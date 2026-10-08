import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/page_geometry.dart';
import '../annotations/editor_controller.dart';
import '../annotations/ink.dart';
import '../annotations/ink_painter.dart';
import 'page_image.dart';
import 'render_service.dart';
import 'viewport_controller.dart';

class DocumentView extends StatefulWidget {
  const DocumentView({super.key, required this.editor, required this.renders,
    required this.viewport});
  final EditorController editor;
  final RenderService renders;
  final ViewportController viewport;
  @override
  State<DocumentView> createState() => DocumentViewState();
}

class DocumentViewState extends State<DocumentView> {
  final _ink = ActiveInk();
  final _touches = <int, Offset>{};
  final _erased = <String>{};
  int? _pointer;
  int? _page;
  bool _erasing = false;
  Offset? _erasePosition;
  Offset? _previousErase;
  double _trackpadScale = 1;
  int _strokeSequence = 0;
  DateTime _lastPen = DateTime.fromMillisecondsSinceEpoch(0);
  ViewportController get view => widget.viewport;

  @override
  void initState() { super.initState(); view.addListener(_rebuild); }
  void _rebuild() { if (mounted) setState(() {}); }

  bool _isPen(PointerEvent e) => e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;
  bool get _palmSuppressed => _pointer != null ||
      DateTime.now().difference(_lastPen).inMilliseconds < 180;

  void _down(PointerDownEvent e) {
    if (_isPen(e)) { _lastPen = DateTime.now(); _touches.clear(); }
    if (_pointer != null) return;
    final drawingDevice = _isPen(e) || (e.kind == PointerDeviceKind.mouse &&
      (e.buttons & kPrimaryMouseButton) != 0);
    if (drawingDevice && widget.editor.tool != EditorTool.hand) {
      final position = view.toDocument(e.localPosition);
      final page = view.layout.pageAtY(position.dy);
      if (!view.layout.pages[page].contains(position)) return;
      _pointer = e.pointer;
      _page = page;
      _erasing = widget.editor.tool == EditorTool.eraser ||
          e.kind == PointerDeviceKind.invertedStylus;
      view.inputActive = true;
      widget.renders.inkActive = true;
      _ink.page = page;
      _ink.width = widget.editor.width;
      _ink.color = widget.editor.color;
      _sample(e);
    } else if (e.kind != PointerDeviceKind.touch || !_palmSuppressed) {
      _touches[e.pointer] = e.localPosition;
    }
  }

  void _move(PointerMoveEvent e) {
    if (_isPen(e)) _lastPen = DateTime.now();
    if (e.pointer == _pointer) { _sample(e); return; }
    if (_pointer != null || !_touches.containsKey(e.pointer)) return;
    if (_touches.length == 1) {
      final previous = _touches[e.pointer]!;
      _touches[e.pointer] = e.localPosition;
      view.pan(e.localPosition - previous);
    } else {
      final before = _touches.values.take(2).toList();
      final oldCenter = (before[0] + before[1]) / 2;
      final oldDistance = (before[0] - before[1]).distance;
      _touches[e.pointer] = e.localPosition;
      final after = _touches.values.take(2).toList();
      final center = (after[0] + after[1]) / 2;
      final distance = (after[0] - after[1]).distance;
      if (oldDistance > 4) view.setZoom(view.zoom * distance / oldDistance, focal: oldCenter);
      view.pan(center - oldCenter);
    }
  }

  void _sample(PointerEvent e) {
    final page = _page!;
    final rect = view.layout.pages[page];
    final local = view.toDocument(e.localPosition) - rect.topLeft;
    // End at the page boundary; never bridge unrelated pages with a stroke.
    if (!(Offset.zero & rect.size).contains(local)) { finishInput(); return; }
    if (_erasing) {
      final from = _previousErase ?? local;
      for (final stroke in widget.editor.strokes(page)) {
        if (strokeIntersects(stroke, rect.size, from, local, 12 / view.scale)) {
          _erased.add(stroke.id);
        }
      }
      _previousErase = local;
      setState(() => _erasePosition = e.localPosition);
      return;
    }
    final normalized = normalizePoint(local, rect.size);
    final range = e.pressureMax - e.pressureMin;
    final pressure = _isPen(e) && range > 0
        ? ((e.pressure - e.pressureMin) / range).clamp(.05, 1.0).toDouble() : .75;
    _ink.points.add(InkPoint(normalized.dx, normalized.dy, pressure, e.timeStamp.inMicroseconds));
    _ink.changed();
  }

