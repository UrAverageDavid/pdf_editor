import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/app/annotation_toolbar.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';
import 'package:papertrail/features/document/app_document.dart';

import 'helpers.dart';

void main() {
  final binding = _SemanticsRecordingBinding();
  testWidgets(
    'sliders preview locally, commit on release, and remain accessible',
    (tester) async {
      binding.recordUpdates = true;
      binding.children.clear();
      binding.orphans.clear();
      addTearDown(() => binding.recordUpdates = false);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final repository = MemoryRepository();
      final editor = EditorController(sampleDocument(), repository);
      var notifications = 0;
      var finishedInputs = 0;
      editor.addListener(() => notifications++);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AnnotationToolbar(
                editor: editor,
                finishInput: () => finishedInputs++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pen-preset-fountain')));
      await tester.pumpAndSettle();

      final values = <String, double Function()>{
        'pen-size-slider': () => editor.width,
        'tip-sharpness': () => editor.penStyle.tipSharpness,
        'pressure-sensitivity': () => editor.penStyle.pressureSensitivity,
      };
      for (final entry in values.entries) {
        final finder = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        notifications = 0;
        finishedInputs = 0;
        final before = entry.value();
        final rect = tester.getRect(finder);
        final gesture = await tester.startGesture(
          Offset(rect.left + rect.width * .3, rect.center.dy),
        );
        for (final fraction in [.45, .6, .75]) {
          await gesture.moveTo(
            Offset(rect.left + rect.width * fraction, rect.center.dy),
          );
          await tester.pump();
          expect(
            notifications,
            0,
            reason: 'Dragging must not rebuild the editor',
          );
          expect(entry.value(), before);
        }
        final preview = tester.widget<Slider>(finder).value;
        expect(preview, isNot(before));
        expect(finishedInputs, 1);
        await gesture.up();
        await tester.pump();
        expect(entry.value(), preview);
        expect(notifications, 1);

        // Slider's portal adds a semantics ancestor; actions belong to the
        // actual slider node beneath it.
        SemanticsNode? sliderNode;
        void findSlider(SemanticsNode node) {
          if (node.getSemanticsData().hasAction(SemanticsAction.increase)) {
            sliderNode = node;
          }
          node.visitChildren((child) {
            findSlider(child);
            return true;
          });
        }

        findSlider(tester.getSemantics(finder));
        expect(sliderNode, isNotNull);
        final node = sliderNode!;
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.increase),
          isTrue,
        );
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.decrease),
          isTrue,
        );
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            viewId: tester.view.viewId,
            nodeId: node.id,
            type: SemanticsAction.increase,
          ),
        );
        await tester.pump();
        expect(entry.value(), greaterThan(preview));
        expect(notifications, 2);
      }

      await tester.tap(find.byTooltip('Close pen settings'));
      await tester.pumpAndSettle();
      await editor.flush();
      final restored = AppDocument.fromJson(repository.saves.last, '');
      expect(restored.penPresets.first.toJson(), editor.selectedPen.toJson());
      expect(tester.takeException(), isNull);
      expect(
        binding.orphans,
        isEmpty,
        reason: 'Every serialized accessibility node must connect to the root',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
      semantics.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
    expect(loaded.penPresets, hasLength(4));
    expect(loaded.annotations[0]!.single.penStyle, isNull);
    final malformed = loaded.toJson();
    (malformed['penPresets'] as List).first['style']['pressureSensitivity'] = 2;
    expect(() => AppDocument.fromJson(malformed, ''), throwsFormatException);
  });

  test('marker shortcut creates a preset for older documents and preserves it on reopen', () async {
    final document = sampleDocument();
    document.penPresets.removeWhere((p) => p.style.type == PenType.highlighter);
    final repository = MemoryRepository();
    final editor = EditorController(document, repository);
    editor.selectHighlighter();
    final id = editor.selectedPen.id;
    editor.setColor(0xffff80ab);
    editor.setWidth(32);
    editor.selectPen('fountain');
    editor.selectHighlighter();
    expect(editor.selectedPen.id, id);
    expect(editor.color, 0xffff80ab);
    expect(editor.width, 32);
    await editor.flush();
    final restored = EditorController(
      AppDocument.fromJson(repository.saves.last, ''),
      repository,
    );
    expect(restored.highlighting, isTrue);
    expect(restored.selectedPen.toJson(), editor.selectedPen.toJson());
    restored.dispose();
    editor.dispose();
  });

  testWidgets(
    'highlighter presets use colored icons and the shared type and color settings',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MemoryRepository();
      final editor = EditorController(sampleDocument(), repository);
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
      expect(find.byTooltip('Highlighter (M)'), findsNothing);
      expect(find.byType(Text), findsNothing);
      for (final preset in editor.penPresets) {
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(ValueKey('pen-preset-${preset.id}')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.color, Color(preset.color));
      }
      await tester.tap(find.byTooltip('Create pen preset'));
      await tester.pumpAndSettle();
      final id = editor.selectedPen.id;
      await tester.tap(find.byKey(const ValueKey('pen-type-highlighter')));
      await tester.pumpAndSettle();
      expect(editor.highlighting, isTrue);
      expect(editor.width, 16);
      expect(find.byKey(const ValueKey('pressure-sensitivity')), findsNothing);
      final pink = find.byTooltip('Choose pink ink');
      await tester.ensureVisible(pink);
      await tester.tap(pink);
      final input = find.byKey(const ValueKey('tip-size-input'));
      await tester.enterText(input, '41');
      await tester.pump();
      expect(find.text('Enter 6–40 pt'), findsOneWidget);
      expect(editor.width, 16);
      await tester.enterText(input, '32');
      await tester.pump();
      await tester.tap(find.byTooltip('Close pen settings'));
      await tester.pumpAndSettle();
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey('pen-preset-$id')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.border_color_outlined);
      expect(icon.color, const Color(0xffff80ab));
      expect(find.byType(Text), findsNothing);
      await editor.flush();
      final restored = AppDocument.fromJson(repository.saves.last, '');
      final saved = restored.penPresets.firstWhere((p) => p.id == id);
      expect(saved.style.type, PenType.highlighter);
      expect(saved.width, 32);
      expect(saved.color, 0xffff80ab);
      await tester.tap(find.byKey(ValueKey('pen-preset-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pen-type-ball')));
      await tester.pumpAndSettle();
      expect(editor.highlighting, isFalse);
      expect(editor.width, 2.2);
      expect(
        find.byKey(const ValueKey('pressure-sensitivity')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await editor.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
    },
  );

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
      expect(editor.penPresets, hasLength(5));
      expect(
        find.byKey(const ValueKey('pen-settings-popover')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('preset-name')),
        'Sketch',
      );
      await tester.tap(find.byKey(const ValueKey('pen-type-brush')));
      await tester.enterText(
        find.byKey(const ValueKey('tip-size-input')),
        '1.75',
      );
      final sharpness = find.byKey(const ValueKey('tip-sharpness'));
      await tester.ensureVisible(sharpness);
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
      expect(editor.penPresets, hasLength(4));
      expect(tester.takeException(), isNull);
      await editor.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
    },
  );
}

// Validate the incremental tree sent to the engine, including empty portal
// nodes that ordinary widget semantics assertions do not inspect.
class _SemanticsRecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  bool recordUpdates = false;
  final children = <int, List<int>>{};
  final orphans = <int>[];

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() {
    final delegate = super.createSemanticsUpdateBuilder();
    return recordUpdates ? _RecordingUpdateBuilder(delegate, this) : delegate;
  }
}

class _RecordingUpdateBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingUpdateBuilder(this.delegate, this.binding);
  final ui.SemanticsUpdateBuilder delegate;
  final _SemanticsRecordingBinding binding;
  final updated = <int>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final id = invocation.namedArguments[#id] as int;
      updated.add(id);
      binding.children[id] = List<int>.from(
        invocation.namedArguments[#childrenInTraversalOrder] as Iterable<int>,
      );
      return Function.apply(delegate.updateNode, [], invocation.namedArguments);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        delegate.updateCustomAction,
        [],
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in binding.children[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    binding.orphans.addAll(updated.where((id) => !reachable.contains(id)));
    binding.children.removeWhere((id, _) => !reachable.contains(id));
    return delegate.build();
  }
}
