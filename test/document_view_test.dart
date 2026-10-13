import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    final reference = viewport.pageRect(0).size;
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
    expect(viewport.layout.notes[0].width, 612);
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
