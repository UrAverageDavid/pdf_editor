import 'dart:async';

import 'package:flutter/foundation.dart';

import '../document/app_document.dart';
import 'ink.dart';

enum SaveState { saved, pending, saving, failed }

class StrokeChange {
  StrokeChange({this.added = const [], this.removed = const {},
    this.areaPage, this.areaBefore, this.areaAfter});
  final int? areaPage;
  final WritingArea? areaBefore;
  final WritingArea? areaAfter;
  final List<InkStroke> added;
  /// Original indices preserve paint order when an erase is undone.
  final Map<InkStroke, int> removed;
}

class EditorController extends ChangeNotifier {
  EditorController(this.document, this.repository,
      {this.debounce = const Duration(milliseconds: 450)});
  final AppDocument document;
  final AnnotationRepository repository;
  final Duration debounce;
  final _pageSignals = <int, ValueNotifier<int>>{};
  final _undo = <StrokeChange>[];
  final _redo = <StrokeChange>[];
  Timer? _timer;
  Future<void>? _saving;
  int _revision = 0;
  int _savedRevision = 0;
  bool _disposed = false;
  SaveState saveState = SaveState.saved;
  Object? saveError;
  EditorTool tool = EditorTool.pen;
  int color = 0xff2947c7;
  double width = 2.2;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get isDirty => _revision != _savedRevision;

  ValueListenable<int> pageSignal(int page) =>
      _pageSignals.putIfAbsent(page, () => ValueNotifier(0));
  List<InkStroke> strokes(int page) => document.annotations[page] ?? const [];

  void setTool(EditorTool value) { tool = value; notifyListeners(); }
  void setColor(int value) { color = value; tool = EditorTool.pen; notifyListeners(); }
  void setWidth(double value) { width = value; notifyListeners(); }

  void addStroke(InkStroke stroke) => execute(StrokeChange(added: [stroke]));

  void expandWritingArea(int page) {
    final area = document.writingAreas[page];
    _setWritingArea(page, WritingArea(width: (area?.width ?? 0) + .5));
  }

  void toggleWritingArea(int page) {
    final area = document.writingAreas[page];
    _setWritingArea(page, area == null ? const WritingArea() :
      WritingArea(width: area.width, visible: !area.visible));
  }

  void _setWritingArea(int page, WritingArea area) {
    if (page < 0 || page >= document.pageCount) throw RangeError('Invalid page');
    execute(StrokeChange(areaPage: page,
      areaBefore: document.writingAreas[page], areaAfter: area));
  }

  void erase(Set<String> ids, int page) {
    final existing = strokes(page);
    final removed = <InkStroke, int>{};
    for (var i = 0; i < existing.length; i++) {
      if (ids.contains(existing[i].id)) removed[existing[i]] = i;
    }
    if (removed.isNotEmpty) execute(StrokeChange(removed: removed));
  }

  void execute(StrokeChange change) {
    _apply(change, forward: true);
    _undo.add(change);
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    _changed();
  }

  void undo() {
    if (!canUndo) return;
    final change = _undo.removeLast();
    _apply(change, forward: false);
    _redo.add(change);
    _changed();
  }

  void redo() {
    if (!canRedo) return;
    final change = _redo.removeLast();
    _apply(change, forward: true);
    _undo.add(change);
    _changed();
  }

  void _apply(StrokeChange change, {required bool forward}) {
    final affected = <int>{};
    final areaPage = change.areaPage;
    if (areaPage != null) {
      final area = forward ? change.areaAfter : change.areaBefore;
      if (area == null) { document.writingAreas.remove(areaPage); }
      else { document.writingAreas[areaPage] = area; }
      affected.add(areaPage);
    }
    for (final stroke in change.added) {
      final list = document.annotations.putIfAbsent(stroke.pageIndex, () => []);
      if (forward) { list.add(stroke); } else { list.removeWhere((s) => s.id == stroke.id); }
      affected.add(stroke.pageIndex);
    }
    final entries = change.removed.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in entries) {
      final stroke = entry.key;
      final list = document.annotations.putIfAbsent(stroke.pageIndex, () => []);
      if (forward) { list.removeWhere((s) => s.id == stroke.id); }
      else { list.insert(entry.value.clamp(0, list.length).toInt(), stroke); }
      affected.add(stroke.pageIndex);
    }
    for (final page in affected) {
      final signal = _pageSignals[page];
      if (signal != null) signal.value++;
    }
  }

  void markDirty() => _changed();

  void _changed() {
    _revision++;
    document.modifiedAt = DateTime.now();
    saveState = SaveState.pending;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(debounce, () { unawaited(flush().catchError((Object _) {})); });
  }

  /// One writer; keep draining if edits arrived while a snapshot was saving.
  Future<void> flush() {
    _timer?.cancel();
    if (_saving != null) return _saving!;
    if (!isDirty) return Future<void>.value();
    final future = Future<void>.microtask(_drain);
    _saving = future;
    return future;
  }

  Future<void> _drain() async {
    try {
      while (isDirty) {
        final revision = _revision;
        final snapshot = document.toJson();
        saveState = SaveState.saving;
        _notify();
        await repository.save(snapshot);
        _savedRevision = revision;
      }
      saveError = null;
      saveState = SaveState.saved;
    } catch (error) {
      saveError = error;
      saveState = SaveState.failed;
      rethrow;
    } finally {
      _saving = null;
      _notify();
    }
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final signal in _pageSignals.values) { signal.dispose(); }
    super.dispose();
  }
}
