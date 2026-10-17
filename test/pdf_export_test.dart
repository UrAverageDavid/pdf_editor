import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/document/app_document.dart';
import 'package:papertrail/features/export/pdfium_pdf_exporter.dart';

// Deterministic source with searchable text, non-zero crop origins and all
// four rotations. No external PDF-generation tools are needed by the tests.
Uint8List exportFixture() {
  final objects = <String>['<< /Type /Catalog /Pages 2 0 R >>', '',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  final pages = <int>[];
  for (var i = 0; i < 5; i++) {
    final id = objects.length + 1;
    pages.add(id);
    objects.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 320] '
      '/CropBox [20 30 220 290] /Rotate ${(i % 4) * 90} '
      '/Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>');
    final content = '0 0 0 rg BT /F1 12 Tf 40 260 Td (Original page ${i + 1}) Tj ET';
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  objects[1] = '<< /Type /Pages /Count 5 /Kids [${pages.map((p) => '$p 0 R').join(' ')}] >>';
  final result = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(result.length);
    result.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = result.length;
  result.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) { result.write('${offset.toString().padLeft(10, '0')} 00000 n \n'); }
  result.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(ascii.encode(result.toString()));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    // Flutter's test executable does not link the macOS framework, but the
    // package's build hook provides this copy of the same PDFium binary.
    if (Platform.isMacOS) {
      pdf.Pdfrx.pdfiumModulePath = File('build/native_assets/macos/libpdfium.dylib').absolute.path;
    }
    await pdf.pdfrxInitialize(tmpPath: Directory.systemTemp.path);
  });
  tearDownAll(() async => pdf.PdfrxEntryFunctions.instance.stopBackgroundWorker());
  setUp(() async { temp = await Directory.systemTemp.createTemp('papertrail-export-'); });
  tearDown(() async { await temp.delete(recursive: true); });

  AppDocument document(String source) => AppDocument(id: 'test', displayName: 'fixture.pdf',
    sourcePath: source, originalPath: source, pageCount: 5, modifiedAt: DateTime.utc(2026));

  test('one writing page keeps dimensions and proportion for narrow and wide margins', () {
    const page = Size(200, 260);
    expect(exportedWritingRect(page, const WritingArea()), const Rect.fromLTWH(50, 0, 100, 260));
    expect(exportedWritingRect(page, const WritingArea(width: 2)), const Rect.fromLTWH(0, 65, 200, 130));
  });

  test('native export preserves PDF text, rotation, crop, source bytes and note order', () async {
    final source = File('${temp.path}/source.pdf');
    final sourceBytes = exportFixture();
    await source.writeAsBytes(sourceBytes);
    final doc = document(source.path);
    for (var page = 0; page < 4; page++) {
      doc.writingAreas[page] = WritingArea(width: page == 1 ? 2 : .5,
        visible: page != 1, pattern: WritingPattern.values[page % 3]);
      doc.annotations[page] = [
        InkStroke(id: 'page-$page', pageIndex: page, width: 12, color: 0xffff0000,
          points: const [InkPoint(.2, .3, .75, 0)], createdAt: DateTime.utc(2026)),
        InkStroke(id: 'marker-$page', pageIndex: page, width: 12, color: 0xffffff00,
          kind: InkKind.highlighter, points: const [InkPoint(.5, .6, .75, 0)], createdAt: DateTime.utc(2026)),
        InkStroke(id: 'notes-$page', pageIndex: page, surface: InkSurface.notes,
          width: 12, color: 0xff0000ff, points: [InkPoint(page == 1 ? 1.6 : .25, .4, .75, 0)],
          createdAt: DateTime.utc(2026)),
      ];
    }
    final before = jsonEncode(doc.toJson());
    final path = '${temp.path}/export.pdf';
    final progress = <int>[];
    await const PdfiumPdfExporter().exportAnnotatedPdf(document: doc, outputPath: path,
      onProgress: (completed, total) { expect(total, 9); progress.add(completed); });
    expect(progress, List.generate(10, (i) => i));
    expect(jsonEncode(doc.toJson()), before);
    expect(await source.readAsBytes(), orderedEquals(sourceBytes));
    final exported = await pdf.PdfDocument.openFile(path);
    final original = await pdf.PdfDocument.openFile(source.path);
    try {
      expect(exported.pages, hasLength(9));
      for (var i = 0; i < 5; i++) {
        final page = exported.pages[i * 2];
        final old = original.pages[i];
        expect(page.width, old.width);
        expect(page.height, old.height);
        expect(page.rotation, old.rotation);
        expect((await page.loadText())!.fullText, (await old.loadText())!.fullText);
        if (i == 4) continue;
        final raster = (await page.render())!;
        List<int> colorAt(pdf.PdfImage image, double x, double y) {
          final offset = ((y * image.height).floor() * image.width + (x * image.width).floor()) * 4;
          return image.pixels.sublist(offset, offset + 3); // BGRA
        }
        try {
          expect(colorAt(raster, .2, .3), [0, 0, 255], reason: 'Rotation $i ink alignment');
          final marker = colorAt(raster, .5, .6);
          expect(marker[0], inInclusiveRange(170, 185));
          expect(marker.sublist(1), [255, 255], reason: 'Marker remains translucent');
        } finally { raster.dispose(); }
        final notes = exported.pages[i * 2 + 1];
        expect(notes.width, old.width);
        expect(notes.height, old.height);
        final noteRaster = (await notes.render())!;
        try {
          expect(colorAt(noteRaster, i == 1 ? .8 : .5, i == 1 ? .45 : .4), [255, 0, 0],
            reason: 'Whole writing space, including hidden/wide notes, fits its following page');
        } finally { noteRaster.dispose(); }
      }
      final qaPath = Platform.environment['PAPERTRAIL_EXPORT_QA'];
      if (qaPath != null) {
        final qa = await Directory(qaPath).create(recursive: true);
        await File('${qa.path}/annotated.pdf').writeAsBytes(await File(path).readAsBytes());
        for (var i = 0; i < exported.pages.length; i++) {
          final raster = (await exported.pages[i].render(fullWidth: exported.pages[i].width * 2,
            fullHeight: exported.pages[i].height * 2))!;
          try {
            final image = await raster.createImage();
            try {
              final png = (await image.toByteData(format: ImageByteFormat.png))!;
              await File('${qa.path}/page-${i + 1}.png').writeAsBytes(png.buffer.asUint8List());
            } finally { image.dispose(); }
          } finally { raster.dispose(); }
        }
      }
    } finally { await exported.dispose(); await original.dispose(); }
  });

  test('export rejects overwrites and library paths, including symlinked directories', () async {
    final source = File('${temp.path}/source.pdf');
    await source.writeAsBytes(exportFixture());
    final doc = document(source.path);
    await expectLater(const PdfiumPdfExporter().exportAnnotatedPdf(document: doc, outputPath: source.path),
      throwsA(isA<FileSystemException>()));
    await expectLater(validateExportDestination(doc, '${temp.path}/new.pdf', libraryRoot: temp.path),
      throwsA(isA<FileSystemException>()));
    if (!Platform.isWindows) {
      final link = Link('${temp.path}-link');
      await link.create(temp.path);
      try {
        await expectLater(validateExportDestination(doc, '${link.path}/new.pdf', libraryRoot: temp.path),
          throwsA(isA<FileSystemException>()));
      } finally { await link.delete(); }
    }
    expect(await source.readAsBytes(), orderedEquals(exportFixture()));
  });

  test('blank hidden space is exported from a stable snapshot; plain PDF pages stay intact', () async {
    final source = File('${temp.path}/source.pdf');
    await source.writeAsBytes(exportFixture());
    final doc = document(source.path);
    doc.writingAreas[0] = const WritingArea(visible: false);
    final path = '${temp.path}/blank-space.pdf';
    await const PdfiumPdfExporter().exportAnnotatedPdf(document: doc, outputPath: path,
      onProgress: (completed, total) {
        expect(total, 6);
        if (completed == 0) doc.writingAreas.clear();
      });
    final output = await pdf.PdfDocument.openFile(path);
    final original = await pdf.PdfDocument.openFile(source.path);
    try {
      expect(output.pages, hasLength(6));
      final blank = (await output.pages[1].render())!;
      try {
        final middle = ((blank.height ~/ 2) * blank.width + blank.width ~/ 2) * 4;
        expect(blank.pixels.sublist(middle, middle + 3), [245, 253, 255]);
      } finally { blank.dispose(); }
      for (var i = 0; i < 5; i++) {
        final actual = (await output.pages[i == 0 ? 0 : i + 1].render())!;
        final expected = (await original.pages[i].render())!;
        try { expect(actual.pixels, orderedEquals(expected.pixels)); }
        finally { actual.dispose(); expected.dispose(); }
      }
    } finally { await output.dispose(); await original.dispose(); }
  });

  test('a source mismatch fails without creating a partial export', () async {
    final source = File('${temp.path}/source.pdf');
    await source.writeAsBytes(exportFixture());
    final doc = document(source.path);
    final mismatch = AppDocument.fromJson({...doc.toJson(), 'pageCount': 6}, source.path);
    final path = '${temp.path}/mismatch.pdf';
    await expectLater(const PdfiumPdfExporter().exportAnnotatedPdf(document: mismatch, outputPath: path),
      throwsA(isA<FormatException>()));
    expect(await File(path).exists(), isFalse);
  });
}
