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
    const SingleActivator(LogicalKeyboardKey.keyE): () => _tool(EditorTool.eraser),
    const SingleActivator(LogicalKeyboardKey.keyH): () => _tool(EditorTool.hand),
  }, child: Focus(autofocus: true, child: Column(children: [
    Container(height: 64, padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xffdddfd7)))),
      child: Row(children: [
        _button(Icons.arrow_back_rounded, 'Back to documents', widget.onBack),
        const SizedBox(width: 8), const Icon(Icons.description_outlined, color: accent, size: 21),
        const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(editor.document.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 3), const Text('Your original PDF stays untouched',
              style: TextStyle(fontSize: 11, color: Color(0xff777e75))),
          ])),
        _button(Icons.file_open_outlined, 'Open another PDF', widget.onOpen),
        PopupMenuButton<String>(tooltip: 'Document options', onSelected: (value) {
          if (value == 'backup') widget.onBackup?.call();
          if (value == 'about') showAboutDialog(context: context, applicationName: 'Papertrail',
            applicationVersion: 'Prototype 0.1', children: [const Text(
              'Pen or mouse draws. Touch scrolls and pinches to zoom. P: pen, E: eraser, H: hand.\n\n'
              'Notes save locally and reopen automatically. Annotated PDF export, high-resolution tiles, '
              'and Surface hardware tuning are next milestones.')]);
        }, itemBuilder: (_) => [
          if (widget.onBackup != null) const PopupMenuItem(value: 'backup', child: Text('Save annotation backup…')),
          const PopupMenuItem(value: 'about', child: Text('About this prototype')),
        ]),
      ])),
    Container(height: 64, padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        _button(Icons.view_sidebar_outlined, 'Toggle page thumbnails', () {
          finishInput(); setState(() => _thumbnails = !_thumbnails);
        }, selected: _thumbnails),
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
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(area == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined,
                  size: 21, color: area == null ? ink : accent),
                const SizedBox(width: 6),
                Text(area == null ? 'Add writing space' : area.visible ? 'Writing space' : 'Notes hidden'),
                const Icon(Icons.arrow_drop_down, size: 18),
              ])),
          );
        }),
        const SizedBox(width: 12),
        _button(Icons.edit_outlined, 'Pen (P)', () => _tool(EditorTool.pen), selected: editor.tool == EditorTool.pen),
        const SizedBox(width: 4),
        _button(Icons.auto_fix_normal_outlined, 'Stroke eraser (E)', () => _tool(EditorTool.eraser), selected: editor.tool == EditorTool.eraser),
        const SizedBox(width: 4),
        _button(Icons.pan_tool_outlined, 'Hand (H)', () => _tool(EditorTool.hand), selected: editor.tool == EditorTool.hand),
        const SizedBox(width: 16), const SizedBox(height: 26, child: VerticalDivider()), const SizedBox(width: 12),
        _button(Icons.undo_rounded, 'Undo', editor.canUndo ? _undo : null),
        _button(Icons.redo_rounded, 'Redo', editor.canRedo ? _redo : null),
        const SizedBox(width: 16), const SizedBox(height: 26, child: VerticalDivider()), const SizedBox(width: 16),
        for (final color in [0xff2947c7, 0xff242c35, 0xffb34a3e, 0xff39755b])
          Padding(padding: const EdgeInsets.only(right: 3), child: Semantics(
            label: {0xff2947c7: 'Blue ink', 0xff242c35: 'Black ink', 0xffb34a3e: 'Red ink', 0xff39755b: 'Green ink'}[color],
            selected: color == editor.color, button: true,
            child: IconButton(tooltip: 'Choose ${ {0xff2947c7: 'blue', 0xff242c35: 'black', 0xffb34a3e: 'red', 0xff39755b: 'green'}[color]} ink',
              onPressed: () { finishInput(); editor.setColor(color); },
              icon: Container(width: 24, height: 24, decoration: BoxDecoration(shape: BoxShape.circle,
                color: Color(color), border: color == editor.color ? Border.all(color: Colors.white, width: 3) : null,
                boxShadow: color == editor.color ? [BoxShadow(color: Color(color), spreadRadius: 2)] : null))))),
        const SizedBox(width: 12),
        DropdownButtonHideUnderline(child: DropdownButton<double>(value: editor.width,
          items: const [DropdownMenuItem(value: 1.2, child: Text('Fine')),
            DropdownMenuItem(value: 2.2, child: Text('Medium')),
            DropdownMenuItem(value: 4.0, child: Text('Bold'))],
          onChanged: (value) { if (value != null) { finishInput(); editor.setWidth(value); } })),
      ]))),
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
