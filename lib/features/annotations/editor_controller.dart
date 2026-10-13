import 'dart:async';

import 'package:flutter/foundation.dart';

import '../document/app_document.dart';
import 'ink.dart';
import 'pen_preset.dart';

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
      {this.debounce = const Duration(seconds: 1)});
  final AppDocument document;
  final AnnotationRepository repository;
  final Duration debounce;
  final _pageSignals = <int, ValueNotifier<int>>{};
  final _undo = <StrokeChange>[];
  final _redo = <StrokeChange>[];
  Timer? _timer;
  Future<void>? _saving;
  bool _flushRequested = false;
  int _revision = 0;
  int _savedRevision = 0;
  bool _disposed = false;
  SaveState saveState = SaveState.saved;
  Object? saveError;
  EditorTool tool = EditorTool.pen;
  List<PenPreset> get penPresets => List.unmodifiable(document.penPresets);
  PenPreset get selectedPen => document.penPresets.firstWhere((p) => p.id == document.selectedPenId);
  int get color => selectedPen.color;
  double get width => selectedPen.width;
  PenStyle get penStyle => selectedPen.style;

  void selectPen(String id) {
    if (!document.penPresets.any((p) => p.id == id)) return;
    tool = EditorTool.pen;
    if (document.selectedPenId == id) { notifyListeners(); return; }
    document.selectedPenId = id;
    _changed();
  }

  void updatePen(PenPreset preset) {
    final index = document.penPresets.indexWhere((p) => p.id == preset.id);
    if (index < 0) return;
    document.penPresets[index] = preset;
    _changed();
  }

  void createPen() {
    final source = selectedPen;
    final preset = PenPreset(id: 'pen-${DateTime.now().microsecondsSinceEpoch}',
      name: 'Pen ${penPresets.length + 1}', width: source.width,
      color: source.color, style: source.style);
    document.penPresets.add(preset);
    document.selectedPenId = preset.id;
    tool = EditorTool.pen;
    _changed();
  }

  void deletePen(String id) {
    if (document.penPresets.length <= 1) return;
    document.penPresets.removeWhere((p) => p.id == id);
    if (document.selectedPenId == id) document.selectedPenId = document.penPresets.first.id;
    _changed();
  }
  bool detectShapes = false;
  bool get highlighting => tool == EditorTool.pen && penStyle.type == PenType.highlighter;
  int get activeColor => color;
  double get activeWidth => width;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get isDirty => _revision != _savedRevision;

  ValueListenable<int> pageSignal(int page) =>
      _pageSignals.putIfAbsent(page, () => ValueNotifier(0));
  List<InkStroke> strokes(int page) => document.annotations[page] ?? const [];

  void setTool(EditorTool value) { tool = value; notifyListeners(); }
  void setColor(int value) {
    tool = EditorTool.pen;
    updatePen(selectedPen.copyWith(color: value));
  }
  void setWidth(double value) => updatePen(selectedPen.copyWith(width: value));

  /// The marker shortcut selects a saved preset, including in older documents.
  void selectHighlighter() {
    if (highlighting) return;
    final existing = penPresets.where((p) => p.style.type == PenType.highlighter).firstOrNull;
    if (existing != null) { selectPen(existing.id); return; }
    final preset = PenPreset.highlighter;
    final id = document.penPresets.any((p) => p.id == preset.id)
      ? 'highlighter-${DateTime.now().microsecondsSinceEpoch}' : preset.id;
    document.penPresets.add(PenPreset(id: id, name: preset.name,
      width: preset.width, color: preset.color, style: preset.style));
    selectPen(id);
  }
  void toggleShapeDetection() { detectShapes = !detectShapes; notifyListeners(); }

  /// Automatic space resizing belongs to the stroke's single undo/redo step.
  void addStroke(InkStroke stroke, {double? writingAreaWidth}) {
    final before = document.writingAreas[stroke.pageIndex];
    final resize = stroke.surface == InkSurface.notes && before != null &&
      writingAreaWidth != null && writingAreaWidth.isFinite && writingAreaWidth > 0 && writingAreaWidth != before.width;
    execute(StrokeChange(added: [stroke],
      areaPage: resize ? stroke.pageIndex : null,
      areaBefore: resize ? before : null,
      areaAfter: resize ? WritingArea(width: writingAreaWidth, visible: before.visible) : null));
  }

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

  void erase(Set<String> ids, int page, {double? writingAreaWidth}) {
    final existing = strokes(page);
    final removed = <InkStroke, int>{};
    for (var i = 0; i < existing.length; i++) {
      if (ids.contains(existing[i].id)) removed[existing[i]] = i;
    }
    final before = document.writingAreas[page];
    final resize = before != null && writingAreaWidth != null &&
      writingAreaWidth.isFinite && writingAreaWidth > 0 && writingAreaWidth != before.width;
    if (removed.isNotEmpty) execute(StrokeChange(removed: removed,
      areaPage: resize ? page : null, areaBefore: resize ? before : null,
      areaAfter: resize ? WritingArea(width: writingAreaWidth, visible: before.visible) : null));
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
    recordInputActivity();
  }

  /// Input postpones autosave without dirtying the document or rebuilding ink.
  void recordInputActivity() {
    if (_disposed || !isDirty) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_save().catchError((Object _) {}));
    });
  }

  /// Explicit saves (including close/background) drain all edits immediately.
  Future<void> flush() => _save(force: true);

  Future<void> _save({bool force = false}) {
    if (force) {
      _timer?.cancel();
      _timer = null;
      if (isDirty || _saving != null) _flushRequested = true;
    }
    if (_saving != null) return _saving!;
    if (!isDirty) return Future<void>.value();
    final future = Future<void>.microtask(_drain);
    _saving = future;
    return future;
  }

  Future<void> _drain() async {
    try {
      while (isDirty) {
        // A new input event/commit during an autosave gets its own idle window.
        // An explicit flush can upgrade that same writer to drain immediately.
        if (!_flushRequested && (_disposed || _timer != null)) break;
        final revision = _revision;
        final snapshot = document.toJson();
        saveState = SaveState.saving;
        _notify();
        await repository.save(snapshot);
        _savedRevision = revision;
      }
      saveError = null;
      saveState = isDirty ? SaveState.pending : SaveState.saved;
      if (!isDirty) { _timer?.cancel(); _timer = null; }
    } catch (error) {
      saveError = error;
      saveState = SaveState.failed;
      rethrow;
    } finally {
      _saving = null;
      _flushRequested = false;
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
