import 'dart:ui';

abstract interface class PdfEngine {
  Future<PdfDocumentHandle> open(String path);
}

abstract interface class PdfDocumentHandle {
  int get pageCount;
  List<Size> get pageSizes;
  Future<Image> renderPage({required int pageIndex, required double scale});
  Future<Image> renderTile({required int pageIndex, required Rect normalizedRegion,
    required double scale});
  Future<void> close();
}
