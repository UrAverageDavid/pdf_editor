import 'dart:math' as math;
import 'dart:ui';

import 'ink.dart';

/// A speed-adaptive low-pass filter based on One Euro, in logical screen pixels.
/// Slow handwriting is stabilized; fast strokes increase the cutoff to avoid
/// trailing the nib. A spatial limit prevents tight loops from shrinking when
/// direction changes lower the speed estimate. Only new samples are filtered,
/// so previous ink never moves.
class InkFilter {
  static const double _maxPositionError = 1; // Logical screen pixels.

  Offset? _raw;
  Offset _position = Offset.zero;
  Offset _velocity = Offset.zero;
  Offset _fastVelocity = Offset.zero;
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
    _fastVelocity = Offset.zero;
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
      // The 1 Hz estimate rejects jitter but reacts slowly at starts/turns.
      // A faster estimate can open the filter sooner, after subtracting the
      // velocity that +/-1 logical pixel of stationary noise can generate.
      // Keep the original estimate as the floor for sustained slow writing.
      final fastAlpha = _alpha(10, dt);
      _fastVelocity += (velocity - _fastVelocity) * fastAlpha;
      final noiseSpeed = 2 * fastAlpha / dt;
      final speed = math.max(_velocity.distance,
        _fastVelocity.distance - noiseSpeed);
      final cutoff = 1.5 + .04 * speed;
      _position += (position - _position) * _alpha(cutoff, dt);
      // Temporal smoothing can cut across a fast loop before reaching its
      // extrema. Keep its displacement within the stationary noise allowance,
      // regardless of speed or direction, and retain that correction as state.
      final error = _position - position;
      final distance = error.distance;
      if (distance > _maxPositionError) {
        _position = position + error * (_maxPositionError / distance);
      }
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
