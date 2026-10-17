import '../document/app_document.dart';

/// Export a separate, shareable copy without changing the editable notebook.
abstract interface class PdfExporter {
  Future<void> exportAnnotatedPdf({required AppDocument document, required String outputPath,
    void Function(int completed, int total)? onProgress});
}
