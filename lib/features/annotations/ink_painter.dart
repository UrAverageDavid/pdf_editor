import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'ink.dart';
import 'pen_preset.dart';

/// A conservative midpoint smoother with pressure-varying segments.
/// Kept separate so stored samples never depend on the painting algorithm.
class StrokeSmoother {
  static void paint(Canvas canvas, Size size, List<InkPoint> points,
      double width, Color color, {InkKind kind = InkKind.pen,
      InkShape shape = InkShape.freehand, PenStyle? penStyle,
      int startSegment = 1, int? endSegment}) {
    if (points.isEmpty) return;
    final highlighting = kind == InkKind.highlighter || penStyle?.type == PenType.highlighter;
    if (highlighting || shape != InkShape.freehand) {
      // One path gives the marker uniform opacity, including self-overlaps.
      final paint = Paint()
        ..color = highlighting ? color.withValues(alpha: .3) : color
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
    double pointWidth(InkPoint p, int index) {
      if (penStyle == null) return width * (.4 + p.pressure * .8);
      final style = penStyle;
      final response = switch (style.type) {
        PenType.ball => .3, PenType.fountain => .8, PenType.brush => 1.3, PenType.highlighter => 0,
      };
      final pressure = 1 + (p.pressure - .75) * 2 * style.pressureSensitivity * response;
      var nib = 1.0;
      if (style.type == PenType.fountain && points.length > 1) {
        final a = points[math.max(0, index - 1)].inSize(size);
        final b = points[math.min(points.length - 1, index + 1)].inSize(size);
        final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
        nib = 1 - style.tipSharpness * .65 * math.cos(angle - math.pi / 4).abs();
      } else if (style.type == PenType.brush && points.length > 1) {
        final edge = math.min(index, points.length - 1 - index) / math.min(6, points.length / 2);
        nib = 1 - style.tipSharpness * .8 * (1 - edge.clamp(0.0, 1.0));
      } else if (style.type == PenType.ball) {
        nib = 1 - style.tipSharpness * .2;
      }
      return width * math.max(.08, pressure) * nib;
    }
    if (points.length == 1) {
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(points.first.inSize(size), pointWidth(points.first, 0) / 2, paint);
      return;
    }
    var start = startSegment == 1 ? points.first.inSize(size) :
      (points[startSegment - 2].inSize(size) + points[startSegment - 1].inSize(size)) / 2;
    for (var i = startSegment; i < (endSegment ?? points.length); i++) {
      final control = points[i - 1].inSize(size);
      final next = points[i].inSize(size);
      final end = i == points.length - 1 ? next : (control + next) / 2;
      paint.strokeWidth = math.max(.1, (pointWidth(points[i - 1], i - 1) + pointWidth(points[i], i)) / 2);
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
            kind: stroke.kind, shape: stroke.shape, penStyle: stroke.penStyle);
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
  PenStyle? penStyle;
  final points = <InkPoint>[];
  final _renderer = _LiveStrokeRenderer();
  void changed() => notifyListeners();
  void clear() { page = null; points.clear(); _renderer.reset(); notifyListeners(); }
  @override
  void dispose() { _renderer.reset(); super.dispose(); }
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
    if (ink.page == page && ink.surface == surface) ink._renderer.paint(canvas, reference, ink.points,
        ink.width * reference.width / pageWidth, Color(ink.color), kind: ink.kind, penStyle: ink.penStyle);
  }

  @override
  bool shouldRepaint(ActiveInkPainter old) => old.ink != ink || old.page != page ||
      old.pageWidth != pageWidth || old.surface != surface || old.referenceSize != referenceSize;
}


/// Cache stable geometry in small pictures. Fountain nib direction needs adjacent
/// samples; brush taper changes the last six samples, so keep eight in the live tail.
/// Pictures belong to the gesture, not the widget, and survive writing-area rebuilds.
class _LiveStrokeRenderer {
  static const _chunkSegments = 128;
  static const _tailSamples = 8;
  final _chunks = <ui.Picture>[];
  int _nextSegment = 1;
  int _lastCount = 0;
  Size? _size;
  double? _width;
  Color? _color;
  InkKind? _kind;
  PenStyle? _style;
  Path _markerPath = Path();
  int _markerCount = 0;

  void reset() {
    for (final picture in _chunks) { picture.dispose(); }
    _chunks.clear();
    _nextSegment = 1;
    _lastCount = 0;
    _markerPath = Path();
    _markerCount = 0;
    _size = null;
  }

  void paint(Canvas canvas, Size size, List<InkPoint> points, double width, Color color,
      {required InkKind kind, PenStyle? penStyle}) {
    if (points.isEmpty) return;
    if (_size != size || _width != width || _color != color || _kind != kind ||
        _style != penStyle || points.length < _lastCount) {
      reset();
      _size = size;
      _width = width;
      _color = color;
      _kind = kind;
      _style = penStyle;
    }
    _lastCount = points.length;
    if (kind == InkKind.highlighter || penStyle?.type == PenType.highlighter) {
      // One path preserves uniform translucency at retraced sections and joins.
      for (var i = _markerCount; i < points.length; i++) {
        final p = points[i].inSize(size);
        if (i == 0) { _markerPath.moveTo(p.dx, p.dy); }
        else { _markerPath.lineTo(p.dx, p.dy); }
      }
      _markerCount = points.length;
      final paint = Paint()..color = color.withValues(alpha: .3)
        ..style = PaintingStyle.stroke..strokeWidth = width
        ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
      if (points.length == 1) {
        canvas.drawCircle(points.first.inSize(size), width / 2, paint..style = PaintingStyle.fill);
      } else { canvas.drawPath(_markerPath, paint); }
      return;
    }
    final stableEnd = points.length - _tailSamples;
    while (_nextSegment + _chunkSegments <= stableEnd) {
      final recorder = ui.PictureRecorder();
      StrokeSmoother.paint(Canvas(recorder), size, points, width, color,
        kind: kind, penStyle: penStyle, startSegment: _nextSegment,
        endSegment: _nextSegment + _chunkSegments);
      _chunks.add(recorder.endRecording());
      _nextSegment += _chunkSegments;
    }
    for (final picture in _chunks) { canvas.drawPicture(picture); }
    StrokeSmoother.paint(canvas, size, points, width, color,
      kind: kind, penStyle: penStyle, startSegment: _nextSegment);
  }
}
