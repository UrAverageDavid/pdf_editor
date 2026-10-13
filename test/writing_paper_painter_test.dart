import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/document/app_document.dart';
import 'package:papertrail/features/pdf_viewer/writing_paper_painter.dart';

Future<ByteData> renderPaper(
  WritingPattern pattern,
  WritingSpacing spacing,
  double scale, {
  double width = 96,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
  WritingPaperPainter(
    pattern: pattern,
    spacing: spacing,
    scale: scale,
  ).paint(canvas, Size(width, 96));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(96, 96);
  final bytes = (await image.toByteData())!;
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  test(
    'blank, ruled and grid guides use the selected spacing at each zoom',
    () async {
      int red(ByteData bytes, int x, int y) => bytes.getUint8((y * 96 + x) * 4);
      for (final spacing in WritingSpacing.values) {
        for (final scale in [1.0, 2.0]) {
          final step = (spacing.points * scale).round();
          final blank = await renderPaper(WritingPattern.blank, spacing, scale);
          final ruled = await renderPaper(WritingPattern.ruled, spacing, scale);
          final grid = await renderPaper(WritingPattern.grid, spacing, scale);
          expect(red(blank, 5, step), 255);
          expect(red(ruled, 5, step), lessThan(255));
          expect(red(ruled, step, 5), 255);
          expect(red(grid, step, 5), lessThan(255));
          expect(red(grid, 5, step), lessThan(255));
          expect(red(grid, step ~/ 2, step ~/ 2), 255);
        }
      }
    },
  );

  test(
    'growing the writing area keeps existing grid guides in place',
    () async {
      final small = await renderPaper(
        WritingPattern.grid,
        WritingSpacing.medium,
        1,
        width: 64,
      );
      final large = await renderPaper(
        WritingPattern.grid,
        WritingSpacing.medium,
        1,
      );
      for (var y = 1; y < 95; y++) {
        for (var x = 1; x < 63; x++) {
          expect(
            small.getUint32((y * 96 + x) * 4),
            large.getUint32((y * 96 + x) * 4),
          );
        }
      }
    },
  );
}
