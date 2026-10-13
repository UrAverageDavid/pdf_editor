import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';

void main() {
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
