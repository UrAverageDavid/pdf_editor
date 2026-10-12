import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/page_geometry.dart';
import '../annotations/editor_controller.dart';
import '../annotations/ink.dart';
import '../annotations/ink_painter.dart';
import 'page_image.dart';
import 'render_service.dart';
import 'viewport_controller.dart';

class DocumentView extends StatefulWidget {
  const DocumentView({super.key, required this.editor, required this.renders,
    required this.viewport});
  final EditorController editor;
  final RenderService renders;
  final ViewportController viewport;
  @override
  State<DocumentView> createState() => DocumentViewState();
}

class DocumentViewState extends State<DocumentView> {
  final _ink = ActiveInk();
  final _touches = <int, Offset>{};
  final _erased = <String>{};
  int? _pointer;
  int? _page;
  bool _erasing = false;
  Offset? _erasePosition;
  Offset? _previousErase;
  double _trackpadScale = 1;
  int _strokeSequence = 0;
  int? _edgePage;
  Rect? _edgePopup;
  DateTime _lastPen = DateTime.fromMillisecondsSinceEpoch(0);
  ViewportController get view => widget.viewport;

  @override
  void initState() {
    super.initState();
    _syncWritingAreas();
    view.addListener(_rebuild);
    widget.editor.addListener(_syncWritingAreas);
  }
  void _syncWritingAreas() => view.setWritingAreas({
    for (final entry in widget.editor.document.writingAreas.entries)
      if (entry.value.visible) entry.key: entry.value.width,
  });
  void _rebuild() {
    if (mounted) setState(() { _edgePage = null; _edgePopup = null; });
  }

  void _hideEdgePopup() {
    if (_edgePage != null) setState(() { _edgePage = null; _edgePopup = null; });
  }

  void _hover(PointerHoverEvent e) {
    if (_pointer != null || _touches.isNotEmpty ||
        (e.kind != PointerDeviceKind.mouse && !_isPen(e))) return;
    final position = e.localPosition;
    // Keep the action still and reachable as the pointer moves onto it.
    if (_edgePopup?.inflate(8).contains(position) ?? false) return;
    final page = view.layout.pageAtY(view.toDocument(position).dy);
    final notes = view.layout.notes[page];
    final rect = view.screenRect(notes.width > 0 ? notes : view.layout.pages[page]);
    if (rect.right < 0 || rect.right > view.size.width ||
        position.dy < rect.top || position.dy > rect.bottom ||
        (position.dx - rect.right).abs() > 24 ||
        view.size.width < 64 || view.size.height < 60) {
      _hideEdgePopup();
      return;
    }
    if (_edgePage == page) return;
    final width = math.min(208.0, view.size.width - 16);
    setState(() {
      _edgePage = page;
      _edgePopup = Rect.fromLTWH(
        (rect.right - width - 8).clamp(8.0, view.size.width - width - 8),
        (position.dy - 22).clamp(8.0, view.size.height - 52), width, 44);
    });
  }

  void _addSpaceAtEdge() {
    final page = _edgePage;
    if (page == null) return;
    _hideEdgePopup();
    finishInput();
    final area = widget.editor.document.writingAreas[page];
    if (area == null || !area.visible) {
      widget.editor.toggleWritingArea(page);
    } else {
      widget.editor.expandWritingArea(page);
    }
    view.revealWritingArea(page);
  }

  bool _isPen(PointerEvent e) => e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;
  bool get _palmSuppressed => _pointer != null ||
      DateTime.now().difference(_lastPen).inMilliseconds < 180;

  void _down(PointerDownEvent e) {
    // The popup's button handles this contact; it must never create ink below it.
    if (_edgePopup?.contains(e.localPosition) ?? false) return;
    _hideEdgePopup();
    if (_isPen(e)) { _lastPen = DateTime.now(); _touches.clear(); }
    if (_pointer != null) return;
    final drawingDevice = _isPen(e) || (e.kind == PointerDeviceKind.mouse &&
      (e.buttons & kPrimaryMouseButton) != 0);
    if (drawingDevice && widget.editor.tool != EditorTool.hand) {
      final position = view.toDocument(e.localPosition);
      final page = view.layout.pageAtY(position.dy);
      final onPage = view.layout.pages[page].contains(position);
      if (!onPage && !view.layout.notes[page].contains(position)) return;
      _pointer = e.pointer;
      _page = page;
      _erasing = widget.editor.tool == EditorTool.eraser ||
          e.kind == PointerDeviceKind.invertedStylus;
      view.inputActive = true;
      widget.renders.inkActive = true;
      _ink.page = page;
      _ink.surface = onPage ? InkSurface.page : InkSurface.notes;
      _ink.width = widget.editor.width;
      _ink.color = widget.editor.color;
      _sample(e);
    } else if (e.kind != PointerDeviceKind.touch || !_palmSuppressed) {
      _touches[e.pointer] = e.localPosition;
    }
  }

