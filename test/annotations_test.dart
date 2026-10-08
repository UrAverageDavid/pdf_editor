import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/document/app_document.dart';

import 'helpers.dart';

void main() {
  test('group erase, undo, redo preserve original stroke paint order', () async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    for (final id in ['a', 'b', 'c', 'd']) { editor.addStroke(stroke(id)); }
    editor.erase({'b', 'd'}, 0);
    expect(editor.strokes(0).map((s) => s.id), ['a', 'c']);
    editor.undo();
    expect(editor.strokes(0).map((s) => s.id), ['a', 'b', 'c', 'd']);
    editor.redo();
    expect(editor.strokes(0).map((s) => s.id), ['a', 'c']);
    editor.undo();
    editor.addStroke(stroke('e'));
    expect(editor.canRedo, isFalse);
    await editor.flush();
    editor.dispose();
  });

  test('undo add and redo operate on annotations only', () async {
    final editor = EditorController(sampleDocument(), MemoryRepository());
    editor.addStroke(stroke('a'));
    editor.undo();
    expect(editor.strokes(0), isEmpty);
    editor.redo();
    expect(editor.strokes(0).single.id, 'a');
    await editor.flush();
    editor.dispose();
  });

  test('serialization preserves points, pressure, width and timestamps', () {
    final document = sampleDocument();
    document.annotations[1] = [stroke('a', page: 1)];
    final decoded = jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>;
    final result = AppDocument.fromJson(decoded, '/new/location.pdf');
    expect(result.toJson(), document.toJson());
    expect(result.sourcePath, '/new/location.pdf');
  });

  test('swept eraser detects crossing even with distant pointer samples', () {
    final line = InkStroke(id: 'line', pageIndex: 0,
      points: const [InkPoint(.5, .1, 1, 0), InkPoint(.5, .9, 1, 1)],
      width: 2, color: 0xff000000, createdAt: DateTime.utc(2026));
    expect(strokeIntersects(line, const Size(100, 100),
      const Offset(0, 50), const Offset(100, 50), 1), isTrue);
    expect(strokeIntersects(line, const Size(100, 100),
      const Offset(0, 0), const Offset(10, 0), 1), isFalse);
  });

  test('autosave drains edits arriving during an in-flight save', () async {
    final repository = DelayedRepository();
    final editor = EditorController(sampleDocument(), repository);
    editor.addStroke(stroke('first'));
    final saving = editor.flush();
    await Future<void>.delayed(Duration.zero);
    editor.addStroke(stroke('second'));
    repository.gate.complete();
    await saving;
    expect(repository.saves.length, 2);
    expect((repository.saves.last['strokes'] as List<dynamic>).length, 2);
    expect(editor.isDirty, isFalse);
    editor.dispose();
  });

  test('failed save remains dirty and retry persists current edits', () async {
    final repository = FailingRepository();
    final editor = EditorController(sampleDocument(), repository);
    editor.addStroke(stroke('first'));
    await expectLater(editor.flush(), throwsStateError);
    expect(editor.saveState, SaveState.failed);
    expect(editor.isDirty, isTrue);
    repository.fail = false;
    await editor.flush();
    expect(editor.saveState, SaveState.saved);
    expect(editor.isDirty, isFalse);
    editor.dispose();
  });
}

class DelayedRepository extends MemoryRepository {
  final gate = Completer<void>();
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    saves.add(snapshot);
    if (saves.length == 1) await gate.future;
  }
}

class FailingRepository extends MemoryRepository {
  bool fail = true;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    if (fail) throw StateError('Disk full');
    await super.save(snapshot);
  }
}
