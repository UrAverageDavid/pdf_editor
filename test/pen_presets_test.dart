import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/app/annotation_toolbar.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';
import 'package:papertrail/features/document/app_document.dart';

import 'helpers.dart';

void main() {
  test(
    'presets and stroke styles survive edits, history, and reopening',
    () async {
      final repository = MemoryRepository();
      final editor = EditorController(sampleDocument(), repository);
      editor.createPen();
      final id = editor.selectedPen.id;
      editor.updatePen(
        editor.selectedPen.copyWith(
          name: 'Calligraphy',
          width: 3.5,
          color: 0xff242c35,
          style: const PenStyle(
            type: PenType.brush,
            pressureSensitivity: .9,
            tipSharpness: .8,
          ),
        ),
      );
      editor.addStroke(
        InkStroke(
          id: 'styled',
          pageIndex: 0,
          points: stroke('s').points,
          width: editor.width,
          color: editor.color,
          penStyle: editor.penStyle,
          createdAt: DateTime.utc(2026),
        ),
      );
      editor.updatePen(
        editor.selectedPen.copyWith(style: const PenStyle(type: PenType.ball)),
      );
      editor.undo();
      editor.redo();
      expect(editor.strokes(0).single.penStyle!.type, PenType.brush);
      await editor.flush();
      final loaded = AppDocument.fromJson(repository.saves.last, '/source.pdf');
      final reopened = EditorController(loaded, repository);
      expect(reopened.selectedPen.id, id);
      expect(reopened.selectedPen.name, 'Calligraphy');
      expect(reopened.width, 3.5);
      expect(reopened.penStyle.type, PenType.ball);
      expect(reopened.strokes(0).single.penStyle!.pressureSensitivity, .9);
      expect(reopened.strokes(0).single.penStyle!.tipSharpness, .8);
      reopened.selectPen('ball');
      expect(reopened.width, .35);
      reopened.selectPen(id);
      expect(reopened.width, 3.5);
      reopened.deletePen(id);
      expect(reopened.selectedPen.id, 'fountain');
      reopened.deletePen('brush');
      reopened.deletePen('ball');
      reopened.deletePen('fountain');
      expect(reopened.penPresets, hasLength(1));
      editor.dispose();
      reopened.dispose();
    },
  );

  test('legacy documents receive presets and keep legacy stroke rendering', () {
    final json = sampleDocument().toJson()
      ..remove('penPresets')
      ..remove('selectedPenId');
    json['strokes'] = [stroke('legacy').toJson()];
    final loaded = AppDocument.fromJson(json, '/source.pdf');
    expect(loaded.penPresets, hasLength(3));
    expect(loaded.annotations[0]!.single.penStyle, isNull);
    final malformed = loaded.toJson();
    (malformed['penPresets'] as List).first['style']['pressureSensitivity'] = 2;
    expect(() => AppDocument.fromJson(malformed, ''), throwsFormatException);
  });

  testWidgets(
    'create, customize, switch and delete a pen through its anchored menu',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final editor = EditorController(sampleDocument(), MemoryRepository());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AnnotationToolbar(editor: editor, finishInput: () {}),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Create pen preset'));
      await tester.pumpAndSettle();
      final id = editor.selectedPen.id;
      expect(editor.penPresets, hasLength(4));
      expect(
        find.byKey(const ValueKey('pen-settings-popover')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('preset-name')),
        'Sketch',
      );
      await tester.tap(find.text('Brush').last);
      await tester.enterText(
        find.byKey(const ValueKey('tip-size-input')),
        '1.75',
      );
      final sharpness = find.byKey(const ValueKey('tip-sharpness'));
      await tester.tapAt(tester.getTopLeft(sharpness) + const Offset(65, 24));
      final pressure = find.byKey(const ValueKey('pressure-sensitivity'));
      await tester.ensureVisible(pressure);
      await tester.tapAt(tester.getTopLeft(pressure) + const Offset(205, 24));
      await tester.pumpAndSettle();
      expect(editor.selectedPen.name, 'Sketch');
      expect(editor.penStyle.type, PenType.brush);
      expect(editor.width, 1.75);
      expect(editor.penStyle.tipSharpness, lessThan(.4));
      expect(editor.penStyle.pressureSensitivity, greaterThan(.6));
      await tester.tap(find.byTooltip('Close pen settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pen-preset-ball')));
      await tester.pumpAndSettle();
      expect(editor.width, .35);
      final custom = find.byKey(ValueKey('pen-preset-$id'));
      await tester.tap(custom);
      await tester.pumpAndSettle();
      expect(editor.width, 1.75);
      await tester.tap(custom);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Delete pen preset'));
      await tester.tap(find.byTooltip('Delete pen preset'));
      await tester.pumpAndSettle();
      expect(editor.penPresets, hasLength(3));
      expect(tester.takeException(), isNull);
      await editor.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
    },
  );
}
