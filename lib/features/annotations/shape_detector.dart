import 'dart:math' as math;
import 'dart:ui';

import 'ink.dart';

class DetectedShape {
  const DetectedShape(this.shape, this.points);
  final InkShape shape;
  final List<InkPoint> points;
}

/// Conservative, single-stroke recognition in page points, independent of zoom
/// and page aspect ratio. Ambiguous handwriting is left untouched.
class ShapeDetector {
  static DetectedShape? detect(List<InkPoint> ink, Size size) {
    if (ink.length < 2) return null;
    final raw = ink.map((p) => p.inSize(size)).toList();
    final points = _resample(raw, 128);
    final bounds = _bounds(points);
    final diagonal = Offset(bounds.width, bounds.height).distance;
    if (diagonal < 18) return null;
    final tolerance = math.max(1.5, diagonal * .035);
    final length = _length(points);

    DetectedShape result(InkShape shape, List<Offset> path) => DetectedShape(
      shape, [for (var i = 0; i < path.length; i++)
        InkPoint(path[i].dx / size.width, path[i].dy / size.height, .75,
          ink.first.timeMicros + ((ink.last.timeMicros - ink.first.timeMicros) *
            i / math.max(1, path.length - 1)).round())]);

    final distance = (points.last - points.first).distance;
    if (distance > 18 && length / distance < 1.12 &&
        points.every((p) => pointSegmentDistance(p, points.first, points.last) <= tolerance)) {
      return result(InkShape.line, [raw.first, raw.last]);
    }

    final simplified = _simplify(points, tolerance);
    // Draw the shaft, one wing, return to the tip, then the other wing.
    if (simplified.length == 5) {
      final start = simplified[0];
      final tip = simplified[1];
      final shaft = tip - start;
      final shaftLength = shaft.distance;
      if (shaftLength > 24 && (simplified[3] - tip).distance < tolerance * 2) {
        final axis = shaft / shaftLength;
        final normal = Offset(-axis.dy, axis.dx);
        final a = simplified[2] - tip;
        final b = simplified[4] - tip;
        final backA = -_dot(a, axis), backB = -_dot(b, axis);
        final sideA = _dot(a, normal), sideB = _dot(b, normal);
        if (backA > shaftLength * .08 && backB > shaftLength * .08 &&
            backA < shaftLength * .5 && backB < shaftLength * .5 &&
            sideA * sideB < 0 && sideA.abs() > backA * .3 &&
            sideB.abs() > backB * .3 && sideA.abs() < backA * 1.8 &&
            sideB.abs() < backB * 1.8) {
          final back = (backA + backB) / 2;
          final side = (sideA.abs() + sideB.abs()) / 2;
          return result(InkShape.arrow, [start, tip,
            tip - axis * back + normal * side, tip,
            tip - axis * back - normal * side]);
        }
      }
    }

    if (distance > diagonal * .16 || bounds.width < 12 || bounds.height < 12) return null;
    // Split a loop across its diameter so simplification also works when the
    // user starts halfway along an edge instead of at a corner.
    var opposite = 1;
    for (var i = 2; i < points.length; i++) {
      if ((points[i] - points.first).distanceSquared >
          (points[opposite] - points.first).distanceSquared) opposite = i;
    }
    final closed = [...points, points.first];
    final polygon = [
      ..._simplify(closed.sublist(0, opposite + 1), tolerance),
      ..._simplify(closed.sublist(opposite), tolerance).skip(1),
    ]..removeLast();
    var changed = true;
    while (changed && polygon.length > 3) {
      changed = false;
      for (var i = 0; i < polygon.length; i++) {
        if (pointSegmentDistance(polygon[i], polygon[(i - 1 + polygon.length) % polygon.length],
            polygon[(i + 1) % polygon.length]) <= tolerance) {
          polygon.removeAt(i);
          changed = true;
          break;
        }
      }
    }
    final perimeter = _length([...polygon, polygon.first]);
    final followsPerimeter = (length - perimeter).abs() < perimeter * .14;
    if (followsPerimeter && polygon.length == 3 &&
        _area(polygon).abs() > bounds.width * bounds.height * .25) {
      return result(InkShape.triangle, [...polygon, polygon.first]);
    }
    if (followsPerimeter && polygon.length == 4) {
      var rectangular = true;
      for (var i = 0; i < 4; i++) {
        final a = polygon[(i + 1) % 4] - polygon[i];
        final b = polygon[(i + 2) % 4] - polygon[(i + 1) % 4];
        if (a.distance < 10 || b.distance < 10 ||
            _dot(a, b).abs() / (a.distance * b.distance) > .25) rectangular = false;
      }
      if (rectangular) {
        final center = polygon.reduce((a, b) => a + b) / 4;
        final edge = (polygon[1] - polygon[0]) + (polygon[2] - polygon[3]);
        final axis = edge / edge.distance;
        final normal = Offset(-axis.dy, axis.dx);
        final halfWidth = polygon.map((p) => _dot(p - center, axis).abs()).reduce((a, b) => a + b) / 4;
        final halfHeight = polygon.map((p) => _dot(p - center, normal).abs()).reduce((a, b) => a + b) / 4;
        final corners = [center - axis * halfWidth - normal * halfHeight,
          center + axis * halfWidth - normal * halfHeight,
          center + axis * halfWidth + normal * halfHeight,
          center - axis * halfWidth + normal * halfHeight];
        return result(InkShape.rectangle, [...corners, corners.first]);
      }
    }

    // Ellipse fit with radial error and one full turn; rejects loops, spirals,
    // rectangles and backtracking even when they share a bounding box.
    final center = bounds.center;
    final rx = bounds.width / 2, ry = bounds.height / 2;
    var error = 0.0, turn = 0.0, absoluteTurn = 0.0;
    double? previousAngle;
    for (final point in points) {
      final x = (point.dx - center.dx) / rx, y = (point.dy - center.dy) / ry;
      error += (math.sqrt(x * x + y * y) - 1).abs();
      final angle = math.atan2(y, x);
      if (previousAngle != null) {
        var delta = angle - previousAngle;
        if (delta > math.pi) delta -= 2 * math.pi;
        if (delta < -math.pi) delta += 2 * math.pi;
        turn += delta;
        absoluteTurn += delta.abs();
      }
      previousAngle = angle;
    }
    if (error / points.length < .085 && turn.abs() > 5.6 &&
        turn.abs() < 6.8 && absoluteTurn < 7.2) {
      return result(InkShape.ellipse, [for (var i = 0; i <= 96; i++)
        center + Offset(rx * math.cos(i * math.pi / 48), ry * math.sin(i * math.pi / 48))]);
    }
    return null;
  }

  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
  static double _length(List<Offset> p) {
    var length = 0.0;
    for (var i = 1; i < p.length; i++) { length += (p[i] - p[i - 1]).distance; }
    return length;
  }
  static double _area(List<Offset> p) {
    var area = 0.0;
    for (var i = 0; i < p.length; i++) {
      final next = p[(i + 1) % p.length];
      area += p[i].dx * next.dy - p[i].dy * next.dx;
    }
    return area / 2;
  }
  static Rect _bounds(List<Offset> points) => Rect.fromLTRB(
    points.map((p) => p.dx).reduce(math.min), points.map((p) => p.dy).reduce(math.min),
    points.map((p) => p.dx).reduce(math.max), points.map((p) => p.dy).reduce(math.max));

