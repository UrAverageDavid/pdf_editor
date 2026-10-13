import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../features/annotations/editor_controller.dart';
import '../features/annotations/ink.dart';
import '../features/annotations/ink_painter.dart';
import '../features/annotations/pen_preset.dart';

String _sizeLabel(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
IconData _penIcon(PenType type) => switch (type) {
  PenType.fountain => Icons.draw_outlined,
  PenType.ball => Icons.edit_outlined,
  PenType.brush => Icons.brush_outlined,
  PenType.highlighter => Icons.border_color_outlined,
};

const penMenuStyle = MenuStyle(
  alignment: Alignment.bottomLeft,
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  backgroundColor: WidgetStatePropertyAll(Color(0xfffafbfc)),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
  ),
);

class PenPresets extends StatefulWidget {
  const PenPresets({
    super.key,
    required this.editor,
    required this.finishInput,
  });
  final EditorController editor;
  final VoidCallback finishInput;
  @override
  State<PenPresets> createState() => _PenPresetsState();
}

class _PenPresetsState extends State<PenPresets> {
  String? _createdId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.editor,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final preset in widget.editor.penPresets)
          _PresetButton(
            key: ValueKey(preset.id),
            preset: preset,
            editor: widget.editor,
            finishInput: widget.finishInput,
            openInitially: preset.id == _createdId,
          ),
        IconButton(
          tooltip: 'Create pen preset',
          icon: const Icon(Icons.add, size: 20),
          onPressed: () {
            widget.finishInput();
            widget.editor.createPen();
            setState(() => _createdId = widget.editor.selectedPen.id);
          },
        ),
      ],
    ),
  );
}

class _PresetButton extends StatefulWidget {
  const _PresetButton({
    super.key,
    required this.preset,
    required this.editor,
    required this.finishInput,
    this.openInitially = false,
  });
  final PenPreset preset;
  final EditorController editor;
  final VoidCallback finishInput;
  final bool openInitially;
  @override
  State<_PresetButton> createState() => _PresetButtonState();
}

class _PresetButtonState extends State<_PresetButton> {
  final _menu = MenuController();
  double _availableHeight = 440;
  void _open() {
    final box = context.findRenderObject() as RenderBox;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    setState(
      () => _availableHeight = math.max(
        80,
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            bottom -
            24,
      ),
    );
    _menu.open();
  }

  @override
  void initState() {
    super.initState();
    if (widget.openInitially)
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await Scrollable.ensureVisible(context);
        if (mounted) _open();
      });
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final selected =
        widget.editor.tool == EditorTool.pen &&
        widget.editor.selectedPen.id == preset.id;
    return MenuAnchor(
      controller: _menu,
      style: penMenuStyle,
      alignmentOffset: const Offset(0, 8),
      consumeOutsideTap: true,
      menuChildren: [
        PenSettings(
          editor: widget.editor,
          presetId: preset.id,
          finishInput: widget.finishInput,
          close: _menu.close,
          maxHeight: _availableHeight,
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message:
            '${preset.name} · ${preset.style.type.label} · ${_sizeLabel(preset.width)} pt\nSelect pen; tap again for settings',
        child: Semantics(
          selected: selected,
          child: IconButton(
            key: ValueKey('pen-preset-${preset.id}'),
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              backgroundColor: selected
                  ? const Color(0xffd9f0f3)
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              widget.finishInput();
              widget.editor.selectPen(preset.id);
              if (selected) {
                controller.isOpen ? controller.close() : _open();
              }
            },
            icon: Icon(
              _penIcon(preset.style.type),
              size: 24,
              color: Color(preset.color),
            ),
          ),
        ),
      ),
    );
  }
}

class PenSettings extends StatefulWidget {
  const PenSettings({
    super.key,
    required this.editor,
    required this.presetId,
    required this.finishInput,
    required this.close,
    required this.maxHeight,
  });
  final EditorController editor;
  final String presetId;
  final VoidCallback finishInput;
  final VoidCallback close;
  final double maxHeight;
  @override
  State<PenSettings> createState() => _PenSettingsState();
}

class _PenSettingsState extends State<PenSettings> {
  PenPreset get _preset =>
      widget.editor.penPresets.firstWhere((p) => p.id == widget.presetId);
  late final _name = TextEditingController(text: _preset.name);
  late final _width = TextEditingController(text: _sizeLabel(_preset.width));
  String? _widthError;
  void _update(PenPreset preset) {
    widget.finishInput();
    widget.editor.updatePen(preset);
  }

