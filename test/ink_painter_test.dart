import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';

Future<int> inkCoverage(PenStyle style, double pressure) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  StrokeSmoother.paint(canvas, const Size(100, 100), List.generate(21,
    (i) => InkPoint(.1 + .04 * i, .5, pressure, i)), 12, Colors.black, penStyle: style);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(100, 100);
  final bytes = (await image.toByteData())!;
  var coverage = 0;
  for (var i = 3; i < bytes.lengthInBytes; i += 4) { coverage += bytes.getUint8(i); }
  image.dispose();
  picture.dispose();
  return coverage;
}

void main() {
  test('pen styles and sharpness change painted ink; zero sensitivity ignores pressure', () async {
    for (final type in PenType.values.where((type) => type != PenType.highlighter)) {
      final insensitive = PenStyle(type: type, pressureSensitivity: 0, tipSharpness: 0);
      expect(await inkCoverage(insensitive, .2), await inkCoverage(insensitive, .9));
      final sensitive = PenStyle(type: type, pressureSensitivity: 1, tipSharpness: 0);
      expect(await inkCoverage(sensitive, .2), lessThan(await inkCoverage(sensitive, .9)));
      final sharp = PenStyle(type: type, pressureSensitivity: 0, tipSharpness: 1);
      expect(await inkCoverage(sharp, .75), lessThan(await inkCoverage(insensitive, .75)));
    }
    final coverage = <int>{};
    for (final type in PenType.values.where((type) => type != PenType.highlighter)) {
      coverage.add(await inkCoverage(PenStyle(type: type), .3));
    }
    expect(coverage, hasLength(3));
  });

  test('highlighter preset ignores pressure and sharpness and stays translucent', () async {
    final low = await inkCoverage(const PenStyle(type: PenType.highlighter,
      pressureSensitivity: 0, tipSharpness: 0), .1);
    final high = await inkCoverage(const PenStyle(type: PenType.highlighter,
      pressureSensitivity: 1, tipSharpness: 1), 1);
    expect(low, high);
    expect(high, lessThan(await inkCoverage(const PenStyle(type: PenType.ball,
      pressureSensitivity: 0, tipSharpness: 0), 1) * .4));
  });

  test('highlighter remains translucent and uniform through retracing', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
    // A black text-like bar under the stroke must remain legible.
    canvas.drawRect(const Rect.fromLTWH(70, 40, 8, 20), Paint()..color = Colors.black);
    StrokeSmoother.paint(canvas, const Size(100, 100), const [
      InkPoint(.1, .5, .1, 0), InkPoint(.9, .5, 1, 1),
      InkPoint(.4, .5, .5, 2), InkPoint(.6, .5, .8, 3),
    ], 16, const Color(0xffffd740), kind: InkKind.highlighter);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(100, 100);
    final bytes = (await image.toByteData())!;
    List<int> pixel(int x, int y) => [for (var c = 0; c < 4; c++) bytes.getUint8((y * 100 + x) * 4 + c)];
    expect(pixel(20, 50), pixel(50, 50));
    expect(pixel(50, 50)[2], inInclusiveRange(190, 200));
    expect(pixel(74, 50)[0], lessThan(85));
    expect(pixel(20, 43), pixel(80, 43)); // Width ignores pen pressure.
    image.dispose();
    picture.dispose();
  });
}
