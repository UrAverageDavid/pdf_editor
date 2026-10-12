import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/document/local_repository.dart';
import 'package:papertrail/features/document/app_document.dart';
import 'package:papertrail/features/annotations/ink.dart';

import 'helpers.dart';

void main() {
  late Directory temp;
  late LocalRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('papertrail-test-');
    repository = LocalRepository(Directory('${temp.path}/library'));
  });
  tearDown(() async { await temp.delete(recursive: true); });

  test('imports identical bytes under one ID without modifying the source', () async {
    final source = File('${temp.path}/original.pdf');
    final bytes = await File('assets/welcome.pdf').readAsBytes();
    await source.writeAsBytes(bytes);
    final id = await repository.importPdf(XFile(source.path));
    final again = await repository.importPdf(XFile(source.path));
    expect(again, id);
    expect(await source.readAsBytes(), bytes);
    expect(await File(repository.pdfPath(id)).readAsBytes(), bytes);
    await repository.verifySource(id);
    await File(repository.pdfPath(id)).writeAsString('Externally modified PDF');
    await expectLater(repository.verifySource(id), throwsFormatException);
    expect(await source.readAsBytes(), bytes);
  });

  test('restores the correct document and recovers from corrupt newest generation', () async {
    final document = sampleDocument();
    document.annotations[0] = [stroke('first')];
    await repository.save(document.toJson());
    document.annotations[0]!.add(stroke('second'));
    await repository.save(document.toJson());
    expect((await repository.load(document.id))!.document.strokeCount, 2);
    final directory = Directory('${repository.root.path}/${document.id}');
    final files = await directory.list().where((f) => f.path.endsWith('.json')).toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    await File(files.first.path).writeAsString('{corrupt');
    final recovered = await repository.load(document.id);
    expect(recovered!.recovered, isTrue);
    expect(recovered.document.strokeCount, 1);
    expect(await repository.load(List.filled(64, 'b').join()), isNull);
    expect(await File(files.first.path).exists(), isTrue);
  });

  test('a partial write cannot replace the last completed save', () async {
    final document = sampleDocument();
    document.annotations[0] = [stroke('saved')];
    await repository.save(document.toJson());
    await File('${repository.root.path}/${document.id}/notes-99999999999999999999.json.part')
      .writeAsString('incomplete');
    expect((await repository.load(document.id))!.document.annotations[0]!.single.id, 'saved');
  });

  test('writing area and ink reopen from disk without altering the PDF', () async {
    final source = File('assets/welcome.pdf');
    final bytes = await source.readAsBytes();
    final id = await repository.importPdf(XFile(source.path));
    final document = sampleDocument(id: id);
    document.writingAreas[1] = const WritingArea(width: 1.5, visible: false);
    document.annotations[1] = [InkStroke(id: 'note', pageIndex: 1,
      surface: InkSurface.notes, points: const [InkPoint(1.2, .5, .7, 0)],
      width: 2, color: 0xff000000, createdAt: DateTime.utc(2026))];
    await repository.save(document.toJson());
    final loaded = (await repository.load(id))!.document;
    expect(loaded.toJson(), document.toJson());
    expect(await File(repository.pdfPath(id)).readAsBytes(), bytes);
    expect(await source.readAsBytes(), bytes);
  });

  test('retains a bounded number of successful generations', () async {
    final document = sampleDocument();
    for (var i = 0; i < 8; i++) { await repository.save(document.toJson()); }
    final files = await Directory('${repository.root.path}/${document.id}').list().toList();
    expect(files.where((f) => f.path.endsWith('.json')).length, 3);
  });
}
