import 'dart:math' as math;
import 'dart:ui';

import 'pen_preset.dart';

enum EditorTool { pen, eraser, hand }
enum InkSurface { page, notes }
enum InkKind { pen, highlighter }
enum InkShape { freehand, line, arrow, rectangle, triangle, ellipse }

/// Coordinates use the original displayed (rotated) page size as their unit.
/// The origin is the top-left of the stroke's surface; note x may exceed 1.
class InkPoint {
  const InkPoint(this.x, this.y, this.pressure, this.timeMicros);
  final double x;
  final double y;
  final double pressure;
  final int timeMicros;

  Offset inSize(Size size) => Offset(x * size.width, y * size.height);
  List<num> toJson() => [x, y, pressure, timeMicros];

  factory InkPoint.fromJson(List<dynamic> value, {bool extended = false}) {
    final x = (value[0] as num).toDouble();
    final y = (value[1] as num).toDouble();
    final pressure = (value[2] as num).toDouble();
    if (!x.isFinite || !y.isFinite || !pressure.isFinite ||
        x < 0 || (!extended && x > 1) || y < 0 || y > 1 || pressure < 0 || pressure > 1) {
      throw const FormatException('Invalid ink coordinates');
    }
    return InkPoint(x, y, pressure, (value[3] as num).toInt());
  }
}

class InkStroke {
  InkStroke({required this.id, required this.pageIndex, required List<InkPoint> points,
    required this.width, required this.color, required this.createdAt,
    this.surface = InkSurface.page, this.kind = InkKind.pen,
    this.shape = InkShape.freehand, this.penStyle})
      : points = List.unmodifiable(points);

  final String id;
  final int pageIndex;
  /// Notes use the original page size as a fixed reference, even when expanded.
  final InkSurface surface;
  final InkKind kind;
  final InkShape shape;
  final PenStyle? penStyle;
  final List<InkPoint> points;
  /// Width in PDF display points, independent of viewport size or zoom.
  final double width;
  final int color;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id, 'page': pageIndex, 'surface': surface.name,
    'kind': kind.name, 'shape': shape.name,
    if (penStyle != null) 'penStyle': penStyle!.toJson(),
    'points': points.map((p) => p.toJson()).toList(),
    'width': width, 'color': color, 'createdAt': createdAt.toIso8601String(),
  };

  factory InkStroke.fromJson(Map<String, dynamic> value) {
    final surface = switch (value['surface']) {
      null || 'page' => InkSurface.page,
      'notes' => InkSurface.notes,
      _ => throw const FormatException('Invalid ink surface'),
    };
    final width = (value['width'] as num).toDouble();
    T decode<T extends Enum>(List<T> values, String key, T fallback) {
      final name = value[key];
      if (name == null) return fallback;
      for (final item in values) { if (item.name == name) return item; }
      throw FormatException('Invalid ink $key');
    }
    final points = (value['points'] as List<dynamic>)
        .map((p) => InkPoint.fromJson(p as List<dynamic>, extended: surface == InkSurface.notes)).toList();
    if (!width.isFinite || width <= 0 || points.isEmpty) {
      throw const FormatException('Invalid stroke');
    }
    return InkStroke(id: value['id'] as String, pageIndex: value['page'] as int, surface: surface,
      points: points, width: width, color: value['color'] as int,
      penStyle: value['penStyle'] == null ? null : PenStyle.fromJson(value['penStyle'] as Map<String, dynamic>),
      kind: decode(InkKind.values, 'kind', InkKind.pen),
      shape: decode(InkShape.values, 'shape', InkShape.freehand),
      createdAt: DateTime.parse(value['createdAt'] as String));
  }
}

double pointSegmentDistance(Offset p, Offset a, Offset b) {
  final d = b - a;
  if (d.distanceSquared == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * d.dx + (p.dy - a.dy) * d.dy) /
      d.distanceSquared).clamp(0.0, 1.0).toDouble();
  return (p - (a + d * t)).distance;
}

/// Swept eraser: fast movement must not skip strokes between pointer samples.
bool strokeIntersects(InkStroke stroke, Size pageSize, Offset from, Offset to,
    double radius) {
  final threshold = radius + stroke.width * .75;
  var previous = stroke.points.first.inSize(pageSize);
  if (pointSegmentDistance(previous, from, to) <= threshold) return true;
  for (final point in stroke.points.skip(1)) {
    final next = point.inSize(pageSize);
    if (_segmentsCross(previous, next, from, to) ||
        math.min(math.min(pointSegmentDistance(previous, from, to),
            pointSegmentDistance(next, from, to)),
          math.min(pointSegmentDistance(from, previous, next),
            pointSegmentDistance(to, previous, next))) <= threshold) return true;
    previous = next;
  }
  return false;
}

bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  double cross(Offset u, Offset v) => u.dx * v.dy - u.dy * v.dx;
  final ab = b - a;
  final cd = d - c;
  final denom = cross(ab, cd);
  if (denom.abs() < 1e-10) return false;
  final t = cross(c - a, cd) / denom;
  final u = cross(c - a, ab) / denom;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}
