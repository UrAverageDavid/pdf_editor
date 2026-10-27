import 'package:flutter/material.dart';

import '../document/app_document.dart';

/// Guides remain anchored to the page's top-left as the margin resizes or zooms.
class WritingPaperPainter extends CustomPainter {
  const WritingPaperPainter({
    required this.pattern,
    required this.spacing,
    required this.scale,
    this.visibleRect,
  });
  final WritingPattern pattern;
  final WritingSpacing spacing;
  final double scale;
  /// Repaint boundaries record with their own clip, which may cover an
  /// enormous offscreen margin. Bound guides explicitly to the viewport.
  final Rect? visibleRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (pattern == WritingPattern.blank || scale <= 0 || !scale.isFinite)
      return;
    final step = spacing.points * scale;
    final visible = canvas.getLocalClipBounds().intersect(Offset.zero & size)
      .intersect(visibleRect ?? (Offset.zero & size));
    if (visible.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xffcbd3d9)
      ..strokeWidth = .7;
    // Only draw lines intersecting the clip, even for very wide notes or tall pages.
    for (
      var y = (visible.top / step).floor() * step;
      y <= visible.bottom;
      y += step
    ) {
      canvas.drawLine(Offset(visible.left, y), Offset(visible.right, y), paint);
    }
    if (pattern == WritingPattern.grid) {
      for (
        var x = (visible.left / step).floor() * step;
        x <= visible.right;
        x += step
      ) {
        canvas.drawLine(
          Offset(x, visible.top),
          Offset(x, visible.bottom),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(WritingPaperPainter oldDelegate) =>
      pattern != oldDelegate.pattern ||
      spacing != oldDelegate.spacing ||
      scale != oldDelegate.scale ||
      (pattern != WritingPattern.blank && visibleRect != oldDelegate.visibleRect);
}
