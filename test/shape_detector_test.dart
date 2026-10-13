import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink.dart';
import 'package:papertrail/features/annotations/shape_detector.dart';

List<InkPoint> samples(List<Offset> vertices, Size size, {double noise = 0}) {
  final points = <InkPoint>[];
  for (var i = 1; i < vertices.length; i++) {
    for (var j = 0; j < 20; j++) {
      final p = Offset.lerp(vertices[i - 1], vertices[i], j / 20)! +
        Offset(math.sin(j * 3) * noise, math.cos(j * 2) * noise);
      points.add(InkPoint(p.dx / size.width, p.dy / size.height, .6, points.length * 1000));
    }
  }
  points.add(InkPoint(vertices.last.dx / size.width, vertices.last.dy / size.height, .6, points.length * 1000));
  return points;
}

void main() {
  const size = Size(612, 792);
  for (final angle in [0.0, .6, 1.7, 3.4]) {
    Offset rotate(Offset p) => const Offset(250, 300) + Offset(
      p.dx * math.cos(angle) - p.dy * math.sin(angle),
      p.dx * math.sin(angle) + p.dy * math.cos(angle));
    test('recognizes noisy lines and arrows at angle $angle', () {
      final line = [Offset.zero, const Offset(150, 0)].map(rotate).toList();
      final detected = ShapeDetector.detect(samples(line, size, noise: 1), size)!;
      expect(detected.shape, InkShape.line);
      expect(detected.points.length, 2);
      final arrow = [Offset.zero, const Offset(150, 0), const Offset(120, -20),
        const Offset(150, 0), const Offset(120, 20)].map(rotate).toList();
      final result = ShapeDetector.detect(samples(arrow, size, noise: .8), size)!;
      expect(result.shape, InkShape.arrow);
      expect(result.points.length, 5);
    });
    test('recognizes rotated rectangles with exact perpendicular edges at $angle', () {
      final corners = [Offset.zero, const Offset(120, 0), const Offset(120, 80),
        const Offset(0, 80), Offset.zero].map(rotate).toList();
      final result = ShapeDetector.detect(samples(corners, size, noise: 1), size)!;
      expect(result.shape, InkShape.rectangle);
      final a = result.points[1].inSize(size) - result.points[0].inSize(size);
      final b = result.points[2].inSize(size) - result.points[1].inSize(size);
      expect(a.dx * b.dx + a.dy * b.dy, closeTo(0, 1e-8));
    });
  }

  test('closed shapes recognize either direction and starts halfway along an edge', () {
    final rectangle = [const Offset(160, 100), const Offset(220, 100),
      const Offset(220, 180), const Offset(100, 180), const Offset(100, 100),
      const Offset(160, 100)];
    final triangle = [const Offset(100, 200), const Offset(180, 80),
      const Offset(260, 200), const Offset(100, 200)];
    for (final vertices in [rectangle, rectangle.reversed.toList()]) {
      expect(ShapeDetector.detect(samples(vertices, size), size)?.shape, InkShape.rectangle);
    }
    for (final vertices in [triangle, triangle.reversed.toList()]) {
      expect(ShapeDetector.detect(samples(vertices, size), size)?.shape, InkShape.triangle);
    }
  });

  for (final ry in [50.0, 90.0]) {
    test('recognizes a noisy ellipse/circle with radius $ry', () {
      final vertices = [for (var i = 0; i <= 80; i++)
        Offset(250 + 90 * math.cos(i * math.pi / 40),
          300 + ry * math.sin(i * math.pi / 40))];
      final result = ShapeDetector.detect(samples(vertices, size, noise: 1), size)!;
      expect(result.shape, InkShape.ellipse);
      expect(result.points.length, 97);
    });
  }

  test('rejects taps, tiny marks, open curves, scribbles and double loops', () {
    final paths = <List<Offset>>[
      [const Offset(20, 20), const Offset(20, 20)],
      [const Offset(20, 20), const Offset(25, 21)],
      [const Offset(100, 100), const Offset(150, 150), const Offset(200, 100)],
      [const Offset(100, 100), const Offset(180, 180), const Offset(120, 130),
        const Offset(190, 100), const Offset(140, 210), const Offset(230, 170)],
      [for (var i = 0; i <= 160; i++) Offset(250 + 90 * math.cos(i * math.pi / 40),
        300 + 60 * math.sin(i * math.pi / 40))],
    ];
    for (final path in paths) {
      expect(ShapeDetector.detect(samples(path, size), size), isNull);
    }
  });

  test('uses physical geometry on wide/tall pages and extended writing space', () {
    for (final page in [size, const Size(1200, 300)]) {
      final path = [const Offset(1300, 100), const Offset(1460, 100)];
      final result = ShapeDetector.detect(samples(path, page), page)!;
      expect(result.shape, InkShape.line);
      expect((result.points.last.inSize(page) - path.last).distance, lessThan(1e-8));
    }
  });
}
