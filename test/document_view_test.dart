import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/editor_controller.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/ink_painter.dart';
import 'package:papertrail/features/document/app_document.dart';
import 'package:papertrail/app/editor_screen.dart';
import 'package:papertrail/features/pdf_viewer/document_view.dart';
import 'package:papertrail/features/pdf_viewer/pdf_engine.dart';
import 'package:papertrail/features/pdf_viewer/render_service.dart';
import 'package:papertrail/features/pdf_viewer/viewport_controller.dart';
import 'package:papertrail/features/pdf_viewer/writing_paper_painter.dart';

import 'helpers.dart';

class PaintCountingEditor extends EditorController {
  PaintCountingEditor(super.document, super.repository);
  int firstPageReads = 0;
  @override
  List<InkStroke> strokes(int page) {
    if (page == 0) firstPageReads++;
    return super.strokes(page);
  }
}

class FakePdf implements PdfDocumentHandle {
  final rendered = <int>[];
  final tiles = <({int page, double scale, Rect region})>[];
  @override
  int get pageCount => 327;
  @override
  List<Size> get pageSizes => List.filled(pageCount, const Size(612, 792));
  @override
  Future<ui.Image> renderPage({required int pageIndex, required double scale}) async {
    rendered.add(pageIndex);
    return _image();
  }
  ui.Image _image() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    try { return picture.toImageSync(8, 8); }
    finally { picture.dispose(); }
  }
  @override
  Future<ui.Image> renderTile({required int pageIndex, required Rect normalizedRegion,
    required double scale}) async {
    tiles.add((page: pageIndex, scale: scale, region: normalizedRegion));
    return _image();
  }
  @override
  Future<void> close() async {}
}

List<ui.Picture> recordedPictures(ContainerLayer root) {
  final pictures = <ui.Picture>[];
  for (var child = root.firstChild; child != null; child = child.nextSibling) {
    if (child is PictureLayer && child.picture != null) pictures.add(child.picture!);
    if (child is ContainerLayer) pictures.addAll(recordedPictures(child));
  }
  return pictures;
}

