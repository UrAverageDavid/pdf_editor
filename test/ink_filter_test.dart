import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink_filter.dart';

void main() {
  test('stabilizes position and pressure noise without moving the first point', () {
    final filter = InkFilter();
    const size = Size(600, 800);
    final first = filter.add(const Offset(100, 200), .5, 0, size);
    expect(first.inSize(size), const Offset(100, 200));
    var noise = 0.0;
    var pressureNoise = 0.0;
    for (var i = 1; i <= 120; i++) {
      final sign = i.isEven ? 1 : -1;
      final point = filter.add(Offset(100, 200 + sign.toDouble()),
        .5 + sign * .1, i * 8333, size);
      noise += (point.inSize(size).dy - 200).abs();
      pressureNoise += (point.pressure - .5).abs();
      expect(point.timeMicros, i * 8333);
    }
    expect(noise / 120, lessThan(.2));
    expect(pressureNoise / 120, lessThan(.03));
  });

  test('fast strokes catch up, stay bounded, and reset between strokes', () {
    final filter = InkFilter();
    const size = Size(600, 800);
    for (var i = 0; i <= 30; i++) {
      final point = filter.add(Offset(100 + i * 10.0, 200), .8, i * 8333, size);
      expect(point.inSize(size).dx, inInclusiveRange(100, 100 + i * 10));
      if (i == 30) expect(point.inSize(size).dx, greaterThan(390));
    }
    expect(filter.endpoint!.inSize(size), const Offset(400, 200));
    // Duplicate and decreasing timestamps cannot generate NaN/overshoot.
    for (final time in [249990, 0, 1000000]) {
      final point = filter.add(const Offset(450, 200), .4, time, size);
      expect(point.x, inInclusiveRange(0, 1));
      expect(point.pressure, inInclusiveRange(.4, .8));
    }
    filter.reset();
    expect(filter.endpoint, isNull);
    final next = filter.add(const Offset(700, 300), .3, 0, size);
    expect(next.inSize(size), const Offset(700, 300)); // Expanded notes allow x > 1.
    expect(next.pressure, .3);
  });
}
