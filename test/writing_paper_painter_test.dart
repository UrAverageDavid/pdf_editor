import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/document/app_document.dart';
import 'package:papertrail/features/pdf_viewer/writing_paper_painter.dart';

class GuideCountingCanvas implements Canvas {
  final lines = <(Offset, Offset)>[];
  @override
  Rect getLocalClipBounds() => Rect.largest;
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  test('an unbounded repaint layer only records guides around the visible margin', () {
    final canvas = GuideCountingCanvas();
    const visible = Rect.fromLTWH(500000, 200000, 600, 800);
    const WritingPaperPainter(pattern: WritingPattern.grid,
      spacing: WritingSpacing.medium, scale: 1, visibleRect: visible)
      .paint(canvas, const Size(1000000, 1000000));
    expect(canvas.lines, isNotEmpty);
    expect(canvas.lines.length, lessThan(100));
    for (final line in canvas.lines) {
      expect(visible.inflate(WritingSpacing.medium.points).contains(line.$1), isTrue);
      expect(visible.inflate(WritingSpacing.medium.points).contains(line.$2), isTrue);
      expect(line.$1.dx % WritingSpacing.medium.points == 0 ||
        line.$1.dy % WritingSpacing.medium.points == 0, isTrue);
    }
  });

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
