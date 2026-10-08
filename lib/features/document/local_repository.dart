import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import 'app_document.dart';

/// Owns imported PDF snapshots and append-only generations of annotation JSON.
/// A generation is flushed and renamed before older generations are collected.
class LocalRepository implements AnnotationRepository {
  LocalRepository(this.root);
  final Directory root;

  String pdfPath(String id) => p.join(root.path, id, 'source.pdf');

  Future<String> importPdf(XFile picked) async {
    await root.create(recursive: true);
    final temporary = File(p.join(root.path,
        'import-${DateTime.now().microsecondsSinceEpoch}.part'));
    try {
      final sink = temporary.openWrite();
      try {
        await sink.addStream(picked.openRead());
        await sink.flush();
      } finally { await sink.close(); }
      final id = await fingerprint(temporary.path);
      final destination = File(pdfPath(id));
      await destination.parent.create(recursive: true);
      if (!await destination.exists()) {
        await temporary.rename(destination.path);
      } else if (await fingerprint(destination.path) != id) {
        throw const FormatException('The stored PDF has changed. Notes were not opened.');
      }
      return id;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> verifySource(String id) async {
    if (await fingerprint(pdfPath(id)) != id) {
      throw const FormatException('The stored PDF changed. Existing notes were preserved.');
    }
  }

  @override
  Future<DocumentLoad?> load(String id) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) throw ArgumentError('Invalid document ID');
    final directory = Directory(p.join(root.path, id));
    if (!await directory.exists()) return null;
    final generations = await _generations(directory);
    var recovered = false;
    for (final file in generations) {
      try {
        final data = await Isolate.run(() => _readEnvelope(file.path));
        final document = AppDocument.fromJson(data, pdfPath(id));
        if (document.id != id) throw const FormatException('Document identity mismatch');
        return DocumentLoad(document, recovered: recovered);
      } on FormatException { recovered = true;
      } on TypeError { recovered = true;
      } on RangeError { recovered = true; }
    }
    if (generations.isNotEmpty) {
      throw const FormatException('Saved notes could not be read. The files were preserved.');
    }
    return null;
  }

  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    final rootPath = root.path;
    await Isolate.run(() => _writeGeneration(rootPath, snapshot));
  }

  @override
  Future<List<AppDocument>> recent() async {
    if (!await root.exists()) return [];
    final documents = <AppDocument>[];
    await for (final entity in root.list()) {
      if (entity is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entity.path))) {
        continue;
      }
      // Do not silently hide unreadable notes: report the failure to the library UI.
      final loaded = await load(p.basename(entity.path));
      if (loaded != null) documents.add(loaded.document);
    }
    documents.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return documents;
  }
}

Future<String> fingerprint(String path) => Isolate.run(() async =>
    (await sha256.bind(File(path).openRead()).first).toString());

Future<List<File>> _generations(Directory directory) async {
  final files = await directory.list().where((f) => f is File &&
      RegExp(r'^notes-[0-9]+\.json$').hasMatch(p.basename(f.path))).cast<File>().toList();
  files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
  return files;
}

Map<String, dynamic> _readEnvelope(String path) {
  final envelope = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final payload = envelope['payload'] as String;
  if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
    throw const FormatException('Note checksum mismatch');
  }
  return jsonDecode(payload) as Map<String, dynamic>;
}

Future<void> _writeGeneration(String root, Map<String, dynamic> snapshot) async {
  final id = snapshot['id'] as String;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) throw ArgumentError('Invalid document ID');
  final directory = Directory(p.join(root, id));
  await directory.create(recursive: true);
  final previous = await _generations(directory);
  final now = DateTime.now().microsecondsSinceEpoch;
  final last = previous.isEmpty ? 0 : int.parse(
      p.basenameWithoutExtension(previous.first.path).substring(6));
  final generation = (now > last ? now : last + 1).toString().padLeft(20, '0');
  final output = File(p.join(directory.path, 'notes-$generation.json'));
  final temp = File('${output.path}.part');
  final payload = jsonEncode(snapshot);
  try {
    await temp.writeAsString(jsonEncode({
      'sha256': sha256.convert(utf8.encode(payload)).toString(), 'payload': payload,
    }), flush: true);
    // Unique destination: no delete/replace window and portable to Windows.
    await temp.rename(output.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
  // Keep the new generation and two *valid* predecessors. Preserve corrupt
  // files for recovery/inspection; never collect the only usable backup.
  var kept = 0;
  for (final file in previous) {
    try {
      final valid = AppDocument.fromJson(_readEnvelope(file.path), '');
      if (valid.id != id) continue;
      if (++kept > 2) await file.delete();
    } on FormatException { continue;
    } on TypeError { continue;
    } on RangeError { continue;
    } on FileSystemException { continue; }
  }
}
