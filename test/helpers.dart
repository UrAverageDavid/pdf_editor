import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/document/app_document.dart';

AppDocument sampleDocument({String? id}) => AppDocument(
  id: id ?? List.filled(64, 'a').join(), displayName: 'Test.pdf',
  sourcePath: '/tmp/source.pdf', originalPath: '/tmp/original.pdf',
  pageCount: 3, modifiedAt: DateTime.utc(2026),
);

InkStroke stroke(String id, {int page = 0}) => InkStroke(id: id, pageIndex: page,
  points: const [InkPoint(.1, .2, .5, 0), InkPoint(.8, .7, .8, 100)],
  width: 2.2, color: 0xff2947c7, createdAt: DateTime.utc(2026));

class MemoryRepository implements AnnotationRepository {
  final saves = <Map<String, dynamic>>[];
  @override
  Future<void> save(Map<String, dynamic> snapshot) async { saves.add(snapshot); }
  @override
  Future<DocumentLoad?> load(String id) async => null;
  @override
  Future<List<AppDocument>> recent() async => [];
}
