import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/pdf_viewer/document_view.dart';
import 'package:papertrail/features/pdf_viewer/pdf_engine.dart';
import 'package:papertrail/features/pdf_viewer/render_service.dart';
import 'package:papertrail/features/pdf_viewer/viewport_controller.dart';

import 'helpers.dart';

class FakePdf implements PdfDocumentHandle {
  final rendered = <int>[];
  @override
  int get pageCount => 327;
  @override
  List<Size> get pageSizes => List.filled(pageCount, const Size(612, 792));
  @override
  Future<ui.Image> renderPage({required int pageIndex, required double scale}) async {
    rendered.add(pageIndex);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    try { return picture.toImageSync(8, 8); }
    finally { picture.dispose(); }
  }
  @override
  Future<ui.Image> renderTile({required int pageIndex, required Rect normalizedRegion,
    required double scale}) => renderPage(pageIndex: pageIndex, scale: scale);
  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('touch pans without creating annotations', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final before = viewport.offset.dy;
    final touch = await tester.startGesture(const Offset(300, 400), kind: PointerDeviceKind.touch);
    await touch.moveTo(const Offset(300, 200));
    await touch.up();
    await tester.pumpAndSettle();
    expect(viewport.offset.dy, lessThan(before));
    expect(editor.document.strokeCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('large PDF is lazy; pen draws without rendering PDF again; touch never inks', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    expect(document.rendered.length, lessThan(8));
    final initialRenders = document.rendered.length;
    final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    await pen.moveTo(const Offset(300, 200));
    await pen.up();
    await tester.pump();
    expect(editor.document.strokeCount, 1);
    expect(document.rendered.length, initialRenders);
    await tester.pump(const Duration(milliseconds: 500));
    final touch = await tester.startGesture(const Offset(300, 400), kind: PointerDeviceKind.touch);
    await touch.moveTo(const Offset(300, 200));
    await touch.up();
    await tester.pumpAndSettle();
    expect(editor.document.strokeCount, 1);
    final points = editor.strokes(0).single.points;
    expect(points.every((p) => p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1), isTrue);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('touch during active pen input cannot move the canvas', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final before = viewport.offset;
    final pen = await tester.startGesture(const Offset(200, 150), pointer: 1, kind: PointerDeviceKind.stylus);
    final palm = await tester.startGesture(const Offset(300, 400), pointer: 2, kind: PointerDeviceKind.touch);
    await palm.moveTo(const Offset(300, 250));
    expect(viewport.offset, before);
    await pen.up();
    await palm.up();
    expect(editor.document.strokeCount, 1);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });
}
