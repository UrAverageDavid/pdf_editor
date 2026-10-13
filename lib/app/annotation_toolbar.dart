import 'package:flutter/material.dart';

import '../features/annotations/editor_controller.dart';
import '../features/annotations/ink.dart';

const _toolInk = Color(0xff253447);
const _selection = Color(0xffd9f0f3);
const _colorNames = {0xff2947c7: 'blue', 0xff242c35: 'black', 0xffb34a3e: 'red',
  0xff39755b: 'green', 0xffffd740: 'yellow', 0xff69f0ae: 'mint',
  0xff40c4ff: 'cyan', 0xffff80ab: 'pink'};

String _widthLabel(double value) => value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

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

  Future<void> _chooseWidth(BuildContext context) async {
    finishInput();
    final width = await showDialog<double>(context: context, builder: (_) => _WidthPicker(
      initialWidth: editor.activeWidth, highlighting: editor.highlighting,
      color: Color(editor.activeColor)));
    if (width != null && context.mounted) _change(() => editor.setWidth(width));
  }

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
              _tool(Icons.edit_outlined, 'Pen (P)', () => editor.setTool(EditorTool.pen), editor.tool == EditorTool.pen),
              _tool(Icons.border_color_outlined, 'Highlighter (M)', () => editor.setTool(EditorTool.highlighter), editor.highlighting),
              _tool(Icons.auto_fix_normal_outlined, 'Stroke eraser (E)', () => editor.setTool(EditorTool.eraser), editor.tool == EditorTool.eraser),
              _tool(Icons.pan_tool_outlined, 'Hand (H)', () => editor.setTool(EditorTool.hand), editor.tool == EditorTool.hand),
              _tool(Icons.auto_awesome_outlined,
                'Detect shapes (S): lines, arrows, rectangles, triangles and ellipses with the pen',
                editor.toggleShapeDetection, editor.detectShapes),
              _divider(),
              for (final width in editor.highlighting ? [10.0, 16.0, 24.0] : [.35, 1.2, 2.2])
                _WidthButton(width: width, highlighting: editor.highlighting,
                  selected: (editor.activeWidth - width).abs() < .001,
                  onPressed: () => _change(() => editor.setWidth(width))),
              Tooltip(message: editor.highlighting ? 'Highlighter width' : 'Pen tip size',
                child: TextButton(key: const ValueKey('width-picker'),
                  style: TextButton.styleFrom(foregroundColor: _toolInk,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(76, 44), padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () => _chooseWidth(context),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${_widthLabel(editor.activeWidth)} pt', style: const TextStyle(fontSize: 12)),
                    const Icon(Icons.expand_more, size: 16),
                  ]))),
              _divider(),
              for (final color in editor.highlighting
                ? [0xffffd740, 0xff69f0ae, 0xff40c4ff, 0xffff80ab]
                : [0xff242c35, 0xff2947c7, 0xffb34a3e, 0xff39755b])
                Semantics(selected: color == editor.activeColor,
                  child: IconButton(tooltip: 'Choose ${_colorNames[color]} ${editor.highlighting ? 'highlighter' : 'ink'}',
                    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    onPressed: () => _change(() => editor.setColor(color)),
                    icon: Container(width: 24, height: 24,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Color(color),
                        border: color == editor.activeColor ? Border.all(color: Colors.white, width: 2) : null,
                        boxShadow: color == editor.activeColor
                          ? const [BoxShadow(color: Color(0xffb8c5d0), spreadRadius: 2)] : null),
                      child: color == editor.activeColor
                        ? Icon(Icons.check, size: 14, color: editor.highlighting ? _toolInk : Colors.white) : null))),
            ])))),
      )),
    ]));
}

class _WidthButton extends StatelessWidget {
  const _WidthButton({required this.width, required this.highlighting,
    required this.selected, required this.onPressed});
  final double width;
  final bool highlighting;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '${_widthLabel(width)} pt ${highlighting ? 'highlighter' : 'pen'}',
    isSelected: selected, onPressed: onPressed,
    style: IconButton.styleFrom(minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: selected ? const Color(0xffedf0f4) : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    icon: SizedBox(width: 22, height: 24, child: Center(child: Container(
      height: highlighting ? width / 3 : width.clamp(.65, 8),
      decoration: BoxDecoration(color: _toolInk, borderRadius: BorderRadius.circular(8))))));
}

class _WidthPicker extends StatefulWidget {
  const _WidthPicker({required this.initialWidth, required this.highlighting, required this.color});
  final double initialWidth;
  final bool highlighting;
  final Color color;
  @override
  State<_WidthPicker> createState() => _WidthPickerState();
}

class _WidthPickerState extends State<_WidthPicker> {
  late double _width = widget.initialWidth;
  late final _input = TextEditingController(text: _widthLabel(_width));
  String? _error;
  double get _min => widget.highlighting ? 6 : .1;
  double get _max => widget.highlighting ? 40 : 8;

  void _select(double value) => setState(() {
    _width = double.parse(value.toStringAsFixed(2));
    _input.text = _widthLabel(_width);
    _error = null;
  });

  void _type(String text) {
    final value = double.tryParse(text.replaceAll(',', '.'));
    setState(() {
      _error = value == null || !value.isFinite || value < _min || value > _max
        ? 'Enter a size from ${_widthLabel(_min)} to ${_widthLabel(_max)} pt' : null;
      if (_error == null) _width = double.parse(value!.toStringAsFixed(2));
    });
  }

  @override
  void dispose() { _input.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.highlighting ? 'Highlighter width' : 'Pen tip size'),
    content: SizedBox(width: 336, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 64, alignment: Alignment.center,
          decoration: BoxDecoration(color: const Color(0xfff5f6f8), borderRadius: BorderRadius.circular(12)),
          child: Container(width: 230, height: _width,
            decoration: BoxDecoration(color: widget.color.withValues(alpha: widget.highlighting ? .3 : 1),
              borderRadius: BorderRadius.circular(20)))),
        const SizedBox(height: 16),
        TextField(key: const ValueKey('tip-size-input'), controller: _input,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Size', suffixText: 'pt', errorText: _error,
            border: const OutlineInputBorder()),
          onChanged: _type, onSubmitted: (_) { if (_error == null) Navigator.pop(context, _width); }),
        Slider(semanticFormatterCallback: (value) => '${_widthLabel(value)} points',
          value: _width.clamp(_min, _max), min: _min, max: _max,
          divisions: widget.highlighting ? 34 : 158, onChanged: _select),
        Text(widget.highlighting ? 'Highlight presets' : 'Fine tips & everyday sizes',
          style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final width in widget.highlighting ? [6.0, 10.0, 16.0, 24.0, 32.0, 40.0]
            : [.1, .25, .35, .5, .7, 1.0, 1.2, 1.5, 2.2, 3.0, 4.0, 6.0, 8.0])
            ChoiceChip(label: Text(_widthLabel(width)), selected: (_width - width).abs() < .001,
              onSelected: (_) => _select(width)),
        ]),
        const SizedBox(height: 12),
        const Text('Sizes are in PDF points and scale with page zoom.', style: TextStyle(fontSize: 12, color: Color(0xff667383))),
      ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _error == null ? () => Navigator.pop(context, _width) : null,
        child: const Text('Apply'))]);
}
