import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'viewport_controller.dart';

/// The PDF canvas has its own pan/zoom transform rather than a ScrollPosition.
/// Keep this control outside its input listener so pen drags cannot create ink.
class DocumentScrollbar extends StatefulWidget {
  const DocumentScrollbar({super.key, required this.viewport,
    required this.onInteractionStart});
  final ViewportController viewport;
  final VoidCallback onInteractionStart;

  @override
  State<DocumentScrollbar> createState() => _DocumentScrollbarState();
}

class _DocumentScrollbarState extends State<DocumentScrollbar> {
  int? _pointer;
  double _grabOffset = 0;

  void _step(double direction) {
    final view = widget.viewport;
    if (view.inputActive || view.verticalScrollExtent == 0) return;
    widget.onInteractionStart();
    view.scrollToFraction(view.scrollFraction +
      direction * view.size.height * .9 / view.verticalScrollExtent);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewport,
    builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
      final view = widget.viewport;
      final height = constraints.maxHeight;
      final extent = view.verticalScrollExtent;
      final thumbHeight = math.min(height, math.max(40.0,
        height * view.size.height / (view.size.height + extent)));
      final travel = height - thumbHeight;
      final top = travel * view.scrollFraction;
      final enabled = extent > 0 && !view.inputActive;
      void seek(double y) {
        if (travel > 0) view.scrollToFraction((y - _grabOffset) / travel);
      }
      String describe(double fraction) {
        final y = (extent * fraction.clamp(0.0, 1.0) + view.size.height / 2) / view.scale;
        return 'Page ${view.layout.pageAtY(y) + 1} of ${view.layout.pages.length}';
      }
      final step = extent > 0 ? view.size.height * .9 / extent : 0.0;
      return Semantics(
        label: 'Document position',
        value: describe(view.scrollFraction),
        increasedValue: enabled ? describe(view.scrollFraction + step) : null,
        decreasedValue: enabled ? describe(view.scrollFraction - step) : null,
        onIncrease: enabled ? () => _step(1) : null,
        onDecrease: enabled ? () => _step(-1) : null,
        child: MouseRegion(cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Listener(
            key: const ValueKey('document-scrollbar'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (_pointer != null || view.inputActive || extent == 0 ||
                  (event.kind == PointerDeviceKind.mouse &&
                    (event.buttons & kPrimaryMouseButton) == 0)) return;
              _pointer = event.pointer;
              final y = event.localPosition.dy;
              _grabOffset = y >= top && y <= top + thumbHeight ? y - top : thumbHeight / 2;
              widget.onInteractionStart();
              seek(y);
            },
            onPointerMove: (event) {
              if (event.pointer == _pointer) seek(event.localPosition.dy);
            },
            onPointerUp: (event) { if (event.pointer == _pointer) _pointer = null; },
            onPointerCancel: (event) { if (event.pointer == _pointer) _pointer = null; },
            child: Stack(children: [
              Positioned(top: 0, bottom: 0, left: 10, width: 4,
                child: DecoratedBox(decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(4)))),
              Positioned(top: top, height: thumbHeight, left: 8, width: 8,
                child: DecoratedBox(key: const ValueKey('document-scrollbar-thumb'),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: extent > 0 ? .5 : .2),
                    borderRadius: BorderRadius.circular(4)))),
            ]),
          ),
        ),
      );
    }),
  );
}
