import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/annotations/editor_controller.dart';
import '../features/annotations/ink.dart';
import '../features/annotations/ink_painter.dart';
import '../features/pdf_viewer/document_view.dart';
import '../features/pdf_viewer/page_image.dart';
import '../features/pdf_viewer/render_service.dart';
import '../features/pdf_viewer/viewport_controller.dart';
import 'app.dart';
import 'annotation_toolbar.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.editor, required this.renders,
    required this.onOpen, required this.onBack, this.onBackup});
  final EditorController editor;
  final RenderService renders;
  final VoidCallback onOpen;
  final VoidCallback onBack;
  final VoidCallback? onBackup;
  @override
  State<EditorScreen> createState() => EditorScreenState();
}

class EditorScreenState extends State<EditorScreen> {
  final _canvas = GlobalKey<DocumentViewState>();
  late final ViewportController _viewport;
  bool _thumbnails = false;
  EditorController get editor => widget.editor;
  void finishInput() => _canvas.currentState?.finishInput();

  @override
  void initState() {
    super.initState();
    _viewport = ViewportController(widget.renders.document.pageSizes);
    _viewport.setWritingAreas({
      for (final entry in editor.document.writingAreas.entries)
        if (entry.value.visible) entry.key: entry.value.width,
    });
    editor.addListener(_rebuild);
  }
  void _rebuild() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    editor.removeListener(_rebuild);
    _viewport.dispose();
    super.dispose();
  }

  void _undo() { finishInput(); editor.undo(); }
  void _redo() { finishInput(); editor.redo(); }
  void _tool(EditorTool tool) { finishInput(); editor.setTool(tool); }

  Future<void> _save() async {
    finishInput();
    try { await editor.flush(); }
    catch (_) { /* Persistent error banner below retains retry and backup actions. */ }
  }

  Future<void> _jump() async {
    finishInput();
    final input = TextEditingController(text: '${_viewport.currentPage + 1}');
    final page = await showDialog<int>(context: context, builder: (context) => AlertDialog(
      title: const Text('Go to page'),
      content: TextField(controller: input, autofocus: true,
        keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(helperText: '1–${editor.document.pageCount}'),
        onSubmitted: (text) => Navigator.pop(context, int.tryParse(text))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(input.text)), child: const Text('Go'))],
    ));
    // Wait for the dialog's reverse transition before disposing its controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (page != null && mounted) _viewport.jumpTo(page - 1);
  }

  Widget _button(IconData icon, String label, VoidCallback? action, {bool selected = false}) =>
    IconButton(tooltip: label, isSelected: selected, onPressed: action,
      style: IconButton.styleFrom(backgroundColor: selected ? const Color(0xffe5eafa) : Colors.transparent,
        foregroundColor: selected ? accent : ink, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
      icon: Icon(icon, size: 21), selectedIcon: Icon(icon, size: 21));

  Widget _documentBar(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    Widget action(IconData icon, String label, VoidCallback onPressed, {bool selected = false}) =>
      IconButton(tooltip: label, onPressed: onPressed, isSelected: selected,
        style: IconButton.styleFrom(foregroundColor: Colors.white,
          backgroundColor: selected ? Colors.white.withValues(alpha: .18) : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        icon: Icon(icon, size: 21));
    return Container(height: 56, padding: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xff315f96),
      child: Row(children: [
        action(Icons.arrow_back_rounded, 'Back to documents', widget.onBack),
        action(Icons.view_sidebar_outlined, 'Toggle page thumbnails', () {
          finishInput(); setState(() => _thumbnails = !_thumbnails);
        }, selected: _thumbnails),
        const SizedBox(width: 8),
        Expanded(child: Text(editor.document.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
        const SizedBox(width: 8),
        AnimatedBuilder(animation: _viewport, builder: (context, _) {
          final page = _viewport.currentPage;
          final area = editor.document.writingAreas[page];
          return PopupMenuButton<String>(
            tooltip: 'Writing space for page ${page + 1}',
            onOpened: finishInput,
            onSelected: (action) {
              finishInput();
              if (action == 'expand') { editor.expandWritingArea(page); }
              else { editor.toggleWritingArea(page); }
              if (editor.document.writingAreas[page]?.visible ?? false) {
                _viewport.revealWritingArea(page);
              } else { _viewport.revealPage(page); }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'toggle', child: Text(area == null ? 'Add writing space to the right' :
                area.visible ? 'Hide writing space (keep notes)' : 'Show writing space')),
              if (area != null) const PopupMenuItem(value: 'expand', child: Text('Add more space to the right')),
            ],
            child: SizedBox(height: 44, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(area == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined,
                  size: 21, color: Colors.white),
                if (!compact) ...[
                  const SizedBox(width: 6),
                  Text(area == null ? 'Add writing space' : area.visible ? 'Writing space' : 'Notes hidden',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white),
                ],
              ]))),
          );
        }),
        action(Icons.file_open_outlined, 'Open another PDF', widget.onOpen),
        PopupMenuButton<String>(tooltip: 'Document options',
          icon: const Icon(Icons.more_horiz, color: Colors.white), onSelected: (value) {
          if (value == 'backup') widget.onBackup?.call();
          if (value == 'about') showAboutDialog(context: context, applicationName: 'Papertrail',
            applicationVersion: 'Prototype 0.1', children: [const Text(
              'Pen or mouse draws. Touch scrolls and pinches to zoom. '
              'P: selected preset, M: highlighter preset, E: eraser, H: hand, S: shape detection.\n\n'
              'Notes save locally and reopen automatically. Annotated PDF export, high-resolution tiles, '
              'and Surface hardware tuning are next milestones.')]);
        }, itemBuilder: (_) => [
          if (widget.onBackup != null) const PopupMenuItem(value: 'backup', child: Text('Save annotation backup…')),
          const PopupMenuItem(value: 'about', child: Text('About this prototype')),
        ]),
      ]));
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(bindings: {
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _redo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => unawaited(_save()),
    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => unawaited(_save()),
    const SingleActivator(LogicalKeyboardKey.keyO, control: true): widget.onOpen,
    const SingleActivator(LogicalKeyboardKey.keyO, meta: true): widget.onOpen,
    const SingleActivator(LogicalKeyboardKey.keyP): () => _tool(EditorTool.pen),
    const SingleActivator(LogicalKeyboardKey.keyM): () { finishInput(); editor.selectHighlighter(); },
    const SingleActivator(LogicalKeyboardKey.keyS): () { finishInput(); editor.toggleShapeDetection(); },
    const SingleActivator(LogicalKeyboardKey.keyE): () => _tool(EditorTool.eraser),
    const SingleActivator(LogicalKeyboardKey.keyH): () => _tool(EditorTool.hand),
  }, child: Focus(autofocus: true, child: Column(children: [
    _documentBar(context),
    AnnotationToolbar(editor: editor, finishInput: finishInput),
    if (editor.saveState == SaveState.failed) MaterialBanner(
      backgroundColor: const Color(0xffffeadc),
      content: Text('Notes are not saved: ${editor.saveError}. Keep this document open.'),
      actions: [TextButton(onPressed: _save, child: const Text('Retry save')),
        if (widget.onBackup != null) TextButton(onPressed: widget.onBackup, child: const Text('Save backup'))]),
    Expanded(child: Row(children: [
      if (_thumbnails) SizedBox(width: MediaQuery.sizeOf(context).width < 600 ? 108 : 170,
        child: _Thumbnails(editor: editor, renders: widget.renders, viewport: _viewport,
          onJump: (page) { finishInput(); _viewport.jumpTo(page); })),
      Expanded(child: DocumentView(key: _canvas, editor: editor, renders: widget.renders, viewport: _viewport)),
    ])),
    AnimatedBuilder(animation: _viewport, builder: (context, _) => Container(
      height: 52, padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xffdddfd7)))),
      child: Row(children: [
        TextButton(onPressed: _jump, child: Text('${_viewport.currentPage + 1} / ${editor.document.pageCount}')),
        const SizedBox(width: 10),
        if (MediaQuery.sizeOf(context).width > 560) Row(children: [
          Icon(editor.saveState == SaveState.saved ? Icons.cloud_done_outlined : Icons.save_outlined,
            size: 15, color: editor.saveState == SaveState.failed ? Colors.red : const Color(0xff718b56)),
          const SizedBox(width: 7), Text(switch (editor.saveState) {
            SaveState.saved => 'Saved on this device', SaveState.pending => 'Unsaved changes',
            SaveState.saving => 'Saving…', SaveState.failed => 'Save failed',
          }, style: const TextStyle(fontSize: 11, color: Color(0xff777e75))),
        ]),
        const Spacer(),
        _button(Icons.remove, 'Zoom out', () => _viewport.setZoom(_viewport.zoom / 1.2)),
        SizedBox(width: 47, child: Text('${(_viewport.zoom * 100).round()}%', textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12))),
        _button(Icons.add, 'Zoom in', () => _viewport.setZoom(_viewport.zoom * 1.2)),
        _button(Icons.fit_screen_outlined, 'Fit width', () => _viewport.setZoom(_viewport.fitWidthZoom)),
      ]))),
  ])));
}

