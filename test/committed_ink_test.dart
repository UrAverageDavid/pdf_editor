import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';

import 'helpers.dart';
import 'ink_painter_test.dart' show rasterize;

InkStroke savedStroke(int index, {int count = 8}) => InkStroke(
  id: '$index', pageIndex: 0, surface: InkSurface.notes,
  points: List.generate(count, (i) => InkPoint(
    .5 + .4 * math.sin((i + index) / 7), .5 + .4 * math.cos((i + index) / 11),
    .2 + .7 * (i % 7) / 7, i * 4167)),
  width: 2 + index % 5, color: index.isEven ? 0x802947c7 : 0xffffd740,
  createdAt: DateTime.utc(2026),
  penStyle: PenStyle(type: PenType.values[index % PenType.values.length]),
  shape: index % 9 == 0 ? InkShape.line : InkShape.freehand,
);

void main() {
  test('visible tile working sets do not churn, even beyond the memory cap', () {
    for (final size in [const Size(1200, 1600), const Size(4608, 4096)]) {
      final cache = CommittedInkCache();
      final strokes = [savedStroke(1)];
      void frame({Rect? visible}) {
        final recorder = ui.PictureRecorder();
        cache.paint(Canvas(recorder), size, size.width, strokes,
          documentSize: size, devicePixelRatio: 1, physicalOrigin: Offset.zero,
          visibleRect: visible);
        recorder.endRecording().dispose();
      }
      frame();
      final count = cache.debugRasterizations;
      expect(count, greaterThan(7));
      expect(cache.debugTileCount * 514 * 514,
        lessThanOrEqualTo(CommittedInkCache.maxTileRasterPixels));
      frame();
      expect(cache.debugRasterizations, count,
        reason: 'A repeat frame must not rerasterize tiles evicted by its own scan');
      // Shrinking the viewport should release offscreen memory too.
      frame(visible: const Rect.fromLTWH(0, 0, 512, 512));
      expect(cache.debugTileCount, lessThanOrEqualTo(7));
      cache.dispose();
    }
  });

  test('tile edits preserve untouched pixels across append, erase, undo and reorder', () async {
    const size = Size(1024, 1024);
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    InkStroke localized(String id, double x, double y, {double width = 4}) => InkStroke(
      id: id, pageIndex: 0, width: width, color: id == 'new' ? 0xffffd740 : 0xff2947c7,
      kind: InkKind.highlighter, createdAt: DateTime.utc(2026),
      points: [InkPoint(x, y, .75, 0), InkPoint(x + .08, y + .08, .75, 1)]);
    final strokes = [localized('left', .1, .1), localized('right', .7, .7)];
    Future<void> check(int expectedRasters) async {
      final before = cache.debugRasterizations;
      Future<List<int>> frame(CommittedInkCache target) => rasterize((canvas) =>
        target.paint(canvas, size, size.width, strokes, documentSize: size,
          devicePixelRatio: 1, physicalOrigin: Offset.zero), size);
      final actual = await frame(cache);
      expect(cache.debugRasterizations - before, expectedRasters);
      final fresh = CommittedInkCache();
      try { expect(actual, orderedEquals(await frame(fresh))); }
      finally { fresh.dispose(); }
    }
    await check(4);
    await check(0);
    strokes.add(localized('new', .15, .15));
    await check(1); // Rebuilding a picture chunk must not invalidate all its tiles.
    final removed = strokes.removeAt(0);
    await check(1);
    strokes.insert(0, removed);
    await check(1);
    final last = strokes.removeLast();
    strokes.insert(0, last);
    await check(4); // Changed paint order must also invalidate affected pixels.
    strokes.add(localized('boundary', .495, .25, width: 20));
    await check(2); // A wide nib reaches across a tile boundary.
    strokes.removeLast();
    await check(2);
    strokes.clear();
    await check(0);
    expect(cache.debugTileCount, 0);
  });

  test('pan reuses tiles, zoom uses vectors, and settling restores exact pixels', () async {
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    const size = Size(600, 800);
    final strokes = List.generate(40, savedStroke);
    Future<List<int>> frame(CommittedInkCache target, Offset origin,
        {bool moving = false, double zoom = 1}) => rasterize((canvas) {
      canvas.translate(origin.dx, origin.dy);
      target.paint(canvas, size * zoom, size.width, strokes, documentSize: size,
        devicePixelRatio: 1, physicalOrigin: origin, viewMoving: moving);
    }, size);
    await frame(cache, Offset.zero);
    final rasters = cache.debugRasterizations;
    final draws = cache.debugTileDraws;
    const origin = Offset(-.37, -.73);
    await frame(cache, origin, moving: true);
    expect(cache.debugRasterizations, rasters);
    expect(cache.debugTileDraws, greaterThan(draws));
    final panDraws = cache.debugTileDraws;
    await frame(cache, origin, moving: true, zoom: 1.25);
    expect(cache.debugRasterizations, rasters);
    expect(cache.debugTileDraws, panDraws, reason: 'Zoom must not stretch cached ink');
    final actual = await frame(cache, origin);
    final fresh = CommittedInkCache();
    try { expect(actual, orderedEquals(await frame(fresh, origin))); }
    finally { fresh.dispose(); }
    expect(cache.debugRasterizations, greaterThan(rasters));
    expect(cache.debugRecordedStrokes, strokes.length);
  });

  test('raster ink preserves edits, opacity, extended coordinates, zoom and DPR', () async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final cache = CommittedInkCache();
    addTearDown(() { cache.dispose(); editor.dispose(); });
    editor.document.annotations[0] = List.generate(40, savedStroke);
    Future<void> check({Set<String> hidden = const {}, double dpr = 1,
        Size reference = const Size(100, 100), Size surface = const Size(200, 100)}) async {
      final actual = await rasterize((canvas) {
        canvas.scale(dpr);
        CommittedInkPainter(editor, 0, 100, surface: InkSurface.notes,
          referenceSize: reference, hidden: hidden, cache: cache,
          devicePixelRatio: dpr).paint(canvas, surface);
      }, surface * dpr);
      final expected = await rasterize((canvas) {
        canvas.scale(dpr);
        CommittedInkPainter(editor, 0, 100, surface: InkSurface.notes,
          referenceSize: reference, hidden: hidden).paint(canvas, surface);
      }, surface * dpr);
      expect(actual, orderedEquals(expected));
    }
    await check();
    final first = cache.debugImage!;
    expect(cache.debugRasterizations, 1);
    expect(cache.debugRasterizedStrokes, 40);
    await check();
    expect(cache.debugImage, same(first));
    expect(cache.debugRasterizations, 1);
    editor.addStroke(savedStroke(40));
    await check();
    expect(cache.debugRasterizedStrokes, 41, reason: 'Append should rasterize only the added stroke');
    expect(first.debugDisposed, isTrue);
    editor.addStroke(InkStroke(id: 'far-note', pageIndex: 0, surface: InkSurface.notes,
      points: const [InkPoint(1.4, .3, .75, 0), InkPoint(1.8, .6, .75, 100)],
      width: 3, color: 0xff2947c7, createdAt: DateTime.utc(2026)));
    await check();
    await check(hidden: {'4'});
    editor.erase({'4'}, 0);
    await check();
    editor.undo();
    await check();
    editor.redo();
    await check();
    await check(dpr: 2);
    await check(dpr: 2, reference: const Size(150, 120), surface: const Size(300, 120));
    await check(surface: const Size(150, 100));
    await check(); // Expanded notes restore ink previously beyond the clip.
    editor.document.annotations[0]!.clear();
    await check();
    expect(cache.debugImage, isNull);
  });

  test('large high-DPI surfaces replay vectors without reducing resolution', () async {
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    final strokes = List.generate(4, (i) => savedStroke(i, count: 128));
    for (final surface in [const Size(1200, 1600), const Size(20000, 1000)]) {
      for (final offset in [0.0, .37, .74]) {
        Future<List<int>> frame(bool cached) => rasterize((canvas) {
          canvas.scale(3);
          canvas.translate(-offset, -.73 * offset);
          if (cached) {
            cache.paint(canvas, const Size(60, 100), 60, strokes,
              surfaceSize: surface, devicePixelRatio: 3);
          } else {
            for (final stroke in strokes) {
              StrokeSmoother.paint(canvas, const Size(60, 100), stroke.points,
                stroke.width, Color(stroke.color), kind: stroke.kind,
                penStyle: stroke.penStyle, shape: stroke.shape);
            }
          }
        }, const Size(240, 330));
        expect(await frame(true), orderedEquals(await frame(false)));
        expect(cache.debugImage, isNull);
      }
    }
    expect(cache.debugRasterizations, 0);
  });

  test('fractional sizes and scroll offsets preserve vector ink sharpness', () async {
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    final strokes = [savedStroke(0), savedStroke(3)];
    const surface = Size(100.3, 120.7);
    for (final dpr in [1.25, 1.5, 2.0]) {
      for (final offset in [0.0, .37]) {
        Future<List<int>> frame(bool cached) => rasterize((canvas) {
          canvas.scale(dpr);
          canvas.translate(offset, offset);
          canvas.clipRect(Offset.zero & surface);
          if (cached) {
            cache.paint(canvas, surface, surface.width, strokes, devicePixelRatio: dpr);
          } else {
            for (final stroke in strokes) {
              StrokeSmoother.paint(canvas, surface, stroke.points, stroke.width,
                Color(stroke.color), kind: stroke.kind, penStyle: stroke.penStyle, shape: stroke.shape);
            }
          }
        }, const Size(240, 260));
        expect(await frame(true), orderedEquals(await frame(false)),
          reason: 'Fractional physical bounds must use vector replay at DPR $dpr, offset $offset');
      }
    }
  });

  test('cached saved ink preserves pixels, order and opacity through edits and zoom', () async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final cache = CommittedInkCache();
    addTearDown(() { cache.dispose(); editor.dispose(); });
    editor.document.annotations[0] = List.generate(70, savedStroke);

    Future<void> check({Set<String> hidden = const {}, Size size = const Size(100, 100)}) async {
      final actual = await rasterize((canvas) => CommittedInkPainter(editor, 0, 100,
        surface: InkSurface.notes, hidden: hidden, cache: cache).paint(canvas, size), size);
      final expected = await rasterize((canvas) => CommittedInkPainter(editor, 0, 100,
        surface: InkSurface.notes, hidden: hidden).paint(canvas, size), size);
      expect(actual, orderedEquals(expected));
    }

    await check();
    expect(cache.debugRecordedStrokes, 70);
    expect(cache.debugPictureCount, 3);
    await check();
    expect(cache.debugRecordedStrokes, 70);
    editor.addStroke(savedStroke(70));
    await check();
    expect(cache.debugRecordedStrokes, 77); // Only the seven-stroke tail.
    await check(hidden: {'4'});
    expect(cache.debugRecordedStrokes, 108); // Only the affected first group.
    editor.erase({'4'}, 0);
    await check();
    expect(cache.debugRecordedStrokes, 108); // Preview already matches the edit.
    editor.undo();
    await check();
    editor.redo();
    await check();
    await check(size: const Size(150, 120));
    await check(size: const Size(100, 100));
    editor.undo();
    editor.undo(); // Undo appended stroke after restoring the erased stroke.
    await check();
    editor.redo();
    await check();
    cache.dispose();
    expect(cache.debugPictureCount, 0);
    await check();
  });

  test('large strokes stay whole and replacing a stroke invalidates its geometry', () async {
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    final strokes = [savedStroke(3, count: 4200), savedStroke(1)];
    Future<void> check() async {
      const size = Size(100, 100);
      final actual = await rasterize((canvas) => cache.paint(canvas, size, 100, strokes), size);
      final expected = await rasterize((canvas) {
        for (final stroke in strokes) {
          StrokeSmoother.paint(canvas, size, stroke.points, stroke.width, Color(stroke.color),
            kind: stroke.kind, shape: stroke.shape, penStyle: stroke.penStyle);
        }
      }, size);
      expect(actual, orderedEquals(expected));
    }
    await check();
    expect(cache.debugPictureCount, 2);
    strokes[1] = savedStroke(1, count: 20); // Same ID, different immutable object.
    await check();
    expect(cache.debugRecordedStrokes, 3);
    strokes.clear();
    await check();
    expect(cache.debugPictureCount, 0);
  });

  test('document geometry survives zoom and tiles match vectors at fractional origins', () async {
    final cache = CommittedInkCache();
    addTearDown(cache.dispose);
    const document = Size(600, 800);
    final strokes = [
      ...List.generate(40, (i) => savedStroke(i, count: 32)),
      InkStroke(id: 'cross-tiles', pageIndex: 0,
        points: const [InkPoint(0, .38, .75, 0), InkPoint(1, .38, .75, 1)],
        width: 1, color: 0xff000000, createdAt: DateTime.utc(2026)),
    ];
    Future<void> check(double zoom, double dpr, Offset origin, {bool tiles = true}) async {
      final size = document * zoom;
      final visible = Rect.fromLTWH(size.width * .25, size.height * .35, 570 / dpr, 330 / dpr);
      Future<List<int>> frame(bool cached) => rasterize((canvas) {
        canvas.translate(origin.dx, origin.dy);
        canvas.scale(dpr);
        canvas.translate(-visible.left, -visible.top);
        if (cached) {
          cache.paint(canvas, size, document.width, strokes, documentSize: document,
            visibleRect: visible, devicePixelRatio: tiles ? dpr : null,
            physicalOrigin: origin - visible.topLeft * dpr);
        } else {
          canvas.clipRect(visible, doAntiAlias: false);
          canvas.scale(zoom);
          for (final stroke in strokes) {
            StrokeSmoother.paint(canvas, document, stroke.points, stroke.width,
              Color(stroke.color), kind: stroke.kind, shape: stroke.shape, penStyle: stroke.penStyle);
          }
        }
      }, const Size(600, 360));
      final actual = await frame(true), expected = await frame(false);
      var different = 0, maxDelta = 0, total = 0;
      for (var i = 3; i < actual.length; i += 4) {
        final delta = (actual[i] - expected[i]).abs();
        if (delta != 0) different++;
        maxDelta = math.max(maxDelta, delta); total += delta;
      }
      expect(expected.where((value) => value != 0), isNotEmpty);
      if (!tiles) {
        expect(actual, orderedEquals(expected));
      } else {
        // Separate raster targets can change edge tessellation slightly; they
        // must not soften the image broadly or change highlighter opacity.
        expect(different / (actual.length / 4), lessThan(.01));
        expect(total / (actual.length / 4), lessThan(.1));
        expect(maxDelta, lessThanOrEqualTo(64));
      }
    }
    await check(1, 1, Offset.zero);
    final rasters = cache.debugRasterizations;
    await check(1, 1, Offset.zero);
    expect(cache.debugRasterizations, rasters, reason: 'Settled tiles should be reused');
    for (final zoom in [1.25, 2.0, 4.0]) {
      await check(zoom, 1.5, const Offset(.37, .73), tiles: false);
      await check(zoom, 1.5, const Offset(.37, .73));
    }
    expect(cache.debugRecordedStrokes, 41, reason: 'Zoom must reuse document geometry');
    expect(cache.debugTileCount, lessThanOrEqualTo(7));
    final removed = strokes.removeAt(0);
    await check(1.25, 1.5, const Offset(.37, .73));
    strokes.insert(0, removed); // Undo must invalidate the edited tiles too.
    await check(1.25, 1.5, const Offset(.37, .73));
    strokes.add(savedStroke(42));
    await check(1.25, 1.5, const Offset(.37, .73));
  });

  testWidgets('mounted ink caches are released when the surface is removed', (tester) async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    editor.document.annotations[0] = [savedStroke(1)];
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 100, height: 100, child: CommittedInk(
        editor: editor, page: 0, pageWidth: 100, surface: InkSurface.notes)))));
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter).whereType<CommittedInkPainter>().single;
    expect(painter.cache!.debugPictureCount, 1);
    final image = painter.cache!.debugImage!;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(painter.cache!.debugPictureCount, 0);
    expect(image.debugDisposed, isTrue);
    editor.dispose();
  });
}
