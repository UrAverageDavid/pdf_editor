import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink_filter.dart';

void main() {
  for (final hz in [60, 120, 240]) {
    test('tracks a rapid direction reversal at $hz Hz', () {
      final filter = InkFilter();
      const size = Size(600, 800);
      filter.add(const Offset(100, 200), .5, 0, size);
      for (var i = 1; i <= hz ~/ 2; i++) {
        final seconds = i / hz;
        final x = 100 + 1200 * (seconds <= .25 ? seconds : .5 - seconds);
        final point = filter.add(Offset(x, 200), .5,
          (seconds * 1000000).round(), size);
        if (seconds > .25) {
          // Opposite velocities cancelled in the old slow estimate, causing
          // over 30 px of lag just when the pen changed direction.
          expect((point.inSize(size).dx - x).abs(), lessThan(7));
        }
        expect(point.inSize(size).dx, inInclusiveRange(100, 400));
      }
    });

    test('rejects stationary jitter at $hz Hz', () {
      final filter = InkFilter();
      const size = Size(600, 800);
      filter.add(const Offset(100, 200), .5, 0, size);
      var noise = 0.0;
      for (var i = 1; i <= hz; i++) {
        final point = filter.add(Offset(100, 200 + (i.isEven ? 1 : -1)),
          .5, (i * 1000000 / hz).round(), size);
        noise += (point.inSize(size).dy - 200).abs();
      }
      // Baseline noise limits before adding the faster motion estimate.
      expect(noise / hz, lessThan(switch (hz) {
        60 => .085,
        120 => .045,
        _ => .023,
      }));
    });

    for (final speed in [300.0, 1200.0]) {
      test('responds promptly to a $speed px/s stroke start at $hz Hz', () {
        final filter = InkFilter();
        const size = Size(600, 800);
        filter.add(const Offset(100, 200), .5, 0, size);
        for (var i = 1; i <= (hz / 10).round(); i++) {
          final x = 100 + speed * i / hz;
          final point = filter.add(Offset(x, 200), .5,
            (i * 1000000 / hz).round(), size);
          // The previous filter trailed by ~8-18 px in these first 100 ms.
          expect(x - point.inSize(size).dx, lessThan(speed == 300 ? 6 : 8));
          expect(point.inSize(size).dx, inInclusiveRange(100, x));
        }
      });
    }
  }

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
