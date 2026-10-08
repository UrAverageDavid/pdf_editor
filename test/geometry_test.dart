import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/core/page_geometry.dart';
import 'package:papertrail/features/pdf_viewer/viewport_controller.dart';

void main() {
  test('page coordinates round-trip across page sizes', () {
    for (final size in [const Size(612, 792), const Size(1600, 900)]) {
      const point = Offset(.25, .75);
      expect(normalizePoint(denormalizePoint(point, size), size), point);
    }
  });

  test('PDF conversion respects crop origin and all four rotations', () {
    const crop = Rect.fromLTWH(20, 40, 400, 600);
    const point = Offset(.25, .75);
    expect(normalizedToPdf(point, crop, 0), const Offset(120, 190));
    expect(normalizedToPdf(point, crop, 90), const Offset(320, 190));
    expect(normalizedToPdf(point, crop, 180), const Offset(320, 490));
    expect(normalizedToPdf(point, crop, 270), const Offset(120, 490));
  });

  test('large-document layout requests only a nearby window', () {
    final layout = PageLayout(List.filled(327, const Size(612, 792)));
    final page = layout.pages[150];
    final visible = layout.visible(Rect.fromLTWH(0, page.top, 612, 700)).toList();
    expect(visible, [148, 149, 150, 151, 152]);
  });

  test('viewport mapping remains invertible after zoom and navigation', () {
    final view = ViewportController(List.filled(327, const Size(612, 792)));
    view.configure(const Size(1000, 800));
    view.jumpTo(150);
    view.setZoom(2, focal: const Offset(500, 400));
    final screen = view.pageRect(150);
    final point = screen.topLeft + Offset(screen.width * .3, screen.height * .4);
    final local = view.toDocument(point) - view.layout.pages[150].topLeft;
    expect(local.dx, closeTo(612 * .3, 1e-8));
    expect(local.dy, closeTo(792 * .4, 1e-8));
    view.dispose();
  });
}
