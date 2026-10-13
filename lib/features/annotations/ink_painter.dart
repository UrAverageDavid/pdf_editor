import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'ink.dart';

/// A conservative midpoint smoother with pressure-varying segments.
/// Kept separate so stored samples never depend on the painting algorithm.
class StrokeSmoother {
  static void paint(Canvas canvas, Size size, List<InkPoint> points,
      double width, Color color, {InkKind kind = InkKind.pen,
      InkShape shape = InkShape.freehand}) {
    if (points.isEmpty) return;
    if (kind == InkKind.highlighter || shape != InkShape.freehand) {
      // One path gives the marker uniform opacity, including self-overlaps.
      final paint = Paint()
        ..color = kind == InkKind.highlighter ? color.withValues(alpha: .3) : color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final first = points.first.inSize(size);
      if (points.length == 1) {
        canvas.drawCircle(first, width / 2, paint..style = PaintingStyle.fill);
        return;
      }
      final path = Path()..moveTo(first.dx, first.dy);
      for (final point in points.skip(1)) {
        final next = point.inSize(size);
        path.lineTo(next.dx, next.dy);
      }
      canvas.drawPath(path, paint);
      return;
    }
    final paint = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    double pointWidth(InkPoint p) => width * (.4 + p.pressure * .8);
    if (points.length == 1) {
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(points.first.inSize(size), pointWidth(points.first) / 2, paint);
      return;
    }
    var start = points.first.inSize(size);
    for (var i = 1; i < points.length; i++) {
      final control = points[i - 1].inSize(size);
      final next = points[i].inSize(size);
      final end = i == points.length - 1 ? next : (control + next) / 2;
      paint.strokeWidth = math.max(.1, (pointWidth(points[i - 1]) + pointWidth(points[i])) / 2);
      canvas.drawPath(Path()..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy), paint);
      start = end;
    }
  }
}

class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter(this.editor, this.page, this.pageWidth, {this.hidden = const {},
    this.surface = InkSurface.page, this.referenceSize})
      : super(repaint: editor.pageSignal(page));
  final EditorController editor;
  final int page;
  final double pageWidth;
  final Set<String> hidden;
  final InkSurface surface;
  final Size? referenceSize;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in editor.strokes(page)) {
      if (stroke.surface == surface && !hidden.contains(stroke.id)) {
        final reference = referenceSize ?? size;
        StrokeSmoother.paint(canvas, reference, stroke.points,
            stroke.width * reference.width / pageWidth, Color(stroke.color),
            kind: stroke.kind, shape: stroke.shape);
      }
    }
  }

  @override
  bool shouldRepaint(CommittedInkPainter old) => old.editor != editor ||
      old.page != page || old.pageWidth != pageWidth || old.hidden != hidden ||
      old.surface != surface || old.referenceSize != referenceSize;
}

class ActiveInk extends ChangeNotifier {
  int? page;
  InkSurface surface = InkSurface.page;
  double width = 2;
  int color = 0xff2947c7;
  InkKind kind = InkKind.pen;
  final points = <InkPoint>[];
  void changed() => notifyListeners();
  void clear() { page = null; points.clear(); notifyListeners(); }
}

class ActiveInkPainter extends CustomPainter {
  ActiveInkPainter(this.ink, this.page, this.pageWidth,
    {this.surface = InkSurface.page, this.referenceSize}) : super(repaint: ink);
  final ActiveInk ink;
  final int page;
  final double pageWidth;
  final InkSurface surface;
  final Size? referenceSize;

  @override
  void paint(Canvas canvas, Size size) {
    final reference = referenceSize ?? size;
    if (ink.page == page && ink.surface == surface) StrokeSmoother.paint(canvas, reference, ink.points,
        ink.width * reference.width / pageWidth, Color(ink.color), kind: ink.kind);
  }

  @override
  bool shouldRepaint(ActiveInkPainter old) => old.ink != ink || old.page != page ||
      old.pageWidth != pageWidth || old.surface != surface || old.referenceSize != referenceSize;
}