  static List<Offset> _resample(List<Offset> points, int count) {
    final length = _length(points);
    if (length == 0) return [points.first, points.last];
    final result = <Offset>[points.first];
    var segment = 1;
    var traversed = 0.0;
    for (var i = 1; i < count - 1; i++) {
      final target = length * i / (count - 1);
      while (segment < points.length - 1 &&
          traversed + (points[segment] - points[segment - 1]).distance < target) {
        traversed += (points[segment] - points[segment - 1]).distance;
        segment++;
      }
      final distance = (points[segment] - points[segment - 1]).distance;
      result.add(Offset.lerp(points[segment - 1], points[segment],
        distance == 0 ? 0 : ((target - traversed) / distance).clamp(0.0, 1.0))!);
    }
    return result..add(points.last);
  }

  static List<Offset> _simplify(List<Offset> p, double tolerance) {
    var farthest = tolerance;
    var split = -1;
    for (var i = 1; i < p.length - 1; i++) {
      final distance = pointSegmentDistance(p[i], p.first, p.last);
      if (distance > farthest) { farthest = distance; split = i; }
    }
    if (split == -1) return [p.first, p.last];
    return [..._simplify(p.sublist(0, split + 1), tolerance),
      ..._simplify(p.sublist(split), tolerance).skip(1)];
  }
}
