import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';

// Run with: flutter test tool/ink_render_benchmark_test.dart --reporter expanded
// Measures Dart-side display-list recording, not GPU or physical pen latency.
void main() {
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
