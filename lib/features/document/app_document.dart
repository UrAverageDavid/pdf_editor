import '../annotations/ink.dart';
import '../annotations/pen_preset.dart';

class WritingArea {
  const WritingArea({this.width = .5, this.visible = true});
  /// Width in multiples of the original PDF page width.
  final double width;
  final bool visible;
  Map<String, dynamic> toJson() => {'width': width, 'visible': visible};
  factory WritingArea.fromJson(Map<String, dynamic> json) {
    final width = (json['width'] as num).toDouble();
    if (!width.isFinite || width <= 0) throw const FormatException('Invalid writing area width');
    return WritingArea(width: width, visible: json['visible'] as bool);
  }
}

class AppDocument {
  AppDocument({required this.id, required this.displayName, required this.sourcePath,
    required this.originalPath, required this.pageCount, required this.modifiedAt,
    Map<int, List<InkStroke>>? annotations, Map<int, WritingArea>? writingAreas,
    List<PenPreset>? penPresets, this.selectedPenId = 'fountain'})
      : annotations = annotations ?? {}, writingAreas = writingAreas ?? {},
        penPresets = List.of(penPresets ?? PenPreset.defaults);

  final String id; // Full SHA-256 of the immutable imported PDF.
  final String displayName;
  final String sourcePath;
  final String originalPath;
  final int pageCount;
  DateTime modifiedAt;
  final Map<int, List<InkStroke>> annotations;
  final Map<int, WritingArea> writingAreas;
  final List<PenPreset> penPresets;
  String selectedPenId;
  int get strokeCount => annotations.values.fold(0, (n, strokes) => n + strokes.length);

  Map<String, dynamic> toJson() => {
    'penPresets': penPresets.map((preset) => preset.toJson()).toList(),
    'selectedPenId': selectedPenId,
    'schema': 2, 'id': id, 'displayName': displayName, 'originalPath': originalPath,
    'pageCount': pageCount, 'modifiedAt': modifiedAt.toIso8601String(),
    'strokes': annotations.values.expand((s) => s).map((s) => s.toJson()).toList(),
    'writingAreas': writingAreas.map((page, area) => MapEntry('$page', area.toJson())),
  };

  factory AppDocument.fromJson(Map<String, dynamic> json, String sourcePath) {
    if (json['schema'] != 1 && json['schema'] != 2) throw const FormatException('Unsupported note format');
    final count = json['pageCount'] as int;
    if (count < 1) throw const FormatException('Invalid page count');
    final areas = <int, WritingArea>{};
    if (json['schema'] == 2) {
      for (final entry in (json['writingAreas'] as Map<String, dynamic>).entries) {
        final page = int.tryParse(entry.key);
        if (page == null || page < 0 || page >= count || areas.containsKey(page)) {
          throw const FormatException('Invalid writing area page');
        }
        areas[page] = WritingArea.fromJson(entry.value as Map<String, dynamic>);
      }
    }
    final presets = (json['penPresets'] as List<dynamic>?)?.map((item) =>
      PenPreset.fromJson(item as Map<String, dynamic>)).toList();
    if (presets != null && (presets.isEmpty || presets.map((p) => p.id).toSet().length != presets.length)) {
      throw const FormatException('Invalid pen presets');
    }
    final selected = json['selectedPenId'] as String? ?? (presets ?? PenPreset.defaults).first.id;
    if (!(presets ?? PenPreset.defaults).any((p) => p.id == selected)) {
      throw const FormatException('Invalid selected pen');
    }
    final annotations = <int, List<InkStroke>>{};
    final ids = <String>{};
    for (final item in json['strokes'] as List<dynamic>) {
      final stroke = InkStroke.fromJson(item as Map<String, dynamic>);
      if (stroke.pageIndex < 0 || stroke.pageIndex >= count || !ids.add(stroke.id)) {
        throw const FormatException('Invalid stroke page or duplicate ID');
      }
      if (stroke.surface == InkSurface.notes) {
        final area = areas[stroke.pageIndex];
        if (area == null || stroke.points.any((p) => p.x > area.width)) {
          throw const FormatException('Ink outside writing area');
        }
      }
      (annotations[stroke.pageIndex] ??= []).add(stroke);
    }
    return AppDocument(id: json['id'] as String, displayName: json['displayName'] as String,
      sourcePath: sourcePath, originalPath: json['originalPath'] as String,
      pageCount: count, modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      annotations: annotations, writingAreas: areas, penPresets: presets, selectedPenId: selected);
  }
}

class DocumentLoad {
  const DocumentLoad(this.document, {this.recovered = false});
  final AppDocument document;
  final bool recovered;
}

abstract interface class AnnotationRepository {
  Future<DocumentLoad?> load(String id);
  Future<void> save(Map<String, dynamic> snapshot);
  Future<List<AppDocument>> recent();
}
