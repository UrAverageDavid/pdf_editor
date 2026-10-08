import '../annotations/ink.dart';

class AppDocument {
  AppDocument({required this.id, required this.displayName, required this.sourcePath,
    required this.originalPath, required this.pageCount, required this.modifiedAt,
    Map<int, List<InkStroke>>? annotations})
      : annotations = annotations ?? {};

  final String id; // Full SHA-256 of the immutable imported PDF.
  final String displayName;
  final String sourcePath;
  final String originalPath;
  final int pageCount;
  DateTime modifiedAt;
  final Map<int, List<InkStroke>> annotations;
  int get strokeCount => annotations.values.fold(0, (n, strokes) => n + strokes.length);

  Map<String, dynamic> toJson() => {
    'schema': 1, 'id': id, 'displayName': displayName, 'originalPath': originalPath,
    'pageCount': pageCount, 'modifiedAt': modifiedAt.toIso8601String(),
    'strokes': annotations.values.expand((s) => s).map((s) => s.toJson()).toList(),
  };

  factory AppDocument.fromJson(Map<String, dynamic> json, String sourcePath) {
    if (json['schema'] != 1) throw const FormatException('Unsupported note format');
    final count = json['pageCount'] as int;
    if (count < 1) throw const FormatException('Invalid page count');
    final annotations = <int, List<InkStroke>>{};
    final ids = <String>{};
    for (final item in json['strokes'] as List<dynamic>) {
      final stroke = InkStroke.fromJson(item as Map<String, dynamic>);
      if (stroke.pageIndex < 0 || stroke.pageIndex >= count || !ids.add(stroke.id)) {
        throw const FormatException('Invalid stroke page or duplicate ID');
      }
      (annotations[stroke.pageIndex] ??= []).add(stroke);
    }
    return AppDocument(id: json['id'] as String, displayName: json['displayName'] as String,
      sourcePath: sourcePath, originalPath: json['originalPath'] as String,
      pageCount: count, modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      annotations: annotations);
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
