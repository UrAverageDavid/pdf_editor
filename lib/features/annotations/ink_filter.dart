import 'dart:math' as math;
import 'dart:ui';

import 'ink.dart';

/// A speed-adaptive low-pass (One Euro) filter, in displayed logical pixels.
/// Slow handwriting is stabilized; fast strokes increase the cutoff to avoid
/// trailing the nib. Only new samples are filtered, so previous ink never moves.
class InkFilter {
  Offset? _raw;
  Offset _position = Offset.zero;
  Offset _velocity = Offset.zero;
  double _pressure = .75;
  int? _time;
  Size _reference = Size.zero;

  /// Finish at the last observed nib position, without using pen-up pressure.
  InkPoint? get endpoint => _raw == null ? null : InkPoint(
    _raw!.dx / _reference.width, _raw!.dy / _reference.height, _pressure, _time!);

  void reset() {
    _raw = null;
    _time = null;
    _velocity = Offset.zero;
  }

  InkPoint add(Offset position, double pressure, int timeMicros, Size reference) {
    _reference = reference;
    if (_raw == null) {
      _position = position;
      _pressure = pressure;
    } else {
      // Drivers can report duplicate timestamps or resume after a long pause.
      final dt = ((timeMicros - _time!) / 1000000).clamp(1 / 240, .05);
      final velocity = (position - _raw!) / dt;
      _velocity += (velocity - _velocity) * _alpha(1, dt);
      final cutoff = 1.5 + .04 * _velocity.distance;
      _position += (position - _position) * _alpha(cutoff, dt);
      _pressure += (pressure - _pressure) * _alpha(8, dt);
    }
    _raw = position;
    _time = timeMicros;
    return InkPoint(_position.dx / reference.width,
      _position.dy / reference.height, _pressure, timeMicros);
  }

  double _alpha(double cutoff, double dt) =>
    1 / (1 + 1 / (2 * math.pi * cutoff * dt));
}
