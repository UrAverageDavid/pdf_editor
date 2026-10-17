import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:pdfium_dart/pdfium_dart.dart' as native;
import 'package:pdfrx/pdfrx.dart' as pdf;

import '../../core/page_geometry.dart';
import '../annotations/ink.dart';
import '../annotations/ink_painter.dart';
import '../document/app_document.dart';
import 'pdf_exporter.dart';

/// Preserve the source PDF's text, graphics, page boxes and rotation. Flatten
/// app ink into a transparent print-resolution overlay, using the same renderer
/// as the editor (including pressure/nibs/highlighter opacity).
class PdfiumPdfExporter implements PdfExporter {
  const PdfiumPdfExporter({this.libraryRoot});
  final String? libraryRoot;

  @override
  Future<void> exportAnnotatedPdf({required AppDocument document, required String outputPath,
      void Function(int completed, int total)? onProgress}) async {
    // Snapshot before awaiting work so edits can never mix document revisions.
    final snapshot = AppDocument.fromJson(document.toJson(), document.sourcePath);
    await validateExportDestination(snapshot, outputPath, libraryRoot: libraryRoot);
    final source = await pdf.PdfDocument.openFile(snapshot.sourcePath);
    try {
      if (source.pages.length != snapshot.pageCount) {
        throw const FormatException('The PDF page count no longer matches the notebook.');
      }
      final sizes = [for (final page in source.pages) ui.Size(page.width, page.height)];
      final total = snapshot.pageCount + snapshot.writingAreas.length;
      var completed = 0;
      onProgress?.call(completed, total);
      // Insert backwards so unprocessed source page indices stay unchanged.
      for (var index = snapshot.pageCount - 1; index >= 0; index--) {
        final size = sizes[index];
        final strokes = snapshot.annotations[index] ?? const <InkStroke>[];
        final pageInk = strokes.where((s) => s.surface == InkSurface.page).toList();
        if (pageInk.isNotEmpty) {
          final layer = await renderExportLayer(size, pageInk);
          await _attach(source, index, size, layer, insert: false);
        }
        onProgress?.call(++completed, total);
        final area = snapshot.writingAreas[index];
        if (area != null) {
          // Hidden is a viewing preference; export includes every saved margin.
          final layer = await renderExportLayer(size,
            strokes.where((s) => s.surface == InkSurface.notes).toList(), area: area);
          await _attach(source, index + 1, size, layer, insert: true, area: area);
          onProgress?.call(++completed, total);
        }
      }
      await source.reloadPages();
      final bytes = await source.encodePdf();
      if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
        throw const FormatException('The PDF could not be encoded.');
      }
      // A failed export never replaces an existing file or the imported source.
      await validateExportDestination(snapshot, outputPath, libraryRoot: libraryRoot);
      final output = File(outputPath);
      await output.create(exclusive: true);
      try { await output.writeAsBytes(bytes, flush: true); }
      catch (_) {
        await output.delete();
        rethrow;
      }
    } finally { await source.dispose(); }
  }

  Future<void> _attach(pdf.PdfDocument document, int index, ui.Size size,
      ExportLayer layer, {required bool insert, WritingArea? area}) {
    final modulePath = pdf.Pdfrx.pdfiumModulePath;
    // PDFium is not thread-safe. This API holds pdfrx's worker lock while the
    // isolated export task edits its own document, leaving the Flutter UI free.
    return document.useNativeDocumentHandle((address) => Isolate.run(() =>
      _attachLayer(modulePath, address, index, size, layer, insert, area)));
  }
}