  void _style({PenType? type, double? pressure, double? sharpness}) {
    final old = _preset.style;
    final nextType = type ?? old.type;
    var width = _preset.width;
    if (nextType != old.type &&
        (width < nextType.minWidth || width > nextType.maxWidth)) {
      width = nextType == PenType.highlighter ? 16 : 2.2;
    }
    if (nextType != old.type) {
      setState(() {
        _widthError = null;
        _width.text = _sizeLabel(width);
      });
    }
    _update(
      _preset.copyWith(
        width: width,
        style: PenStyle(
          type: type ?? old.type,
          pressureSensitivity: pressure ?? old.pressureSensitivity,
          tipSharpness: sharpness ?? old.tipSharpness,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _width.dispose();
    super.dispose();
  }

  Widget _slider(
    String label,
    String key,
    double value,
    ValueChanged<double> change,
  ) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      Slider(
        key: ValueKey(key),
        value: value,
        divisions: 100,
        semanticFormatterCallback: (v) => '${(v * 100).round()}%',
        onChanged: change,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.editor,
    builder: (context, _) {
      final preset = _preset;
      final highlighting = preset.style.type == PenType.highlighter;
      final minWidth = preset.style.type.minWidth;
      final maxWidth = preset.style.type.maxWidth;
      final available = MediaQuery.sizeOf(context);
      return SizedBox(
        key: const ValueKey('pen-settings-popover'),
        width: math.min(304, available.width - 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(
              80,
              math.min(
                500,
                math.min(
                  widget.maxHeight,
                  available.height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      140,
                ),
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        preset.style.type.label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close pen settings',
                      onPressed: widget.close,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 60,
                        width: double.infinity,
                        child: CustomPaint(painter: _PenPreview(preset)),
                      ),
                      TextField(
                        key: const ValueKey('preset-name'),
                        controller: _name,
                        maxLength: 32,
                        decoration: const InputDecoration(
                          labelText: 'Preset name',
                          isDense: true,
                          counterText: '',
                        ),
                        onChanged: (name) {
                          if (name.trim().isNotEmpty)
                            _update(_preset.copyWith(name: name.trim()));
                        },
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final type in PenType.values)
                            SizedBox(
                              width: 131,
                              child: TextButton.icon(
                                key: ValueKey('pen-type-${type.name}'),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 10,
                                  ),
                                  backgroundColor: preset.style.type == type
                                      ? const Color(0xffd9f0f3)
                                      : Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () => _style(type: type),
                                icon: Icon(_penIcon(type), size: 22),
                                label: Text(
                                  type.label,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final entry in const {
                            0xff242c35: 'black',
                            0xff2947c7: 'blue',
                            0xffb34a3e: 'red',
                            0xff39755b: 'green',
                            0xffffd740: 'yellow',
                            0xff69f0ae: 'mint',
                            0xff40c4ff: 'cyan',
                            0xffff80ab: 'pink',
                          }.entries)
                            Semantics(
                              selected: preset.color == entry.key,
                              child: IconButton(
                                tooltip: 'Choose ${entry.value} ink',
                                onPressed: () =>
                                    _update(_preset.copyWith(color: entry.key)),
                                icon: Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: Color(entry.key),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xffb8c5d0),
                                    ),
                                  ),
                                  child: preset.color == entry.key
                                      ? Icon(
                                          Icons.check,
                                          size: 16,
                                          color:
                                              entry.key == 0xff242c35 ||
                                                  entry.key == 0xff2947c7 ||
                                                  entry.key == 0xffb34a3e ||
                                                  entry.key == 0xff39755b
                                              ? Colors.white
                                              : const Color(0xff253447),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const ValueKey('tip-size-input'),
                        controller: _width,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Tip size',
                          suffixText: 'pt',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          errorText: _widthError,
                        ),
                        onChanged: (text) {
                          final value = double.tryParse(
                            text.replaceAll(',', '.'),
                          );
                          final valid =
                              value != null &&
                              value.isFinite &&
                              value >= minWidth &&
                              value <= maxWidth;
                          setState(
                            () => _widthError = valid
                                ? null
                                : 'Enter ${_sizeLabel(minWidth)}–${_sizeLabel(maxWidth)} pt',
                          );
                          if (valid) _update(_preset.copyWith(width: value));
                        },
                      ),
                      Slider(
                        key: const ValueKey('pen-size-slider'),
                        value: preset.width,
                        min: minWidth,
                        max: maxWidth,
                        divisions: highlighting ? 34 : 158,
                        semanticFormatterCallback: (v) =>
                            '${_sizeLabel(v)} points',
                        onChanged: (value) {
                          final width = double.parse(value.toStringAsFixed(2));
                          setState(() {
                            _widthError = null;
                            _width.text = _sizeLabel(width);
                          });
                          _update(_preset.copyWith(width: width));
                        },
                      ),
                      if (!highlighting)
                        _slider(
                          'TIP SHARPNESS',
                          'tip-sharpness',
                          preset.style.tipSharpness,
                          (value) => _style(sharpness: value),
                        ),
                      if (!highlighting)
                        _slider(
                          'PRESSURE SENSITIVITY',
                          'pressure-sensitivity',
                          preset.style.pressureSensitivity,
                          (value) => _style(pressure: value),
                        ),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Saved with this document',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xff667383),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete pen preset',
                            onPressed: widget.editor.penPresets.length > 1
                                ? () {
                                    widget.close();
                                    widget.finishInput();
                                    widget.editor.deletePen(widget.presetId);
                                  }
                                : null,
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _PenPreview extends CustomPainter {
  const _PenPreview(this.preset);
  final PenPreset preset;
  @override
  void paint(Canvas canvas, Size size) {
    final points = List.generate(49, (i) {
      final t = i / 48;
      return InkPoint(
        .06 + .88 * t,
        .5 + .27 * math.sin(t * math.pi * 2),
        .15 + .85 * math.sin(t * math.pi),
        i,
      );
    });
    StrokeSmoother.paint(
      canvas,
      size,
      points,
      preset.width * (preset.style.type == PenType.highlighter ? 1 : 2),
      Color(preset.color),
      penStyle: preset.style,
    );
  }

  @override
  bool shouldRepaint(_PenPreview oldDelegate) => oldDelegate.preset != preset;
}