class _Thumbnails extends StatelessWidget {
  const _Thumbnails({required this.editor, required this.renders, required this.viewport, required this.onJump});
  final EditorController editor;
  final RenderService renders;
  final ViewportController viewport;
  final void Function(int) onJump;

  @override
  Widget build(BuildContext context) => ColoredBox(color: const Color(0xfff0f0ea),
    child: Column(children: [
      const Padding(padding: EdgeInsets.all(16), child: Text('PAGES',
        style: TextStyle(fontSize: 10, letterSpacing: 1.7, color: Color(0xff777e75)))),
      Expanded(child: ListView.builder(itemCount: renders.document.pageCount, cacheExtent: 200,
        padding: const EdgeInsets.symmetric(horizontal: 16), itemBuilder: (context, page) {
          final size = renders.document.pageSizes[page];
          return Padding(padding: const EdgeInsets.only(bottom: 18), child: InkWell(
            onTap: () => onJump(page), child: Column(children: [
              AspectRatio(aspectRatio: size.width / size.height,
                child: Stack(fit: StackFit.expand, children: [
                  PageImage(renders: renders, page: page, scale: .3, priority: 4),
                  IgnorePointer(child: CustomPaint(painter: CommittedInkPainter(editor, page, size.width))),
                ])),
              const SizedBox(height: 8), Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${page + 1}', style: const TextStyle(fontSize: 11)),
                if (editor.document.writingAreas.containsKey(page)) ...[
                  const SizedBox(width: 5),
                  Tooltip(message: 'Has writing space', child: Icon(Icons.sticky_note_2_outlined,
                    size: 14, color: accent)),
                ],
              ]),
            ])));
        })),
    ]));
}