  void _move(PointerMoveEvent e) {
    if (_isPen(e)) _lastPen = DateTime.now();
    if (e.pointer == _pointer) { _sample(e); return; }
    if (_pointer != null || !_touches.containsKey(e.pointer)) return;
    if (_touches.length == 1) {
      final previous = _touches[e.pointer]!;
      _touches[e.pointer] = e.localPosition;
      view.pan(e.localPosition - previous);
    } else {
      final before = _touches.values.take(2).toList();
      final oldCenter = (before[0] + before[1]) / 2;
      final oldDistance = (before[0] - before[1]).distance;
      _touches[e.pointer] = e.localPosition;
      final after = _touches.values.take(2).toList();
      final center = (after[0] + after[1]) / 2;
      final distance = (after[0] - after[1]).distance;
      if (oldDistance > 4) view.setZoom(view.zoom * distance / oldDistance, focal: oldCenter);
      view.pan(center - oldCenter);
    }
  }

  void _sample(PointerEvent e) {
    final page = _page!;
    final rect = _ink.surface == InkSurface.page ? view.layout.pages[page] : view.layout.notes[page];
    final reference = view.layout.pages[page].size;
    final local = view.toDocument(e.localPosition) - rect.topLeft;
    // End at the page boundary; never bridge unrelated pages with a stroke.
    if (!(Offset.zero & rect.size).contains(local)) { finishInput(); return; }
    if (_erasing) {
      final from = _previousErase ?? local;
      for (final stroke in widget.editor.strokes(page)) {
        if (stroke.surface == _ink.surface &&
            strokeIntersects(stroke, reference, from, local, 12 / view.scale)) {
          _erased.add(stroke.id);
        }
      }
      _previousErase = local;
      setState(() => _erasePosition = e.localPosition);
      return;
    }
    final normalized = _ink.surface == InkSurface.page ? normalizePoint(local, reference) :
      Offset(local.dx / reference.width, local.dy / reference.height);
    final range = e.pressureMax - e.pressureMin;
    final pressure = _isPen(e) && range > 0
        ? ((e.pressure - e.pressureMin) / range).clamp(.05, 1.0).toDouble() : .75;
    _ink.points.add(InkPoint(normalized.dx, normalized.dy, pressure, e.timeStamp.inMicroseconds));
    _ink.changed();
  }

  /// Also used before focus loss, document switching, export, and normal exit.
  void finishInput() {
    if (_pointer == null) { _touches.clear(); return; }
    if (_erasing) {
      widget.editor.erase(_erased, _page!);
    } else if (_ink.points.isNotEmpty) {
      final now = DateTime.now();
      widget.editor.addStroke(InkStroke(
        id: '${now.microsecondsSinceEpoch}-${_strokeSequence++}', pageIndex: _page!,
        points: _ink.points, width: _ink.width, color: _ink.color, createdAt: now,
        surface: _ink.surface));
    }
    _pointer = null;
    _page = null;
    _previousErase = null;
    _erased.clear();
    _ink.clear();
    view.inputActive = false;
    widget.renders.inkActive = false;
    if (mounted) setState(() => _erasePosition = null);
  }

  void _up(PointerEvent e) {
    if (e.pointer == _pointer) finishInput();
    _touches.remove(e.pointer);
  }

