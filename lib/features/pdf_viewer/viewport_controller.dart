import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../core/page_geometry.dart';

class ViewportController extends ChangeNotifier {
  ViewportController(List<Size> sizes) : _sizes = List.unmodifiable(sizes), layout = PageLayout(sizes);
  final List<Size> _sizes;
  PageLayout layout;
  Map<int, double> _rightWidths = {};

  void setWritingAreas(Map<int, double> widths) {
    if (mapEquals(_rightWidths, widths)) return;
    _rightWidths = Map.of(widths);
    layout = PageLayout(_sizes, rightWidths: widths);
    _clamp();
    notifyListeners();
  }
  Size size = Size.zero;
  double zoom = 1;
  Offset offset = Offset.zero;
  bool inputActive = false;
  double get fitScale => math.max(.05, (size.width - 48) / layout.pdfWidth);
  double get fitWidthZoom => layout.pdfWidth / layout.width;
  double get scale => fitScale * zoom;
  int get currentPage => layout.pageAtY(toDocument(Offset(size.width / 2, size.height / 2)).dy);
  Rect get visibleDocument => Rect.fromPoints(toDocument(Offset.zero),
      toDocument(Offset(size.width, size.height)));
  Offset toDocument(Offset viewport) => (viewport - offset) / scale;
  Rect pageRect(int page) {
    return screenRect(layout.pages[page]);
  }

  Rect screenRect(Rect r) {
    return Rect.fromLTWH(r.left * scale + offset.dx, r.top * scale + offset.dy,
        r.width * scale, r.height * scale);
  }

  /// Called during layout; the current build consumes the new values directly.
  void configure(Size next) {
    if (size == next) return;
    final anchor = size.isEmpty ? Offset.zero : toDocument(Offset(size.width / 2, 0));
    size = next;
    offset = Offset(size.width / 2 - anchor.dx * scale, -anchor.dy * scale);
    _clamp();
  }

  void pan(Offset delta) {
    if (inputActive) return;
    offset += delta;
    _clamp();
    notifyListeners();
  }

  void revealWritingArea(int page) {
    if (inputActive || layout.notes[page].width == 0) return;
    offset = Offset(math.min(offset.dx, size.width - 24 - layout.notes[page].right * scale), offset.dy);
    _clamp();
    notifyListeners();
  }

  void revealPage(int page) {
    if (inputActive) return;
    offset = Offset(24 - layout.pages[page].left * scale, offset.dy);
    _clamp();
    notifyListeners();
  }

  void setZoom(double next, {Offset? focal}) {
    if (inputActive) return;
    final focus = focal ?? Offset(size.width / 2, size.height / 2);
    final anchor = toDocument(focus);
    zoom = next.clamp(math.min(.35, fitWidthZoom), 5.0).toDouble();
    offset = focus - anchor * scale;
    _clamp();
    notifyListeners();
  }

  void jumpTo(int page) {
    if (inputActive) return;
    final index = page.clamp(0, layout.pages.length - 1).toInt();
    offset = Offset(24 - layout.pages[index].left * scale,
      -layout.pages[index].top * scale + 20);
    _clamp();
    notifyListeners();
  }

  void _clamp() {
    final w = layout.width * scale;
    final h = layout.height * scale;
    offset = Offset(w <= size.width ? (size.width - w) / 2 :
      offset.dx.clamp(size.width - w - 24, 24).toDouble(),
      offset.dy.clamp(math.min(0.0, size.height - h - 20), 0.0).toDouble());
  }
}
