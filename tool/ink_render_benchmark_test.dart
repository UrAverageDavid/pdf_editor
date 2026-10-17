import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';

// Run with: flutter test tool/ink_render_benchmark_test.dart --reporter expanded
// The raster benchmark waits for image readback; the other cases only measure
// Dart display-list recording. Neither measures Windows presentation/pen latency.
void main() {
  test('rasterize scrolling saved ink using pictures versus a retained image', () async {
    const size = Size(600, 800);
    final strokes = List.generate(200, (index) => InkStroke(id: '$index', pageIndex: 0,
      points: List.generate(128, (i) => InkPoint(
        .1 + .8 * i / 128, .5 + .35 * math.sin((i + index) / 20), .75, i * 4167)),
      width: 2.2, color: 0xff2947c7, createdAt: DateTime.utc(2026),
      penStyle: const PenStyle(type: PenType.fountain)));
    for (final bitmap in [false, true]) {
      final cache = CommittedInkCache();
      // Record once, exactly like the retained display list used while scrolling.
      final recording = ui.PictureRecorder();
      cache.paint(Canvas(recording), size, 600, strokes,
        devicePixelRatio: bitmap ? 1 : null);
      final content = recording.endRecording();
      Future<void> frame(int i) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..translate(-.37 * i, -.73 * i);
        canvas.drawPicture(content);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(600, 800);
        try { await image.toByteData(); }
        finally { image.dispose(); picture.dispose(); }
      }
      for (var i = 0; i < 3; i++) { await frame(i); }
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) { await frame(i); }
      watch.stop();
      debugPrint('Saved ink raster + readback, 200 x 128 samples, bitmap=$bitmap: '
        '${(watch.elapsedMicroseconds / 20000).toStringAsFixed(3)} ms/frame');
      content.dispose();
      cache.dispose();
    }
  });

  test('record saved ink after successive stroke commits', () {
    const size = Size(600, 800);
    InkStroke stroke(int index) => InkStroke(id: '$index', pageIndex: 0,
      points: List.generate(128, (i) => InkPoint(
        .1 + .8 * i / 128, .5 + .25 * math.sin((i + index) / 20), .75, i * 4167)),
      width: 2.2, color: 0xff2947c7, createdAt: DateTime.utc(2026),
      penStyle: const PenStyle(type: PenType.fountain));
    for (final count in [100, 500]) {
      final initial = List.generate(count, stroke);
      final appended = List.generate(30, (i) => stroke(count + i));
      for (final cached in [false, true]) {
        final strokes = List<InkStroke>.of(initial);
        final cache = CommittedInkCache();
        void frame() {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          if (cached) {
            cache.paint(canvas, size, 600, strokes);
          } else {
            for (final stroke in strokes) {
              StrokeSmoother.paint(canvas, size, stroke.points, stroke.width,
                Color(stroke.color), penStyle: stroke.penStyle);
            }
          }
          recorder.endRecording().dispose();
        }
        frame();
        final watch = Stopwatch()..start();
        for (final stroke in appended) { strokes.add(stroke); frame(); }
        watch.stop();
        debugPrint('Saved ink, $count strokes, cached=$cached: '
          '${(watch.elapsedMicroseconds / 30000).toStringAsFixed(3)} ms/commit');
        cache.dispose();
      }
    }
  });

  test('record sustained live ink frames', () {
    for (final type in [PenType.fountain, PenType.brush, PenType.highlighter]) {
      for (final count in [1000, 6000]) {
        final ink = ActiveInk()..page = 0..penStyle = PenStyle(type: type);
        final painter = ActiveInkPainter(ink, 0, 600);
        void append(int i) => ink.points.add(InkPoint(.1 + .8 * (i % 500) / 500,
          .5 + .25 * math.sin(i / 20), .6 + .3 * math.sin(i / 15), i * 4167));
        void frame() {
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder), const Size(600, 800));
          recorder.endRecording().dispose();
        }
        for (var i = 0; i < count; i++) { append(i); }
        frame();
        final watch = Stopwatch()..start();
        for (var frameIndex = 0; frameIndex < 60; frameIndex++) {
          for (var sample = 0; sample < 4; sample++) { append(ink.points.length); }
          frame();
        }
        watch.stop();
        debugPrint('${type.name}, $count samples: ${(watch.elapsedMicroseconds / 60000).toStringAsFixed(3)} ms/frame');
        ink.dispose();
      }
    }
  });
}
