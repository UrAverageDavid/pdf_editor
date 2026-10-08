import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import '../../core/lru_cache.dart';
import 'pdf_engine.dart';

typedef RenderKey = ({int page, double scale, Rect? tile});

class RenderTicket {
  RenderTicket(this.key, this.priority);
  final RenderKey key;
  int priority;
  final _result = Completer<Image?>();
  bool cancelled = false;
  Future<Image?> get result => _result.future;
  void cancel() {
    cancelled = true;
    if (!_result.isCompleted) _result.complete(null);
  }
}

/// Single bounded render worker. The backend owns rasterization threading.
/// Every returned Image is a caller-owned clone and must be disposed.
class RenderService {
  RenderService(this.document, {int budgetBytes = 64 * 1024 * 1024})
      : cache = LruCache(budgetBytes: budgetBytes,
          sizeOf: (Image image) => image.width * image.height * 4,
          onEvict: (Image image) => image.dispose());

  final PdfDocumentHandle document;
  final LruCache<RenderKey, Image> cache;
  final _queue = <RenderTicket>[];
  bool _busy = false;
  bool _closed = false;
  bool _paused = false;
  Completer<void>? _idle;

  set inkActive(bool value) {
    _paused = value;
    if (!value) _schedule();
  }

  RenderTicket request(int page, double scale, {int priority = 1}) {
    final size = document.pageSizes[page];
    // Whole-page prototype limit: 2 million pixels/page, even at extreme zoom.
    // Tile-capable engine can replace this policy without changing ink geometry.
    final bounded = math.min((scale * 4).ceil() / 4,
        math.sqrt(2000000 / (size.width * size.height)));
    final RenderKey key = (page: page, scale: bounded, tile: null);
    final ticket = RenderTicket(key, priority);
    if (_closed) { ticket.cancel(); return ticket; }
    final cached = cache.get(key);
    if (cached != null) { ticket._result.complete(cached.clone()); return ticket; }
    _queue.add(ticket);
    _schedule();
    return ticket;
  }

  void _schedule() { scheduleMicrotask(_pump); }

  Future<void> _pump() async {
    if (_busy || _closed || _paused) return;
    _queue.removeWhere((t) => t.cancelled);
    if (_queue.isEmpty) return;
    _queue.sort((a, b) => a.priority.compareTo(b.priority));
    final ticket = _queue.removeAt(0);
    _busy = true;
    try {
      final cached = cache.get(ticket.key);
      final image = cached?.clone() ?? await document.renderPage(
        pageIndex: ticket.key.page, scale: ticket.key.scale);
      if (ticket.cancelled || _closed) {
        image.dispose();
        ticket.cancel();
      } else {
        ticket._result.complete(image.clone());
        cache.put(ticket.key, image);
      }
    } catch (error, stack) {
      if (!ticket._result.isCompleted) ticket._result.completeError(error, stack);
    } finally {
      _busy = false;
      _idle?.complete();
      _idle = null;
      _schedule();
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final ticket in _queue) { ticket.cancel(); }
    _queue.clear();
    if (_busy) { _idle ??= Completer<void>(); await _idle!.future; }
    cache.clear();
    await document.close();
  }
}