void main() {
  testWidgets('continuous zoom reuses stroke paths and defers PDF tiles until settling', (tester) async {
    final pdf = FakePdf();
    final renders = RenderService(pdf);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    editor.document.annotations[0] = List.generate(100, (i) => InkStroke(
      id: 'zoom-$i', pageIndex: 0, width: 2, color: 0xff2947c7,
      createdAt: DateTime.utc(2026), points: List.generate(128, (p) => InkPoint(
        .1 + p * .005, .05 + i * .008, .75, p))));
    final viewport = ViewportController(pdf.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final cache = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter).whereType<CommittedInkPainter>()
      .firstWhere((p) => p.page == 0).cache!;
    final recorded = cache.debugRecordedStrokes;
    final rasterized = cache.debugRasterizations;
    final rendersBefore = pdf.rendered.length;
    final tilesBefore = pdf.tiles.length;
    for (var i = 1; i <= 20; i++) {
      viewport.setZoom(1 + i * .04);
      await tester.pump(const Duration(milliseconds: 8));
      final mountedCache = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter).whereType<CommittedInkPainter>()
        .firstWhere((p) => p.page == 0).cache!;
      expect(mountedCache, same(cache));
      expect(cache.debugRecordedStrokes, recorded);
      expect(cache.debugRasterizations, rasterized);
      expect(pdf.rendered.length, rendersBefore);
      expect(pdf.tiles.length, tilesBefore);
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(cache.debugRecordedStrokes, recorded);
    expect(cache.debugTileCount, inInclusiveRange(1, CommittedInkCache.maxTileRasterPixels ~/ (514 * 514)));
    expect(pdf.tiles.length, greaterThan(tilesBefore));
    final dpr = tester.view.devicePixelRatio;
    for (final tile in pdf.tiles.skip(tilesBefore)) {
      expect(tile.scale, viewport.scale * dpr);
      expect(tile.region.width * 612 * tile.scale, lessThanOrEqualTo(514.001));
      expect(tile.region.height * 792 * tile.scale, lessThanOrEqualTo(514.001));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    editor.dispose();
    viewport.dispose();
  });

  testWidgets('document options exposes PDF export and commits active input first', (tester) async {
    final renders = RenderService(FakePdf());
    final editor = EditorController(sampleDocument(), MemoryRepository());
    var exportedStrokeCount = -1;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
      editor: editor, renders: renders, onOpen: () {}, onBack: () {},
      onExport: () => exportedStrokeCount = editor.document.strokeCount))));
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byType(DocumentView));
    final pen = await tester.startGesture(canvas.topLeft + const Offset(150, 100),
      kind: PointerDeviceKind.stylus);
    await pen.moveBy(const Offset(40, 20));
    await tester.tap(find.byTooltip('Document options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export annotated PDF…'));
    await tester.pumpAndSettle();
    expect(exportedStrokeCount, 1);
    await pen.up();
    expect(editor.document.strokeCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    editor.dispose();
  });

  for (final pattern in [WritingPattern.blank, WritingPattern.grid]) {
    testWidgets('$pattern paper surface is retained during scrolling; offscreen notes are lazy', (tester) async {
      final document = FakePdf();
      final renders = RenderService(document);
      final saved = sampleDocument();
      for (var page = 0; page < 3; page++) {
        saved.writingAreas[page] = WritingArea(pattern: pattern);
      }
      final editor = EditorController(saved, MemoryRepository());
      final viewport = ViewportController(document.pageSizes);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
        editor: editor, renders: renders, viewport: viewport))));
      viewport.revealWritingArea(0);
      await tester.pumpAndSettle();
      final paper = tester.renderObject<RenderDecoratedBox>(find.descendant(
        of: find.byKey(const ValueKey('notes-0')), matching: find.byType(DecoratedBox)).first);
      var paperPaints = 0;
      final previousPaintCallback = debugOnProfilePaint;
      debugOnProfilePaint = (object) {
        previousPaintCallback?.call(object);
        if (identical(object, paper)) paperPaints++;
      };
      final pdfRenders = document.rendered.length;
      try {
        for (var i = 0; i < 30; i++) {
          viewport.pan(const Offset(0, -.73));
          await tester.pump();
        }
      } finally {
        debugOnProfilePaint = previousPaintCallback;
      }
      expect(paperPaints, 0,
        reason: 'Scrolling must retain the entire paper surface, including its background and border');
      expect(find.byKey(const ValueKey('notes-1')), findsNothing);
      expect(find.byKey(const ValueKey('notes-2')), findsNothing);
      expect(document.rendered.length, pdfRenders);
      viewport.jumpTo(1);
      viewport.revealWritingArea(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-0')), findsNothing);
      expect(find.byKey(const ValueKey('notes-1')), findsOneWidget);
      // Culling a margin must not hide or delete it in the saved document.
      expect(saved.writingAreas[0]!.visible, isTrue);
      viewport.jumpTo(0);
      viewport.revealWritingArea(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      viewport.dispose();
      editor.dispose();
    });
  }

  testWidgets('writing-space menu animation does not repaint the document surface', (tester) async {
    final renders = RenderService(FakePdf());
    final saved = sampleDocument()..writingAreas[0] = const WritingArea();
    final editor = EditorController(saved, MemoryRepository());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
      editor: editor, renders: renders, onOpen: () {}, onBack: () {}))));
    await tester.pumpAndSettle();
    final surface = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('document-surface')));
    final pictures = recordedPictures(surface.debugLayer!);
    expect(pictures, isNotEmpty);
    await tester.tap(find.byTooltip('Writing space for page 1'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Hide writing space (keep notes)'), findsOneWidget);
    expect(recordedPictures(surface.debugLayer!), orderedEquals(pictures),
      reason: 'Opening the menu must reuse all document display lists');
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    editor.dispose();
  });

  testWidgets('fractional scrolling reuses ink geometry without rasterizing during movement', (tester) async {
    final renders = RenderService(FakePdf());
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea(pattern: WritingPattern.grid);
    final editor = PaintCountingEditor(saved, MemoryRepository());
    saved.annotations[0] = [
      for (final surface in InkSurface.values)
        for (var i = 0; i < 40; i++) InkStroke(id: '${surface.name}-$i', pageIndex: 0,
          surface: surface, width: 2, color: 0xff2947c7, createdAt: DateTime.utc(2026),
          points: List.generate(128, (p) => InkPoint(
            .05 + .4 * p / 128, .1 + i * .015 + (p % 7) * .001, .75, p * 4167))),
    ];
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    viewport.setZoom(.65);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('page-0'));
    final notes = find.byKey(const ValueKey('notes-0'));
    final pageSize = tester.getSize(page);
    final notesSize = tester.getSize(notes);
    final inkCaches = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter).whereType<CommittedInkPainter>()
      .where((p) => p.page == 0).map((p) => p.cache!).toList();
    final rasterizations = [for (final cache in inkCaches) cache.debugRasterizations];
    final tileDraws = [for (final cache in inkCaches) cache.debugTileDraws];
    final images = [for (final cache in inkCaches) cache.debugImage];
    expect(inkCaches.every((cache) => cache.debugPictureCount > 0), isTrue);
    final recordings = [for (final cache in inkCaches) cache.debugRecordedStrokes];
    editor.firstPageReads = 0;
    for (var i = 0; i < 100; i++) {
      viewport.pan(Offset(i.isEven ? -.37 : .37, -.73));
      await tester.pump();
      expect(tester.getSize(page), pageSize);
      expect(tester.getSize(notes), notesSize);
    }
    expect([for (final cache in inkCaches) cache.debugRecordedStrokes], recordings,
      reason: 'Scrolling must reuse the retained document geometry');
    expect([for (final cache in inkCaches) cache.debugRasterizations], rasterizations);
    for (var i = 0; i < inkCaches.length; i++) {
      expect(inkCaches[i].debugTileDraws, greaterThan(tileDraws[i]),
        reason: 'Panning must draw the cached pixels, not replay all saved vectors');
    }
    expect([for (final cache in inkCaches) cache.debugImage], orderedEquals(images),
      reason: 'Scrolling must retain each surface cache, including vector fallbacks');
    editor.firstPageReads = 0;
    editor.addStroke(stroke('page-only'));
    await tester.pump();
    expect(editor.firstPageReads, 1, reason: 'A PDF edit must not repaint note ink');
    editor.firstPageReads = 0;
    editor.addStroke(InkStroke(id: 'note-only', pageIndex: 0, surface: InkSurface.notes,
      points: const [InkPoint(.1, .2, .8, 0)], width: 2, color: 0xff000000,
      createdAt: DateTime.utc(2026)));
    await tester.pump();
    expect(editor.firstPageReads, 1, reason: 'A note edit must not repaint PDF ink');
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('sustained note writing batches layout growth and fits exactly on release', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea(pattern: WritingPattern.grid);
    final editor = EditorController(saved, repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    viewport.setZoom(.45);
    viewport.revealWritingArea(0);
    await tester.pumpAndSettle();
    final initialNotes = viewport.screenRect(viewport.layout.notes[0]);
    final initialPage = viewport.pageRect(0);
    final start = Offset(initialNotes.right - 60, initialNotes.top + 100);
    var layoutUpdates = 0;
    viewport.addListener(() => layoutUpdates++);
    final pen = await tester.startGesture(start, kind: PointerDeviceKind.stylus);
    await tester.pump();
    for (var i = 1; i <= 48; i++) {
      final point = start + Offset(i * 3, i * .5);
      await pen.moveTo(point, timeStamp: Duration(milliseconds: i * 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(viewport.screenRect(viewport.layout.notes[0]).right - point.dx,
        greaterThanOrEqualTo(40));
      expect(viewport.pageRect(0), initialPage);
    }
    expect(layoutUpdates, lessThanOrEqualTo(3),
      reason: 'Growing notes must not rebuild the document on every ink frame');
    expect(editor.document.writingAreas[0]!.width, .5);
    expect(repository.saves, isEmpty);
    await pen.up();
    await tester.pump();
    final stroke = editor.strokes(0).single;
    final right = stroke.points.fold<double>(0, (x, p) => p.x > x ? p.x : x) * 612 + stroke.width * .85;
    expect(viewport.layout.notes[0].width * viewport.scale - right * viewport.scale,
      closeTo(40, 1e-8));
    expect(stroke.points.last.x, greaterThan(.5));
    editor.undo();
    expect(editor.document.writingAreas[0]!.width, .5);
    expect(editor.strokes(0), isEmpty);
    editor.redo();
    await editor.flush();
    expect(AppDocument.fromJson(repository.saves.last, '').annotations[0]!.single.toJson(), stroke.toJson());
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('Windows commits confirmed native samples before saving', (tester) async {
    const channel = MethodChannel('papertrail/wet_ink');
    final reply = Completer<Object?>();
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'begin') return true;
      if (call.method == 'freeze') return reply.future;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    await tester.pump();
    await pen.moveTo(const Offset(230, 170), timeStamp: const Duration(milliseconds: 16));
    await pen.up();
    final initial = editor.strokes(0).single;
    final saving = editor.flush();
    await tester.pump();
    expect(repository.saves, isEmpty);
    expect(calls.where((c) => c.method == 'retire'), isEmpty);
    reply.complete([[.2, .3, .7, 0], [.25, .35, .8, 16000]]);
    await tester.pump();
    await saving;
    await tester.pump();
    final confirmed = editor.strokes(0).single;
    expect(confirmed.id, initial.id);
    expect(confirmed.points.map((p) => p.toJson()), [[.2, .3, .7, 0], [.25, .35, .8, 16000]]);
    expect(AppDocument.fromJson(repository.saves.last, '').annotations[0]!.single.toJson(), confirmed.toJson());
    expect(calls.where((c) => c.method == 'retire'), hasLength(1));
    editor.undo();
    expect(editor.strokes(0), isEmpty);
    await tester.pump();
    expect(calls.where((c) => c.method == 'discard'), hasLength(1));
    editor.redo();
    expect(editor.strokes(0).single, same(confirmed));
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  for (final nativeAccepted in [true, false]) {
    testWidgets('Windows wet ink preserves saved samples (accepted: $nativeAccepted)', (tester) async {
      const channel = MethodChannel('papertrail/wet_ink');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'begin' ? nativeAccepted : null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final renders = RenderService(FakePdf());
      final editor = EditorController(sampleDocument(), MemoryRepository());
      final viewport = ViewportController(renders.document.pageSizes);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Padding(
        padding: const EdgeInsets.only(left: 30, top: 50),
        child: DocumentView(editor: editor, renders: renders, viewport: viewport)))));
      await tester.pumpAndSettle();
      final ink = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter).whereType<ActiveInkPainter>().first.ink;
      final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
      await tester.pump();
      expect(ink.nativePreview, nativeAccepted);
      final args = calls.singleWhere((c) => c.method == 'begin').arguments as Map;
      final dpr = tester.view.devicePixelRatio;
      expect(args['x'], 200 * dpr);
      expect(args['y'], 150 * dpr);
      expect((args['clip'] as List)[1], greaterThanOrEqualTo(50 * dpr));
      for (var i = 1; i <= 10; i++) {
        await pen.moveTo(Offset(200 + i * 3, 150 + i * 2),
          timeStamp: Duration(milliseconds: i * 8));
      }
      expect(ink.points.length, greaterThan(5));
      final observed = List<InkPoint>.of(ink.points);
      await pen.up();
      await tester.pump();
      expect(ink.nativePreview, isFalse);
      final saved = editor.strokes(0).single;
      expect(saved.points.take(observed.length), orderedEquals(observed));
      expect(calls.where((c) => c.method == 'begin'), hasLength(1));
      expect(calls.where((c) => c.method == 'freeze'), hasLength(nativeAccepted ? 1 : 0));
      expect(calls.where((c) => c.method == 'retire'), hasLength(nativeAccepted ? 1 : 0));
      final beginCount = calls.where((c) => c.method == 'begin').length;
      final mouse = await tester.startGesture(const Offset(250, 200), kind: PointerDeviceKind.mouse);
      await mouse.up();
      editor.setTool(EditorTool.eraser);
      final eraser = await tester.startGesture(const Offset(250, 200), kind: PointerDeviceKind.stylus);
      await eraser.up();
      editor.setTool(EditorTool.hand);
      final hand = await tester.startGesture(const Offset(250, 200), kind: PointerDeviceKind.stylus);
      await hand.up();
      expect(calls.where((c) => c.method == 'begin'), hasLength(beginCount));
      await editor.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      viewport.dispose();
      editor.dispose();
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }

  testWidgets('stylus prediction expires while held and never enters saved strokes', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final ink = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter).whereType<ActiveInkPainter>().first.ink;
    final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    await pen.moveTo(const Offset(205, 150), timeStamp: const Duration(milliseconds: 10));
    await pen.moveTo(const Offset(210, 150), timeStamp: const Duration(milliseconds: 20));
    await tester.pump();
    expect(ink.prediction, hasLength(2));
    expect(ink.prediction.last.x, greaterThan(ink.points.last.x));
    final actualCount = ink.points.length;
    await tester.pump(const Duration(milliseconds: 40));
    expect(ink.prediction, isEmpty);
    expect(ink.points, hasLength(actualCount));
    for (var i = 0; i < 3; i++) {
      await pen.moveTo(Offset(215.0 + 5 * i, 150), timeStamp: Duration(milliseconds: 70 + 10 * i));
    }
    expect(ink.prediction, isNotEmpty);
    final predictedX = ink.prediction.last.x;
    await pen.up();
    expect(ink.prediction, isEmpty);
    final stroke = editor.strokes(0).single;
    expect(stroke.points.every((point) => point.x < predictedX), isTrue);
    final lastInput = viewport.toDocument(const Offset(225, 150)) - viewport.layout.pages[0].topLeft;
    expect(stroke.points.last.x, closeTo(lastInput.dx / viewport.layout.pages[0].width, .000001));
    await editor.flush();
    final restored = AppDocument.fromJson(repository.saves.last, '');
    expect(restored.annotations[0]!.single.points.last.x, stroke.points.last.x);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  for (final ending in ['cancel', 'focus loss', 'dispose']) {
    testWidgets('prediction clears safely on $ending', (tester) async {
      final renders = RenderService(FakePdf());
      final editor = EditorController(sampleDocument(), MemoryRepository());
      final viewport = ViewportController(renders.document.pageSizes);
      final key = GlobalKey<DocumentViewState>();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
        key: key, editor: editor, renders: renders, viewport: viewport))));
      await tester.pumpAndSettle();
      final ink = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter).whereType<ActiveInkPainter>().first.ink;
      final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
      await pen.moveTo(const Offset(205, 150), timeStamp: const Duration(milliseconds: 10));
      await pen.moveTo(const Offset(210, 150), timeStamp: const Duration(milliseconds: 20));
      expect(ink.prediction, isNotEmpty);
      if (ending == 'cancel') { await pen.cancel(); }
      if (ending == 'focus loss') {
        key.currentState!.didChangeAppLifecycleState(AppLifecycleState.inactive);
      }
      if (ending != 'dispose') { expect(ink.prediction, isEmpty); }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await renders.close();
      viewport.dispose();
      editor.dispose();
    });
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets('writing space paper menu sets lines, grids and sizes at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final renders = RenderService(FakePdf());
      final repository = MemoryRepository();
      final editor = EditorController(sampleDocument(), repository);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
        editor: editor, renders: renders, onOpen: () {}, onBack: () {}))));
      await tester.pumpAndSettle();
      Future<void> choose(String label) async {
        await tester.tap(find.byTooltip('Writing space for page 1'));
        await tester.pumpAndSettle();
        final item = find.widgetWithText(CheckedPopupMenuItem<String>, label);
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
      }
      WritingPaperPainter paper() => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter).whereType<WritingPaperPainter>().first;
      await choose('Grid');
      expect(editor.document.writingAreas[0]!.visible, isTrue);
      expect(paper().pattern, WritingPattern.grid);
      await choose('Small (12 pt)');
      expect(paper().spacing, WritingSpacing.small);
      await choose('Ruled lines');
      expect(paper().pattern, WritingPattern.ruled);
      await choose('Large (32 pt)');
      expect(paper().spacing, WritingSpacing.large);
      await choose('Blank');
      expect(paper().pattern, WritingPattern.blank);
      expect(editor.document.writingAreas[1], isNull);
      await editor.flush();
      final restored = AppDocument.fromJson(repository.saves.last, '');
      expect(restored.writingAreas[0]!.pattern, WritingPattern.blank);
      expect(restored.writingAreas[0]!.spacing, WritingSpacing.large);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      editor.dispose();
    });
  }

  for (final zoom in [.45, 1.5]) {
    testWidgets('writing space keeps 40 screen pixels clear at zoom $zoom and grows with one undo step', (tester) async {
      final renders = RenderService(FakePdf());
      final repository = MemoryRepository();
      final saved = sampleDocument();
      saved.writingAreas[0] = const WritingArea(pattern: WritingPattern.grid, spacing: WritingSpacing.small);
      final editor = EditorController(saved, repository);
      final viewport = ViewportController(renders.document.pageSizes);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
        editor: editor, renders: renders, viewport: viewport))));
      await tester.pumpAndSettle();
      viewport.setZoom(zoom);
      viewport.revealWritingArea(0);
      await tester.pumpAndSettle();
      final originalPage = viewport.pageRect(0);
      final originalNotes = viewport.screenRect(viewport.layout.notes[0]);
      final originalOffset = viewport.offset;
      final start = Offset(originalNotes.right - 20, (originalNotes.top + 80).clamp(80.0, 500.0).toDouble());
      var notifications = 0;
      editor.addListener(() => notifications++);
      final pen = await tester.startGesture(start, kind: PointerDeviceKind.stylus);
      await tester.pump();
      expect(viewport.screenRect(viewport.layout.notes[0]).right - start.dx, greaterThanOrEqualTo(40));
      expect(viewport.pageRect(0), originalPage);
      expect(viewport.offset, originalOffset);
      final end = Offset(originalNotes.right + 10, start.dy + 15);
      await pen.moveTo(end);
      await tester.pump();
      expect(viewport.screenRect(viewport.layout.notes[0]).right - end.dx, greaterThanOrEqualTo(40));
      expect(viewport.pageRect(0), originalPage);
      expect(editor.document.writingAreas[0]!.width, .5); // Growth is transient while writing.
      expect(editor.document.strokeCount, 0);
      expect(notifications, 0);
      expect(repository.saves, isEmpty);
      await pen.up();
      await tester.pump();
      final expanded = editor.document.writingAreas[0]!.width;
      final ink = editor.strokes(0).single;
      expect(expanded, greaterThan(.5));
      expect(ink.surface, InkSurface.notes);
      expect(ink.points.last.x, greaterThan(.5)); // Crossing the old edge did not end the stroke.
      final endpoint = viewport.screenRect(viewport.layout.notes[0]).topLeft +
        ink.points.last.inSize(viewport.layout.pages[0].size) * viewport.scale;
      expect((endpoint - end).distance, lessThan(.001));
      expect(viewport.offset, originalOffset);
      editor.undo();
      expect(editor.strokes(0), isEmpty);
      expect(editor.document.writingAreas[0]!.width, .5);
      expect(editor.canUndo, isFalse);
      editor.redo();
      expect(editor.document.writingAreas[0]!.width, expanded);
      expect(editor.strokes(0).single.toJson(), ink.toJson());
      await tester.pump(const Duration(seconds: 1));
      expect(repository.saves, hasLength(1));
      final reopened = AppDocument.fromJson(repository.saves.single, '');
      expect(reopened.writingAreas[0]!.width, expanded);
      expect(reopened.writingAreas[0]!.pattern, WritingPattern.grid);
      expect(reopened.writingAreas[0]!.spacing, WritingSpacing.small);
      expect(reopened.annotations[0]!.single.toJson(), ink.toJson());
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      viewport.dispose();
      editor.dispose();
    });
  }

  testWidgets('writing space shrinks to 40 px around all notes and shrinks after erasing', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea(width: 1, pattern: WritingPattern.ruled, spacing: WritingSpacing.large);
    InkStroke note(String id, double x, double y) => InkStroke(id: id, pageIndex: 0,
      surface: InkSurface.notes, points: [InkPoint(x - .05, y - .05, .75, 0), InkPoint(x, y, .75, 1)],
      width: 4, color: 0xff2947c7, createdAt: DateTime.utc(2026));
    final far = note('far', .7, .3);
    final near = note('near', .2, .55);
    saved.annotations[0] = [near, far];
    final editor = EditorController(saved, repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    viewport.setZoom(.45);
    await tester.pumpAndSettle();
    Offset point(double x, double y) => viewport.screenRect(viewport.layout.notes[0]).topLeft +
      Offset(x * 612, y * 792) * viewport.scale;
    double gap(InkStroke ink) => viewport.screenRect(viewport.layout.notes[0]).right -
      (point(ink.points.last.x, ink.points.last.y).dx + ink.width * .85 * viewport.scale);
    final originalOffset = viewport.offset;
    final originalPage = viewport.pageRect(0);
    final pen = await tester.startGesture(point(.08, .7), kind: PointerDeviceKind.stylus);
    await pen.moveTo(point(.12, .72));
    await tester.pump();
    expect(gap(far), closeTo(40, 1e-8));
    expect(viewport.layout.notes[0].width, lessThan(612));
    expect(viewport.pageRect(0), originalPage);
    expect(viewport.offset, originalOffset);
    expect(editor.document.writingAreas[0]!.width, 1);
    expect(repository.saves, isEmpty);
    await pen.up();
    await tester.pump();
    final fitted = editor.document.writingAreas[0]!.width;
    expect(fitted, lessThan(1));
    expect(gap(far), closeTo(40, 1e-8));
    editor.undo();
    expect(editor.document.writingAreas[0]!.width, 1);
    expect(editor.strokes(0), [near, far]);
    editor.redo();
    expect(editor.document.writingAreas[0]!.width, fitted);
    await tester.pump();
    editor.setTool(EditorTool.eraser);
    final beforeErase = viewport.offset;
    final erase = await tester.startGesture(point(.7, .3), kind: PointerDeviceKind.stylus);
    await erase.up();
    await tester.pump();
    expect(editor.strokes(0).any((stroke) => stroke.id == 'far'), isFalse);
    expect(editor.document.writingAreas[0]!.width, lessThan(fitted));
    expect(gap(near), greaterThanOrEqualTo(40));
    expect(editor.document.writingAreas[0]!.width, WritingArea.minimumWidth);
    expect(viewport.offset, beforeErase);
    editor.undo();
    expect(editor.document.writingAreas[0]!.width, fitted);
    expect(editor.strokes(0).any((stroke) => stroke.id == 'far'), isTrue);
    editor.redo();
    await editor.flush();
    final loaded = AppDocument.fromJson(repository.saves.last, '');
    expect(loaded.writingAreas[0]!.width, editor.document.writingAreas[0]!.width);
    expect(loaded.writingAreas[0]!.pattern, WritingPattern.ruled);
    expect(loaded.writingAreas[0]!.spacing, WritingSpacing.large);
    expect(loaded.annotations[0]!.map((s) => s.toJson()), editor.strokes(0).map((s) => s.toJson()));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('empty and lightly used margins stay at least half a page wide', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea(width: 1);
    final editor = EditorController(saved, repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    viewport.setZoom(.45);
    await tester.pumpAndSettle();
    final start = viewport.screenRect(viewport.layout.notes[0]).topLeft +
      const Offset(30, 100) * viewport.scale;
    final pen = await tester.startGesture(start, kind: PointerDeviceKind.stylus);
    await tester.pump();
    expect(viewport.layout.notes[0].width, 306);
    await pen.up();
    await tester.pump();
    expect(editor.document.writingAreas[0]!.width, WritingArea.minimumWidth);
    editor.setTool(EditorTool.eraser);
    final eraser = await tester.startGesture(start, kind: PointerDeviceKind.stylus);
    await eraser.up();
    await tester.pump();
    expect(editor.strokes(0), isEmpty);
    expect(viewport.layout.notes[0].width, 306);
    expect(editor.document.writingAreas[0]!.width, WritingArea.minimumWidth);
    await editor.flush();
    final reopened = AppDocument.fromJson(repository.saves.last, '');
    expect(reopened.writingAreas[0]!.width, WritingArea.minimumWidth);
    expect(reopened.strokeCount, 0);
    editor.undo();
    expect(editor.strokes(0), hasLength(1));
    editor.undo();
    expect(editor.document.writingAreas[0]!.width, 1);
    expect(editor.strokes(0), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('hover, erasing, touch, and PDF strokes do not expand writing space', (tester) async {
    final renders = RenderService(FakePdf());
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea();
    final editor = EditorController(saved, MemoryRepository());
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    viewport.setZoom(viewport.fitWidthZoom);
    await tester.pumpAndSettle();
    final edge = viewport.screenRect(viewport.layout.notes[0]).topRight + const Offset(-10, 80);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: edge);
    await mouse.moveTo(edge + const Offset(-1, 1));
    expect(viewport.layout.notes[0].width, 306);
    await mouse.removePointer();
    editor.setTool(EditorTool.eraser);
    final eraser = await tester.startGesture(edge, kind: PointerDeviceKind.stylus);
    await eraser.moveTo(edge + const Offset(-10, 10));
    await eraser.up();
    expect(viewport.layout.notes[0].width, 306);
    await tester.pump(const Duration(milliseconds: 200));
    final touch = await tester.startGesture(edge, kind: PointerDeviceKind.touch);
    await touch.moveTo(edge + const Offset(-10, 10));
    await touch.up();
    expect(viewport.layout.notes[0].width, 306);
    editor.setTool(EditorTool.pen);
    final pageEdge = viewport.pageRect(0).topRight + const Offset(-10, 80);
    final pen = await tester.startGesture(pageEdge, kind: PointerDeviceKind.stylus);
    await pen.moveTo(pageEdge + const Offset(20, 10));
    await pen.up();
    expect(viewport.layout.notes[0].width, 306);
    expect(editor.strokes(0).single.surface, InkSurface.page);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('continuous pen movement postpones autosave until one second after lift', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final first = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    await first.moveTo(const Offset(250, 160));
    await first.up();
    await tester.pump(const Duration(milliseconds: 700));
    final second = await tester.startGesture(const Offset(200, 200), kind: PointerDeviceKind.stylus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 700));
      await second.moveTo(Offset(230 + i * 20, 210));
      expect(repository.saves, isEmpty);
    }
    await second.up();
    await tester.pump(const Duration(milliseconds: 999));
    expect(repository.saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.saves, hasLength(1));
    expect((repository.saves.single['strokes'] as List<dynamic>), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('keyboard and hover input defer pending autosave', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    editor.addStroke(stroke('pending'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 700));
    expect(repository.saves, isEmpty);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(200, 150));
    await mouse.moveTo(const Offset(210, 160));
    await tester.pump(const Duration(milliseconds: 999));
    expect(repository.saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.saves, hasLength(1));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('anchored pen settings validate, update ink and preserve independent tool sizes', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
      editor: editor, renders: renders, onOpen: () {}, onBack: () {}))));
    await tester.pumpAndSettle();
    final picker = find.byKey(const ValueKey('pen-preset-fountain'));
    Future<void> openPicker() async {
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
    }
    await openPicker();
    expect(find.byType(AlertDialog), findsNothing);
    final popup = tester.getRect(find.byKey(const ValueKey('pen-settings-popover')));
    expect(popup.width, lessThanOrEqualTo(304));
    expect(popup.top, greaterThanOrEqualTo(tester.getRect(picker).bottom));
    final input = find.byKey(const ValueKey('tip-size-input'));
    await tester.enterText(input, '0');
    await tester.pump();
    expect(find.text('Enter 0.1–8 pt'), findsOneWidget);
    expect(editor.width, 2.2);
    await tester.enterText(input, 'NaN');
    await tester.pump();
    expect(find.text('Enter 0.1–8 pt'), findsOneWidget);
    expect(editor.width, 2.2);
    await tester.enterText(input, '0.25');
    await tester.pump();
    await tester.tap(find.byTooltip('Close pen settings'));
    await tester.pumpAndSettle();
    expect(editor.width, .25);
    expect(find.text('0.25 pt'), findsNothing);
    final pen = await tester.startGesture(const Offset(200, 250), kind: PointerDeviceKind.stylus);
    await pen.moveTo(const Offset(320, 260));
    await pen.up();
    await tester.pump();
    expect(editor.strokes(0).single.width, .25);
    expect(editor.strokes(0).single.penStyle!.toJson(), editor.penStyle.toJson());
    await editor.flush();
    expect(AppDocument.fromJson(repository.saves.last, '/source.pdf').annotations[0]!.single.width, .25);
    final highlighterPreset = find.byKey(const ValueKey('pen-preset-highlighter'));
    await tester.ensureVisible(highlighterPreset);
    await tester.tap(highlighterPreset);
    await tester.pumpAndSettle();
    final highlighterPicker = highlighterPreset;
    await tester.ensureVisible(highlighterPicker);
    await tester.tap(highlighterPicker);
    await tester.pumpAndSettle();
    expect(find.text('Highlighter'), findsWidgets);
    await tester.enterText(input, '24');
    await tester.pump();
    await tester.tapAt(const Offset(10, 580));
    await tester.pumpAndSettle();
    expect(editor.width, 24);
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(editor.width, .25);
    expect(find.text('0.25 pt'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    editor.dispose();
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets('drawing palette is usable at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final renders = RenderService(FakePdf());
      final editor = EditorController(sampleDocument(), MemoryRepository());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
        editor: editor, renders: renders, onOpen: () {}, onBack: () {}))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final fineTip = find.byKey(const ValueKey('pen-preset-ball'));
      await tester.ensureVisible(fineTip);
      await tester.tap(fineTip);
      await tester.pumpAndSettle();
      expect(editor.width, .35);
      await tester.tap(fineTip);
      await tester.pumpAndSettle();
      final color = find.byTooltip('Choose green ink');
      await tester.ensureVisible(color);
      await tester.tap(color);
      await tester.pumpAndSettle();
      expect(editor.color, 0xff39755b);

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      final popup = tester.getRect(find.byKey(const ValueKey('pen-settings-popover')));
      expect(popup.left, greaterThanOrEqualTo(0));
      expect(popup.right, lessThanOrEqualTo(width));
      await tester.tap(find.byTooltip('Close pen settings'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      editor.dispose();
    });
  }

  testWidgets('pen detector snaps on lift; highlighter stays freehand; undo and erase work', (tester) async {
    final renders = RenderService(FakePdf());
    final repository = MemoryRepository();
    final editor = EditorController(sampleDocument(), repository);
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    Future<void> draw(List<Offset> vertices) async {
      final pen = await tester.startGesture(vertices.first, kind: PointerDeviceKind.stylus);
      var time = 0;
      for (var i = 1; i < vertices.length; i++) {
        for (var step = 1; step <= 20; step++) {
          time += 16;
          await pen.moveTo(Offset.lerp(vertices[i - 1], vertices[i], step / 20)!,
            timeStamp: Duration(milliseconds: time));
        }
      }
      await pen.up();
      await tester.pump();
    }
    const line = [Offset(200, 150), Offset(350, 153)];
    await draw(line);
    expect(editor.strokes(0).last.shape, InkShape.freehand);
    editor.toggleShapeDetection();
    await draw(line);
    expect(editor.strokes(0).last.shape, InkShape.line);
    expect(editor.strokes(0).last.points.length, 2);
    await draw(const [Offset(200, 200), Offset(350, 200), Offset(350, 300),
      Offset(200, 300), Offset(200, 200)]);
    expect(editor.strokes(0).last.shape, InkShape.rectangle);
    await draw(const [Offset(200, 350), Offset(350, 350), Offset(320, 330),
      Offset(350, 350), Offset(320, 370)]);
    expect(editor.strokes(0).last.shape, InkShape.arrow);
    editor.selectHighlighter();
    await draw(line);
    final highlight = editor.strokes(0).last;
    expect(highlight.kind, InkKind.highlighter);
    expect(highlight.shape, InkShape.freehand);
    expect(highlight.width, 16);
    expect(highlight.color, 0xffffd740);
    editor.undo();
    expect(editor.strokes(0).last.shape, InkShape.arrow);
    editor.redo();
    expect(editor.strokes(0).last, same(highlight));
    editor.setTool(EditorTool.eraser);
    await draw(const [Offset(280, 130), Offset(280, 170)]);
    expect(editor.strokes(0).map((s) => s.shape), [InkShape.rectangle, InkShape.arrow]);
    editor.undo();
    expect(editor.strokes(0).last, same(highlight));
    await editor.flush();
    final loaded = AppDocument.fromJson(repository.saves.last, '/source.pdf');
    expect(loaded.annotations[0]!.map((s) => s.toJson()), editor.strokes(0).map((s) => s.toJson()));
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('dot follows mouse and pen hover, hides on exit, and hand keeps its cursor', (tester) async {
    final renders = RenderService(FakePdf());
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(renders.document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final region = find.byWidgetPredicate((w) => w is MouseRegion && w.onExit != null &&
      (w.cursor == SystemMouseCursors.none || w.cursor == SystemMouseCursors.grab));
    expect(tester.widget<MouseRegion>(region).cursor, SystemMouseCursors.none);
    final dot = find.byKey(const ValueKey('pen-cursor-dot'));
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus]) {
      final pointer = await tester.createGesture(kind: kind);
      await pointer.addPointer(location: const Offset(200, 150));
      await pointer.moveTo(const Offset(220, 160));
      await tester.pump();
      final painted = tester.widget<CustomPaint>(dot).painter!;
      await pointer.moveTo(const Offset(250, 180));
      await tester.pump();
      expect(tester.widget<CustomPaint>(dot).painter!.shouldRepaint(painted), isTrue);
      await pointer.removePointer();
      await tester.pump();
    }
    editor.setTool(EditorTool.hand);
    await tester.pump();
    expect(dot, findsNothing);
    expect(tester.widget<MouseRegion>(region).cursor, SystemMouseCursors.grab);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus, PointerDeviceKind.touch]) {
    testWidgets('$kind scrollbar follows navigation and drags without creating ink', (tester) async {
      final document = FakePdf();
      final renders = RenderService(document);
      final editor = EditorController(sampleDocument(), MemoryRepository());
      final viewport = ViewportController(document.pageSizes);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
        editor: editor, renders: renders, viewport: viewport))));
      await tester.pumpAndSettle();
      final rail = find.byKey(const ValueKey('document-scrollbar'));
      final thumb = find.byKey(const ValueKey('document-scrollbar-thumb'));
      final track = tester.getRect(rail);
      expect(tester.getRect(thumb).top, track.top);
      viewport.jumpTo(160);
      await tester.pumpAndSettle();
      expect(tester.getCenter(thumb).dy, closeTo(track.center.dy, 12));

      final drag = await tester.startGesture(tester.getCenter(thumb), kind: kind);
      await drag.moveTo(Offset(track.center.dx, track.bottom));
      await drag.up();
      await tester.pumpAndSettle();
      expect(viewport.scrollFraction, 1);
      expect(tester.getRect(thumb).bottom, closeTo(track.bottom, 1e-8));
      expect(editor.document.strokeCount, 0);

      final click = await tester.startGesture(Offset(track.center.dx, track.top), kind: kind);
      await click.up();
      await tester.pumpAndSettle();
      expect(viewport.scrollFraction, 0);
      expect(editor.document.strokeCount, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(viewport.scrollFraction, 0); // No momentum after releasing the thumb.
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      viewport.dispose();
      editor.dispose();
    });
  }

  testWidgets('scrollbar contact cannot move the document during pen input', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    final before = viewport.offset;
    final contact = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('document-scrollbar'))),
      kind: PointerDeviceKind.touch);
    await contact.moveBy(const Offset(0, 100));
    await contact.up();
    expect(viewport.offset, before);
    expect(viewport.inputActive, isTrue);
    await pen.up();
    expect(editor.document.strokeCount, 1);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('scrolling preserves loaded page state as the visible list shifts', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    viewport.jumpTo(1);
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('pdf-3'));
    final state = tester.state(page);
    final image = tester.widget<RawImage>(find.descendant(of: page, matching: find.byType(RawImage))).image;
    viewport.jumpTo(3); // Evicts page 0 and shifts every remaining child's index.
    await tester.pump();
    expect(tester.state(page), same(state));
    expect(tester.widget<RawImage>(find.descendant(of: page, matching: find.byType(RawImage))).image, same(image));
    await tester.pumpAndSettle();
    expect(document.rendered.where((p) => p == 3).length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('Windows haptics follow pen strokes and stop on cancel and focus loss', (tester) async {
    const channel = MethodChannel('papertrail/pen_haptics');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final pen = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    await pen.moveTo(const Offset(220, 160), timeStamp: const Duration(milliseconds: 16));
    await pen.cancel();
    await tester.pump();
    expect(calls, ['start', 'stop']);
    calls.clear();
    final second = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
    tester.state<DocumentViewState>(find.byType(DocumentView))
      .didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    expect(calls, ['start', 'stop']);
    expect(viewport.inputActive, isFalse);
    await second.up();
    calls.clear();
    for (final tool in [EditorTool.hand, EditorTool.eraser]) {
      editor.setTool(tool);
      final gesture = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.stylus);
      await gesture.up();
    }
    editor.setTool(EditorTool.pen);
    final mouse = await tester.startGesture(const Offset(200, 150), kind: PointerDeviceKind.mouse);
    await mouse.up();
    await tester.pump();
    expect(calls, isEmpty);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus]) {
    testWidgets('$kind edge popup adds, expands and restores space without ink', (tester) async {
      final document = FakePdf();
      final renders = RenderService(document);
      final editor = EditorController(sampleDocument(), MemoryRepository());
      final viewport = ViewportController(document.pageSizes);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
        editor: editor, renders: renders, viewport: viewport))));
      await tester.pumpAndSettle();
      final popup = find.byKey(const ValueKey('edge-writing-space'));
      final pointer = await tester.createGesture(kind: kind);
      await pointer.addPointer(location: const Offset(300, 200));
      await tester.pump();
      expect(popup, findsNothing);

      Future<void> hoverEdge() async {
        final notes = viewport.layout.notes[1];
        final rect = viewport.screenRect(notes.width > 0 ? notes : viewport.layout.pages[1]);
        await pointer.moveTo(Offset(rect.right - 2, rect.top + 100));
        await tester.pumpAndSettle();
        expect(popup, findsOneWidget);
      }
      Future<void> activate() async {
        final center = tester.getCenter(popup);
        await pointer.moveTo(center);
        await tester.pump();
        expect(popup, findsOneWidget);
        await pointer.down(center);
        await pointer.up();
        await tester.pumpAndSettle();
        expect(editor.document.strokeCount, 0);
        expect(editor.document.writingAreas[0], isNull);
      }

      viewport.jumpTo(1);
      viewport.setZoom(.8);
      await tester.pumpAndSettle();
      await hoverEdge();
      expect(editor.document.writingAreas, isEmpty);
      await pointer.moveTo(const Offset(300, 400));
      await tester.pump();
      expect(popup, findsNothing);
      await hoverEdge();
      await activate();
      expect(editor.document.writingAreas[1]!.width, .5);
      await hoverEdge();
      expect(find.text('Add more space'), findsOneWidget);
      await activate();
      expect(editor.document.writingAreas[1]!.width, 1);
      editor.undo();
      await tester.pump();
      expect(editor.document.writingAreas[1]!.width, .5);

      editor.toggleWritingArea(1);
      viewport.revealPage(1);
      await tester.pumpAndSettle();
      await hoverEdge();
      expect(find.text('Show writing space'), findsOneWidget);
      await activate();
      expect(editor.document.writingAreas[1]!.visible, isTrue);
      expect(editor.document.writingAreas[1]!.width, .5);
      await hoverEdge();
      viewport.pan(const Offset(0, -50));
      await tester.pump();
      expect(popup, findsNothing);

      await pointer.removePointer();
      await editor.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      await renders.close();
      viewport.dispose();
      editor.dispose();
    });
  }

  testWidgets('drawing and touch at the right edge do not open the popup', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();
    final edge = Offset(viewport.pageRect(0).right - 2, 200);
    for (final kind in [PointerDeviceKind.stylus, PointerDeviceKind.touch]) {
      final pointer = await tester.startGesture(edge - const Offset(50, 0), kind: kind);
      await pointer.moveTo(edge);
      await tester.pump();
      expect(find.byKey(const ValueKey('edge-writing-space')), findsNothing);
      await pointer.up();
    }
    expect(editor.document.writingAreas, isEmpty);
    expect(editor.document.strokeCount, 1);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('right-side ink stays aligned through expansion, hide, zoom and erasing', (tester) async {
    final document = FakePdf();
    final renders = RenderService(document);
    final editor = EditorController(sampleDocument(), MemoryRepository());
    final viewport = ViewportController(document.pageSizes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentView(
      editor: editor, renders: renders, viewport: viewport))));
    await tester.pumpAndSettle();

    Future<void> draw(Offset start, Offset end) async {
      final pen = await tester.startGesture(start, kind: PointerDeviceKind.stylus);
      await pen.moveTo(end);
      await pen.up();
      await tester.pump();
    }
    Offset point(InkSurface surface, double x, double y) {
      final rect = surface == InkSurface.page ? viewport.layout.pages[0] : viewport.layout.notes[0];
      return viewport.screenRect(rect).topLeft + Offset(x, y) * viewport.scale;
    }

    await draw(point(InkSurface.page, 60, 100), point(InkSurface.page, 120, 140));
    final original = editor.strokes(0).single.toJson();
    editor.expandWritingArea(0);
    viewport.setZoom(viewport.fitWidthZoom);
    await tester.pumpAndSettle();
    await draw(point(InkSurface.notes, 60, 100), point(InkSurface.notes, 120, 140));
    expect(editor.strokes(0).last.surface, InkSurface.notes);
    final note = editor.strokes(0).last.toJson();
    final fittedWidth = editor.document.writingAreas[0]!.width;
    final reference = viewport.pageSize(0);
    editor.expandWritingArea(0);
    await tester.pump();
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter).whereType<CommittedInkPainter>();
    expect(painters.firstWhere((p) => p.surface == InkSurface.notes && p.page == 0).referenceSize, reference);
    expect(editor.strokes(0).first.toJson(), original);
    expect(editor.strokes(0).last.toJson(), note);

    editor.toggleWritingArea(0);
    await tester.pump();
    expect(viewport.layout.notes[0].width, 0);
    expect(editor.strokes(0).length, 2);
    editor.undo();
    await tester.pump();
    expect(viewport.layout.notes[0].width, closeTo((fittedWidth + .5) * 612, 1e-8));
    editor.setTool(EditorTool.eraser);
    await draw(point(InkSurface.notes, 60, 100), point(InkSurface.notes, 120, 140));
    expect(editor.strokes(0).single.toJson(), original);
    editor.undo();
    await tester.pump();
    expect(editor.strokes(0).last.toJson(), note);

    // A gesture ends at the seam rather than bridging unrelated surfaces.
    editor.setTool(EditorTool.pen);
    await draw(point(InkSurface.page, 590, 200), point(InkSurface.notes, 20, 200));
    expect(editor.strokes(0).last.surface, InkSurface.page);
    expect(editor.strokes(0).last.points.length, 1);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    viewport.dispose();
    editor.dispose();
  });

  testWidgets('saved writing space reopens; controls expand, hide and show on the current page', (tester) async {
    final renders = RenderService(FakePdf());
    final saved = sampleDocument();
    saved.writingAreas[0] = const WritingArea();
    final editor = EditorController(saved, MemoryRepository());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EditorScreen(
      editor: editor, renders: renders, onOpen: () {}, onBack: () {}))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Writing space'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add more space to the right'));
    await tester.pumpAndSettle();
    expect(saved.writingAreas[0]!.width, 1);
    await tester.tap(find.text('Writing space'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide writing space (keep notes)'));
    await tester.pumpAndSettle();
    expect(find.text('Notes hidden'), findsOneWidget);
    expect(saved.writingAreas[0]!.visible, isFalse);
    await tester.tap(find.text('Notes hidden'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show writing space'));
    await tester.pumpAndSettle();
    expect(saved.writingAreas[0]!.visible, isTrue);
    expect(saved.writingAreas[1], isNull);
    await editor.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await renders.close();
    editor.dispose();
  });

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