Future<void> validateExportDestination(AppDocument document, String outputPath,
    {String? libraryRoot}) async {
  final output = File(outputPath);
  if (await FileSystemEntity.type(outputPath, followLinks: false) != FileSystemEntityType.notFound) {
    throw const FileSystemException('Choose a new filename so no existing file is replaced.');
  }
  final parent = await output.parent.resolveSymbolicLinks();
  final canonical = p.join(parent, p.basename(outputPath));
  for (final path in [document.sourcePath, document.originalPath]) {
    if (p.equals(p.normalize(p.absolute(path)), canonical)) {
      throw const FileSystemException('Choose a different filename from the source PDF.');
    }
  }
  if (libraryRoot != null) {
    final root = await Directory(libraryRoot).resolveSymbolicLinks();
    if (p.equals(root, parent) || p.isWithin(root, canonical)) {
      throw const FileSystemException('Choose a location outside the document library.');
    }
  }
}

/// Fits an entire margin onto one same-sized page, without enlarging small
/// margins or stretching handwriting. Wide margins shrink uniformly.
ui.Rect exportedWritingRect(ui.Size page, WritingArea area) {
  final scale = math.min(1.0, 1 / area.width);
  final size = ui.Size(page.width * area.width * scale, page.height * scale);
  return ui.Rect.fromLTWH((page.width - size.width) / 2,
    (page.height - size.height) / 2, size.width, size.height);
}

class ExportLayer {
  const ExportLayer(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

/// 216 dpi, bounded to 8 million pixels per layer. Never export the viewer's
/// lower-resolution scrolling cache. Original PDF content remains vector.
Future<ExportLayer> renderExportLayer(ui.Size page, List<InkStroke> strokes,
    {WritingArea? area}) async {
  final scale = math.min(3.0, math.min(math.sqrt(8000000 / (page.width * page.height)),
    8192 / math.max(page.width, page.height)));
  final width = math.max(1, (page.width * scale).floor());
  final height = math.max(1, (page.height * scale).floor());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(width / page.width, height / page.height);
  canvas.clipRect(ui.Offset.zero & page);
  if (area != null) {
    final rect = exportedWritingRect(page, area);
    final fit = math.min(1.0, 1 / area.width);
    canvas.translate(rect.left, rect.top);
    canvas.scale(fit);
    final notesSize = ui.Size(page.width * area.width, page.height);
    canvas.clipRect(ui.Offset.zero & notesSize);
  }
  for (final stroke in strokes) {
    StrokeSmoother.paint(canvas, page, stroke.points, stroke.width, ui.Color(stroke.color),
      kind: stroke.kind, shape: stroke.shape, penStyle: stroke.penStyle);
  }
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) throw StateError('Could not render export annotations.');
      return ExportLayer(width, height, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } finally { image.dispose(); }
  } finally { picture.dispose(); }
}

