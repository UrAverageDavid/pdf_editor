import 'dart:ui';

import 'package:pdfrx/pdfrx.dart' as backend;

import 'pdf_engine.dart';

class PdfrxEngine implements PdfEngine {
  static Future<void> initialize() => backend.pdfrxFlutterInitialize();

  @override
  Future<PdfDocumentHandle> open(String path) async {
    final document = await backend.PdfDocument.openFile(path);
    if (document.pages.isEmpty || document.pages.any((p) =>
        !p.width.isFinite || !p.height.isFinite || p.width <= 0 || p.height <= 0)) {
      await document.dispose();
      throw const FormatException('This PDF has no usable pages or invalid page dimensions.');
    }
    return _PdfrxDocument(document);
  }
}

class _PdfrxDocument implements PdfDocumentHandle {
  _PdfrxDocument(this.document) : pageSizes = List.unmodifiable(document.pages
      .map((page) => Size(page.width, page.height)));
  final backend.PdfDocument document;
  @override
  final List<Size> pageSizes;
  @override
  int get pageCount => pageSizes.length;

  @override
  Future<Image> renderPage({required int pageIndex, required double scale}) =>
      renderTile(pageIndex: pageIndex, normalizedRegion: const Rect.fromLTWH(0, 0, 1, 1),
        scale: scale);

  @override
  Future<Image> renderTile({required int pageIndex, required Rect normalizedRegion,
      required double scale}) async {
    final page = document.pages[pageIndex];
    final fullWidth = page.width * scale;
    final fullHeight = page.height * scale;
    final rendered = await page.render(
      x: (normalizedRegion.left * fullWidth).floor(),
      y: (normalizedRegion.top * fullHeight).floor(),
      width: (normalizedRegion.width * fullWidth).ceil(),
      height: (normalizedRegion.height * fullHeight).ceil(),
      fullWidth: fullWidth, fullHeight: fullHeight,
    );
    if (rendered == null) throw StateError('Page rendering was cancelled');
    try { return await rendered.createImage(); }
    finally { rendered.dispose(); }
  }

  @override
  Future<void> close() => document.dispose();
}
