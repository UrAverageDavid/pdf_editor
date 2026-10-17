import 'dart:math' as math;

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

  testWidgets('mounted ink caches are released when the surface is removed', (tester) async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    editor.document.annotations[0] = [savedStroke(1)];
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
      child: SizedBox(width: 100, height: 100, child: CommittedInk(
        editor: editor, page: 0, pageWidth: 100, surface: InkSurface.notes))));
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter).whereType<CommittedInkPainter>().single;
    expect(painter.cache!.debugPictureCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(painter.cache!.debugPictureCount, 0);
    editor.dispose();
  });
}
