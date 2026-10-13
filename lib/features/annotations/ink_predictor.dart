import 'dart:math' as math;
import 'dart:ui';

import 'ink.dart';

/// A disposable preview of where the nib may be when a frame reaches the display.
/// Uses raw screen-space motion, independently of filtering and stored samples.
/// Inspired by Windows Ink's adaptive 15 ms prediction horizon; this is our own
/// conservative velocity extrapolator, not Microsoft's proprietary model.
class InkPredictor {
  static const horizonSeconds = .015;
  static const maxLeadPixels = 24.0;
  static const expiry = Duration(milliseconds: 32);
  Offset? _position;
  Offset? _velocity;
  int? _time;

  void reset() {
    _position = null;
    _velocity = null;
    _time = null;
  }

  List<InkPoint> add(Offset position, int timeMicros, Size reference, double pressure) {
    final previous = _position;
    final previousTime = _time;
    final previousVelocity = _velocity;
    _position = position;
    _time = timeMicros;
    _velocity = null;
    if (previous == null || previousTime == null) return const [];
    final dt = (timeMicros - previousTime) / 1000000;
    // Duplicate/out-of-order timestamps and resumed input cannot establish speed.
    if (dt < .001 || dt > .05) return const [];
    final delta = position - previous;
    final velocity = delta / dt;
    _velocity = velocity;
    final speed = velocity.distance;
    if (previousVelocity == null || speed < 25 || delta.distance < .35) return const [];
    final previousSpeed = previousVelocity.distance;
    if (previousSpeed < 25) return const [];
    final alignment = ((velocity.dx * previousVelocity.dx + velocity.dy * previousVelocity.dy) /
      (speed * previousSpeed)).clamp(0.0, 1.0);
    // Retreat at corners, reversals, deceleration, and unstable acceleration.
    final slowing = math.min(1.0, speed / previousSpeed);
    final change = (velocity - previousVelocity).distance * horizonSeconds / (dt * math.max(speed, 100));
    final horizon = horizonSeconds * alignment * alignment * slowing * slowing / (1 + 2 * change);
    final lead = math.min(maxLeadPixels, speed * horizon);
    if (lead < .35) return const [];
    final duration = lead / speed;
    return [for (final fraction in [.5, 1.0])
      InkPoint((position.dx + velocity.dx * duration * fraction) / reference.width,
        (position.dy + velocity.dy * duration * fraction) / reference.height,
        pressure, timeMicros + (duration * fraction * 1000000).round()),
    ];
  }
}