void _attachLayer(String? modulePath, int address, int index, ui.Size size,
    ExportLayer layer, bool insert, WritingArea? area) {
  final api = native.getPdfium(modulePath: modulePath);
  final document = native.FPDF_DOCUMENT.fromAddress(address);
  final page = insert ? api.FPDFPage_New(document, index, size.width, size.height)
    : api.FPDF_LoadPage(document, index);
  if (page == nullptr) throw StateError('Could not open export page ${index + 1}.');
  try {
    if (area != null) _addWritingPaper(api, page, size, area);
    using((arena) {
      final bounds = arena<native.FS_RECTF>();
      if (api.FPDF_GetPageBoundingBox(page, bounds) == 0) throw StateError('Invalid PDF page bounds.');
      final crop = ui.Rect.fromLTRB(bounds.ref.left, bounds.ref.bottom, bounds.ref.right, bounds.ref.top);
      final rotation = api.FPDFPage_GetRotation(page) * 90;
      final origin = normalizedToPdf(const ui.Offset(0, 1), crop, rotation);
      final x = normalizedToPdf(const ui.Offset(1, 1), crop, rotation) - origin;
      final y = normalizedToPdf(const ui.Offset(0, 0), crop, rotation) - origin;
      // PDFium expects straight BGRA, not Flutter's premultiplied RGBA.
      final bitmap = api.FPDFBitmap_CreateEx(layer.width, layer.height,
        native.FPDFBitmap_BGRA, nullptr, 0);
      if (bitmap == nullptr) throw StateError('Could not allocate export bitmap.');
      try {
        final stride = api.FPDFBitmap_GetStride(bitmap);
        final buffer = api.FPDFBitmap_GetBuffer(bitmap).cast<Uint8>().asTypedList(stride * layer.height);
        for (var row = 0; row < layer.height; row++) {
          for (var col = 0; col < layer.width; col++) {
            final src = (row * layer.width + col) * 4;
            final dst = row * stride + col * 4;
            buffer[dst] = layer.rgba[src + 2];
            buffer[dst + 1] = layer.rgba[src + 1];
            buffer[dst + 2] = layer.rgba[src];
            buffer[dst + 3] = layer.rgba[src + 3];
          }
        }
        final object = api.FPDFPageObj_NewImageObj(document);
        if (object == nullptr) throw StateError('Could not create export image.');
        var ownedByPage = false;
        try {
          if (api.FPDFImageObj_SetBitmap(nullptr, 0, object, bitmap) == 0 ||
              api.FPDFImageObj_SetMatrix(object, x.dx, x.dy, y.dx, y.dy, origin.dx, origin.dy) == 0 ||
              api.FPDFPage_InsertObject(page, object) == 0) {
            throw StateError('Could not attach annotations to the PDF.');
          }
          ownedByPage = true;
          if (api.FPDFPage_GenerateContent(page) == 0) throw StateError('Could not generate PDF content.');
        } finally { if (!ownedByPage) api.FPDFPageObj_Destroy(object); }
      } finally { api.FPDFBitmap_Destroy(bitmap); }
    });
  } finally { api.FPDF_ClosePage(page); }
}

// Keep paper guides vector: thin raster lines can disappear in PDF readers
// that downsample image objects without interpolation.
void _addWritingPaper(native.PDFium api, native.FPDF_PAGE page, ui.Size size, WritingArea area) {
  final rect = exportedWritingRect(size, area);
  final bottom = size.height - rect.bottom;
  void check(int result) { if (result == 0) throw StateError('Could not export the paper pattern.'); }
  void path(native.FPDF_PAGEOBJECT object, void Function() configure) {
    if (object == nullptr) throw StateError('Could not create writing paper.');
    var ownedByPage = false;
    try {
      configure();
      check(api.FPDFPage_InsertObject(page, object));
      ownedByPage = true;
    } finally { if (!ownedByPage) api.FPDFPageObj_Destroy(object); }
  }
  final background = api.FPDFPageObj_CreateNewRect(rect.left, bottom, rect.width, rect.height);
  path(background, () {
    check(api.FPDFPageObj_SetFillColor(background, 255, 253, 245, 255));
    check(api.FPDFPath_SetDrawMode(background, native.FPDF_FILLMODE_WINDING, 0));
  });
  if (area.pattern == WritingPattern.blank) return;
  final fit = math.min(1.0, 1 / area.width);
  final step = area.spacing.points * fit;
  final guides = api.FPDFPageObj_CreateNewPath(rect.left, bottom);
  path(guides, () {
    void line(double x1, double y1, double x2, double y2) {
      check(api.FPDFPath_MoveTo(guides, x1, size.height - y1));
      check(api.FPDFPath_LineTo(guides, x2, size.height - y2));
    }
    for (var y = rect.top; y <= rect.bottom; y += step) { line(rect.left, y, rect.right, y); }
    if (area.pattern == WritingPattern.grid) {
      for (var x = rect.left; x <= rect.right; x += step) { line(x, rect.top, x, rect.bottom); }
    }
    check(api.FPDFPageObj_SetStrokeColor(guides, 203, 211, 217, 255));
    check(api.FPDFPageObj_SetStrokeWidth(guides, .7 * fit));
    check(api.FPDFPath_SetDrawMode(guides, native.FPDF_FILLMODE_NONE, 1));
  });
}
