import 'dart:math' as math;
import 'dart:ui';

enum EditorTool { pen, eraser, hand }

/// Coordinates are relative to the displayed (rotated) page, top-left origin.
class InkPoint {
  const InkPoint(this.x, this.y, this.pressure, this.timeMicros);
  final double x;
  final double y;
  final double pressure;
  final int timeMicros;

  Offset inSize(Size size) => Offset(x * size.width, y * size.height);
  List<num> toJson() => [x, y, pressure, timeMicros];

  factory InkPoint.fromJson(List<dynamic> value) {
    final x = (value[0] as num).toDouble();
    final y = (value[1] as num).toDouble();
    final pressure = (value[2] as num).toDouble();
    if (!x.isFinite || !y.isFinite || !pressure.isFinite ||
        x < 0 || x > 1 || y < 0 || y > 1 || pressure < 0 || pressure > 1) {
      throw const FormatException('Invalid ink coordinates');
    }
    return InkPoint(x, y, pressure, (value[3] as num).toInt());
  }
}

class InkStroke {
  InkStroke({required this.id, required this.pageIndex, required List<InkPoint> points,
    required this.width, required this.color, required this.createdAt})
      : points = List.unmodifiable(points);

  final String id;
  final int pageIndex;
  final List<InkPoint> points;
  /// Width in PDF display points, independent of viewport size or zoom.
  final double width;
  final int color;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id, 'page': pageIndex, 'points': points.map((p) => p.toJson()).toList(),
    'width': width, 'color': color, 'createdAt': createdAt.toIso8601String(),
  };

  factory InkStroke.fromJson(Map<String, dynamic> value) {
    final width = (value['width'] as num).toDouble();
    final points = (value['points'] as List<dynamic>)
        .map((p) => InkPoint.fromJson(p as List<dynamic>)).toList();
    if (!width.isFinite || width <= 0 || points.isEmpty) {
      throw const FormatException('Invalid stroke');
    }
    return InkStroke(id: value['id'] as String, pageIndex: value['page'] as int,
      points: points, width: width, color: value['color'] as int,
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
