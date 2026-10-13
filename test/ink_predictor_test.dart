import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/ink_predictor.dart';

void main() {
  test('steady motion projects 15 ms at different sampling rates and zooms', () {
    for (final hz in [60, 120, 240]) {
      for (final zoom in [.5, 1.0, 2.0]) {
        final predictor = InkPredictor();
        final reference = Size(600 * zoom, 800 * zoom);
        final step = (1000000 / hz).round();
        for (var i = 0; i < 10; i++) {
          final t = step * i;
          final position = Offset(20 + 500 * t / 1000000, 50);
          final preview = predictor.add(position, t, reference, .6);
          if (i < 2) { expect(preview, isEmpty); continue; }
          expect(preview.last.inSize(reference).dx - position.dx, closeTo(7.5, .001));
          expect(preview.last.inSize(reference).dy, closeTo(position.dy, .001));
          expect(preview.last.timeMicros - t, 15000);
          expect(preview.last.pressure, .6);
        }
      }
    }
  });

  InkPredictor moving() => InkPredictor()
    ..add(const Offset(0, 50), 0, const Size(600, 800), .5)
    ..add(const Offset(5, 50), 10000, const Size(600, 800), .5)
    ..add(const Offset(10, 50), 20000, const Size(600, 800), .5);

  test('corners, reversals and stops remove the speculative tail', () {
    for (final position in [const Offset(10, 55), const Offset(5, 50), const Offset(10, 50)]) {
      expect(moving().add(position, 30000, const Size(600, 800), .5), isEmpty);
    }
    final slow = moving().add(const Offset(11, 50), 30000, const Size(600, 800), .5);
    expect(slow, isEmpty);
    final accelerating = moving().add(const Offset(20, 50), 30000, const Size(600, 800), .5);
    expect(accelerating.last.timeMicros - 30000, lessThan(15000));
  });

  test('stationary jitter never produces a long prediction', () {
    final predictor = InkPredictor();
    for (var i = 0; i < 100; i++) {
      expect(predictor.add(Offset(i.isEven ? 49.5 : 50.5, 50), i * 8333,
        const Size(600, 800), .5), isEmpty);
    }
  });

  test('invalid timing, pauses and reset require fresh velocity samples', () {
    for (final t in [20000, 19000, 21000 - 1, 100000]) {
      final predictor = moving();
      expect(predictor.add(const Offset(15, 50), t, const Size(600, 800), .5), isEmpty);
      expect(predictor.add(const Offset(20, 50), t + 10000, const Size(600, 800), .5), isEmpty);
    }
    final predictor = moving()..reset();
    expect(predictor.add(const Offset(100, 100), 30000, const Size(600, 800), .5), isEmpty);
  });

  test('fast movement has a screen-space distance cap', () {
    final predictor = InkPredictor();
    predictor.add(Offset.zero, 0, const Size(600, 800), .5);
    predictor.add(const Offset(100, 0), 10000, const Size(600, 800), .5);
    final preview = predictor.add(const Offset(200, 0), 20000, const Size(600, 800), .5);
    expect(preview.last.inSize(const Size(600, 800)).dx, closeTo(224, .001));
  });
}