  void _signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || _pointer != null) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final scroll = event as PointerScrollEvent;
      if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) {
        view.setZoom(view.zoom * math.exp(-scroll.scrollDelta.dy * .002), focal: scroll.localPosition);
      } else { view.pan(-scroll.scrollDelta); }
    });
  }

  @override
  void dispose() {
    view.removeListener(_rebuild);
    widget.editor.removeListener(_syncWritingAreas);
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    if (view.size != constraints.biggest) { _edgePage = null; _edgePopup = null; }
    view.configure(constraints.biggest);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final visible = view.visibleDocument;
    final pages = view.layout.visible(visible).toList();
    return Semantics(label: 'PDF canvas. Pen or mouse draws; touch scrolls and pinches to zoom.',
      child: MouseRegion(cursor: widget.editor.tool == EditorTool.hand
        ? SystemMouseCursors.grab : SystemMouseCursors.precise,
        onExit: (_) => _hideEdgePopup(),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down, onPointerMove: _move,
          onPointerHover: _hover,
          onPointerUp: _up, onPointerCancel: _up, onPointerSignal: _signal,
          onPointerPanZoomStart: (_) => _trackpadScale = 1,
          onPointerPanZoomUpdate: (e) {
            view.setZoom(view.zoom * e.scale / _trackpadScale, focal: e.localPosition);
            _trackpadScale = e.scale;
            view.pan(e.panDelta);
          },
          child: ClipRect(child: ColoredBox(color: const Color(0xffe9e9e5),
            child: Stack(children: [
              for (final page in pages)
                Positioned.fromRect(rect: view.pageRect(page),
                  child: RepaintBoundary(child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 12, offset: const Offset(0, 3))]),
                    child: ClipRect(child: Stack(fit: StackFit.expand, children: [
                      RepaintBoundary(child: PageImage(key: ValueKey('pdf-$page'),
                        renders: widget.renders, page: page, scale: view.scale * dpr,
                        priority: page == view.currentPage ? 0 : view.layout.pages[page].overlaps(visible) ? 1 : 3)),
                      RepaintBoundary(child: CustomPaint(painter: CommittedInkPainter(
                        widget.editor, page, view.layout.pages[page].width,
                        hidden: _erasing && _page == page ? Set.of(_erased) : const {}))),
                      RepaintBoundary(child: CustomPaint(painter: ActiveInkPainter(
                        _ink, page, view.layout.pages[page].width))),
                    ])),
                  )),
                ),
              for (final page in pages)
                if (view.layout.notes[page].width > 0)
                  Positioned.fromRect(rect: view.screenRect(view.layout.notes[page]),
                    child: Semantics(label: 'Writing space for page ${page + 1}',
                      child: ClipRect(child: DecoratedBox(
                        decoration: const BoxDecoration(color: Color(0xfffffdf5),
                          border: Border(left: BorderSide(color: Color(0xffd6d1bf)))),
                        child: Stack(fit: StackFit.expand, children: [
                          RepaintBoundary(child: CustomPaint(painter: CommittedInkPainter(
                            widget.editor, page, view.layout.pages[page].width,
                            surface: InkSurface.notes, referenceSize: view.pageRect(page).size,
                            hidden: _erasing && _page == page ? Set.of(_erased) : const {}))),
                          RepaintBoundary(child: CustomPaint(painter: ActiveInkPainter(
                            _ink, page, view.layout.pages[page].width,
                            surface: InkSurface.notes, referenceSize: view.pageRect(page).size))),
                        ]),
                      )))),
              if (_erasePosition != null) Positioned(left: _erasePosition!.dx - 12,
                top: _erasePosition!.dy - 12, width: 24, height: 24,
                child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
                  shape: BoxShape.circle, color: Colors.white.withValues(alpha: .5),
                  border: Border.all(color: const Color(0xff2947c7), width: 1.5))))),
              if (_edgePage != null && _edgePopup != null)
                Positioned.fromRect(rect: _edgePopup!,
                  child: Material(elevation: 4, color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(10), clipBehavior: Clip.antiAlias,
                    child: TextButton.icon(
                      key: const ValueKey('edge-writing-space'),
                      onPressed: _addSpaceAtEdge,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(widget.editor.document.writingAreas[_edgePage] == null
                        ? 'Add writing space'
                        : widget.editor.document.writingAreas[_edgePage]!.visible
                          ? 'Add more space' : 'Show writing space'),
                    ))),
            ])),
          ),
        ),
      ),
    );
  });
}
