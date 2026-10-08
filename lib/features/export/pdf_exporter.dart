import '../document/app_document.dart';

/// The next milestone implements standard PDF Ink annotations through this
/// boundary. Editing never needs access to a PDF-writing dependency.
abstract interface class PdfExporter {
  Future<void> exportAnnotatedPdf({required AppDocument document, required String outputPath});
}
