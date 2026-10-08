import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../core/page_geometry.dart';

class ViewportController extends ChangeNotifier {
  ViewportController(List<Size> sizes) : layout = PageLayout(sizes);
  final PageLayout layout;
  Size size = Size.zero;
  double zoom = 1;
  Offset offset = Offset.zero;
  bool inputActive = false;
  double get fitScale => math.max(.05, (size.width - 48) / layout.width);
  double get scale => fitScale * zoom;
  int get currentPage => layout.pageAtY(toDocument(Offset(size.width / 2, size.height / 2)).dy);
  Rect get visibleDocument => Rect.fromPoints(toDocument(Offset.zero),
      toDocument(Offset(size.width, size.height)));
  Offset toDocument(Offset viewport) => (viewport - offset) / scale;
  Rect pageRect(int page) {
    final r = layout.pages[page];
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

  void setZoom(double next, {Offset? focal}) {
    if (inputActive) return;
    final focus = focal ?? Offset(size.width / 2, size.height / 2);
    final anchor = toDocument(focus);
    zoom = next.clamp(.35, 5.0).toDouble();
    offset = focus - anchor * scale;
    _clamp();
    notifyListeners();
  }

  void jumpTo(int page) {
    if (inputActive) return;
    final index = page.clamp(0, layout.pages.length - 1).toInt();
    offset = Offset(offset.dx, -layout.pages[index].top * scale + 20);
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
