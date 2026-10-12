import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/core/page_geometry.dart';
import 'package:papertrail/features/pdf_viewer/viewport_controller.dart';

void main() {
  test('navigation reveals the PDF after panning into a wide writing area', () {
    final view = ViewportController(List.filled(3, const Size(612, 792)));
    view.configure(const Size(1000, 800));
    view.setWritingAreas({0: 2, 1: 2});
    view.revealWritingArea(0);
    expect(view.screenRect(view.layout.notes[0]).right, closeTo(976, 1e-8));
    expect(view.pageRect(0).right, lessThan(0));
    view.setWritingAreas({1: 2});
    view.revealPage(0);
    expect(view.pageRect(0).left, closeTo(24, 1e-8));
    view.revealWritingArea(1);
    view.jumpTo(2);
    expect(view.pageRect(2).left, closeTo(24, 1e-8));
    expect(view.pageRect(2).top, closeTo(20, 1e-8));
    view.dispose();
  });

  test('right-side space preserves mixed PDF page geometry and scale', () {
    final view = ViewportController([const Size(612, 792), const Size(900, 600)]);
    view.configure(const Size(1000, 800));
    final original = List<Rect>.of(view.layout.pages);
    final scale = view.scale;
    view.setWritingAreas({0: .5, 1: 1.5});
    expect(view.layout.pages, original);
    expect(view.scale, scale);
    expect(view.layout.notes[0].left, original[0].right);
    expect(view.layout.notes[0].width, 306);
    expect(view.layout.width, 2250);
    view.setZoom(view.fitWidthZoom);
    expect(view.layout.width * view.scale, closeTo(952, 1e-8));
    view.setWritingAreas({});
    expect(view.layout.pages, original);
    view.dispose();
  });

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
