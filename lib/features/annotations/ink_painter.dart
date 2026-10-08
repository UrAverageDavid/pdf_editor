import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'ink.dart';

/// A conservative midpoint smoother with pressure-varying segments.
/// Kept separate so raw stored samples never depend on the painting algorithm.
class StrokeSmoother {
  static void paint(Canvas canvas, Size size, List<InkPoint> points,
      double width, Color color) {
    if (points.isEmpty) return;
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
  CommittedInkPainter(this.editor, this.page, this.pageWidth, {this.hidden = const {}})
      : super(repaint: editor.pageSignal(page));
  final EditorController editor;
  final int page;
  final double pageWidth;
  final Set<String> hidden;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in editor.strokes(page)) {
      if (!hidden.contains(stroke.id)) {
        StrokeSmoother.paint(canvas, size, stroke.points,
            stroke.width * size.width / pageWidth, Color(stroke.color));
      }
    }
  }

  @override
  bool shouldRepaint(CommittedInkPainter old) => old.editor != editor ||
      old.page != page || old.pageWidth != pageWidth || old.hidden != hidden;
}

class ActiveInk extends ChangeNotifier {
  int? page;
  double width = 2;
  int color = 0xff2947c7;
  final points = <InkPoint>[];
  void changed() => notifyListeners();
  void clear() { page = null; points.clear(); notifyListeners(); }
}

class ActiveInkPainter extends CustomPainter {
  ActiveInkPainter(this.ink, this.page, this.pageWidth) : super(repaint: ink);
  final ActiveInk ink;
  final int page;
  final double pageWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (ink.page == page) StrokeSmoother.paint(canvas, size, ink.points,
        ink.width * size.width / pageWidth, Color(ink.color));
  }

  @override
  bool shouldRepaint(ActiveInkPainter old) => old.ink != ink || old.page != page ||
      old.pageWidth != pageWidth;
}
