import 'package:flutter/material.dart';

import '../features/annotations/editor_controller.dart';
import '../features/annotations/ink.dart';
import 'pen_presets.dart';

const _toolInk = Color(0xff253447);
const _selection = Color(0xffd9f0f3);
/// A compact drawing palette, kept separate from document/navigation actions.
class AnnotationToolbar extends StatelessWidget {
  const AnnotationToolbar({super.key, required this.editor, required this.finishInput});
  final EditorController editor;
  final VoidCallback finishInput;

  void _change(VoidCallback action) { finishInput(); action(); }

  Widget _tool(IconData icon, String label, VoidCallback action, bool selected) =>
    IconButton(tooltip: label, isSelected: selected,
      onPressed: () => _change(action),
      style: IconButton.styleFrom(minimumSize: const Size(44, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: selected ? _selection : Colors.transparent,
        foregroundColor: _toolInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      icon: Icon(icon, size: 22), selectedIcon: Icon(icon, size: 22));

  Widget _divider() => const Padding(padding: EdgeInsets.symmetric(horizontal: 5),
    child: SizedBox(height: 24, child: VerticalDivider(width: 1, color: Color(0xffdce1e6))));

  @override
  Widget build(BuildContext context) => Container(
    height: 68, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    color: const Color(0xfff5f6f8),
    child: Row(children: [
      IconButton(tooltip: 'Undo', onPressed: editor.canUndo ? () => _change(editor.undo) : null,
        icon: const Icon(Icons.undo_rounded, size: 21)),
      IconButton(tooltip: 'Redo', onPressed: editor.canRedo ? () => _change(editor.redo) : null,
        icon: const Icon(Icons.redo_rounded, size: 21)),
      const SizedBox(width: 8),
      Expanded(child: Center(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: DecoratedBox(decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xffe0e5ea)),
          boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 6, offset: Offset(0, 2))]),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _tool(Icons.auto_fix_normal_outlined, 'Stroke eraser (E)', () => editor.setTool(EditorTool.eraser), editor.tool == EditorTool.eraser),
              _tool(Icons.pan_tool_outlined, 'Hand (H)', () => editor.setTool(EditorTool.hand), editor.tool == EditorTool.hand),
              _tool(Icons.auto_awesome_outlined,
                'Detect shapes (S): lines, arrows, rectangles, triangles and ellipses with the pen',
                editor.toggleShapeDetection, editor.detectShapes),
              _divider(),
              PenPresets(editor: editor, finishInput: finishInput),
            ])))),
      )),
    ]));
}