  /// Also used before focus loss, document switching, export, and normal exit.
  void finishInput() {
    if (_pointer == null) { _touches.clear(); return; }
    if (_erasing) {
      widget.editor.erase(_erased, _page!);
    } else if (_ink.points.isNotEmpty) {
      final now = DateTime.now();
      widget.editor.addStroke(InkStroke(
        id: '${now.microsecondsSinceEpoch}-${_strokeSequence++}', pageIndex: _page!,
        points: _ink.points, width: _ink.width, color: _ink.color, createdAt: now));
    }
    _pointer = null;
    _page = null;
    _previousErase = null;
    _erased.clear();
    _ink.clear();
    view.inputActive = false;
    widget.renders.inkActive = false;
    if (mounted) setState(() => _erasePosition = null);
  }

  void _up(PointerEvent e) {
    if (e.pointer == _pointer) finishInput();
    _touches.remove(e.pointer);
  }

  void _signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || _pointer != null) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final scroll = event as PointerScrollEvent;
      if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) {
        view.setZoom(view.zoom * math.exp(-scroll.scrollDelta.dy * .002), focal: scroll.localPosition);
      } else { view.pan(-scroll.scrollDelta); }
    });
  }

  @override
  void dispose() {
    view.removeListener(_rebuild);
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    view.configure(constraints.biggest);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final visible = view.visibleDocument;
    final pages = view.layout.visible(visible).toList();
    return Semantics(label: 'PDF canvas. Pen or mouse draws; touch scrolls and pinches to zoom.',
      child: MouseRegion(cursor: widget.editor.tool == EditorTool.hand
        ? SystemMouseCursors.grab : SystemMouseCursors.precise,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down, onPointerMove: _move,
          onPointerUp: _up, onPointerCancel: _up, onPointerSignal: _signal,
          onPointerPanZoomStart: (_) => _trackpadScale = 1,
          onPointerPanZoomUpdate: (e) {
            view.setZoom(view.zoom * e.scale / _trackpadScale, focal: e.localPosition);
            _trackpadScale = e.scale;
            view.pan(e.panDelta);
          },
          child: ClipRect(child: ColoredBox(color: const Color(0xffe9e9e5),
            child: Stack(children: [
              for (final page in pages)
                Positioned.fromRect(rect: view.pageRect(page),
                  child: RepaintBoundary(child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 12, offset: const Offset(0, 3))]),
                    child: ClipRect(child: Stack(fit: StackFit.expand, children: [
                      RepaintBoundary(child: PageImage(key: ValueKey('pdf-$page'),
                        renders: widget.renders, page: page, scale: view.scale * dpr,
                        priority: page == view.currentPage ? 0 : view.layout.pages[page].overlaps(visible) ? 1 : 3)),
                      RepaintBoundary(child: CustomPaint(painter: CommittedInkPainter(
                        widget.editor, page, view.layout.pages[page].width,
                        hidden: _erasing && _page == page ? Set.of(_erased) : const {}))),
                      RepaintBoundary(child: CustomPaint(painter: ActiveInkPainter(
                        _ink, page, view.layout.pages[page].width))),
                    ])),
                  )),
                ),
              if (_erasePosition != null) Positioned(left: _erasePosition!.dx - 12,
                top: _erasePosition!.dy - 12, width: 24, height: 24,
                child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
                  shape: BoxShape.circle, color: Colors.white.withValues(alpha: .5),
                  border: Border.all(color: const Color(0xff2947c7), width: 1.5))))),
            ])),
          ),
        ),
      ),
    );
  });
}
