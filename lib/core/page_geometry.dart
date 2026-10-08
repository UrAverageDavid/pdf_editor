import 'dart:ui';

Offset normalizePoint(Offset local, Size page) => Offset(
  (local.dx / page.width).clamp(0.0, 1.0).toDouble(),
  (local.dy / page.height).clamp(0.0, 1.0).toDouble(),
);

Offset denormalizePoint(Offset point, Size page) =>
    Offset(point.dx * page.width, point.dy * page.height);

/// Map displayed-page normalized coordinates to unrotated PDF user space.
/// The crop box here uses PDF min/max coordinates, not a screen-space origin.
Offset normalizedToPdf(Offset point, Rect cropBox, int clockwiseDegrees) {
  final Offset unrotated;
  switch (clockwiseDegrees % 360) {
    case 0: unrotated = Offset(point.dx, 1 - point.dy);
    case 90: unrotated = Offset(point.dy, point.dx);
    case 180: unrotated = Offset(1 - point.dx, point.dy);
    case 270: unrotated = Offset(1 - point.dy, 1 - point.dx);
    default: throw ArgumentError('Page rotation must be a multiple of 90');
  }
  return Offset(cropBox.left + unrotated.dx * cropBox.width,
    cropBox.top + unrotated.dy * cropBox.height);
}

class PageLayout {
  PageLayout(List<Size> sizes) {
    width = sizes.fold<double>(0, (a, b) => a > b.width ? a : b.width);
    var top = 20.0;
    pages = List.unmodifiable(sizes.map((size) {
      final rect = Rect.fromLTWH((width - size.width) / 2, top, size.width, size.height);
      top += size.height + 20;
      return rect;
    }));
    height = top;
  }
  late final double width;
  late final double height;
  late final List<Rect> pages;

  int pageAtY(double y) {
    var lo = 0;
    var hi = pages.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (pages[mid].bottom < y) { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
  }

  Iterable<int> visible(Rect viewport, {int prefetch = 2}) sync* {
    if (pages.isEmpty) return;
    final first = (pageAtY(viewport.top) - prefetch).clamp(0, pages.length - 1).toInt();
    final last = (pageAtY(viewport.bottom) + prefetch).clamp(0, pages.length - 1).toInt();
    for (var i = first; i <= last; i++) { yield i; }
  }
}
