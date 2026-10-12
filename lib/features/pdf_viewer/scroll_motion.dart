import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/scheduler.dart';

import 'viewport_controller.dart';

/// Direct manipulation stays under the finger, then coasts with friction.
/// Wheel/precision-scroll deltas accumulate into a frame-driven eased target.
class ScrollMotion {
  ScrollMotion(this.view, TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
    view.addListener(_viewportChanged);
  }

  final ViewportController view;
  late final Ticker _ticker;
  Offset _pending = Offset.zero;
  Offset _velocity = Offset.zero;
  Duration _frame = Duration.zero;
  Duration? _sampleTime;
  bool _applying = false;

  void _viewportChanged() {
    if (!_applying) stop(); // Zoom, jumps and layout changes cancel momentum.
  }

  void stop() {
    _ticker.stop();
    _pending = Offset.zero;
    _velocity = Offset.zero;
    _sampleTime = null;
  }

  void begin(Duration time) {
    stop();
    _sampleTime = time;
  }

  void drag(Offset delta, Duration time) {
    if (view.inputActive) return;
    final previous = _sampleTime;
    if (previous != null && time > previous) {
      final dt = (time - previous).inMicroseconds / 1000000;
      final measured = delta / math.max(dt, 1 / 240);
      final blend = 1 - math.exp(-dt / .035);
      _velocity += (measured - _velocity) * blend;
    }
    _sampleTime = time;
    _pan(delta);
  }

  void end(Duration time) {
    if (_sampleTime == null || time - _sampleTime! > const Duration(milliseconds: 100)) {
      stop();
      return;
    }
    if (_velocity.distance > 6000) _velocity *= 6000 / _velocity.distance;
    if (_velocity.distance < 60) { stop(); return; }
    _startTicker();
  }

  void wheel(Offset delta, Duration time) {
    if (view.inputActive || delta == Offset.zero) return;
    _velocity = Offset.zero;
    // Reverse immediately rather than fighting the previous direction's tail.
    if (_pending.dx * delta.dx < 0) _pending = Offset(0, _pending.dy);
    if (_pending.dy * delta.dy < 0) _pending = Offset(_pending.dx, 0);
    final dt = _sampleTime == null ? .1 :
      ((time - _sampleTime!).inMicroseconds / 1000000).clamp(.008, .1);
    final speed = delta.distance / dt;
    final gain = 1 + ((speed - 500) / 5000).clamp(0.0, .5);
    _pending += delta * gain;
    _sampleTime = time;
    _startTicker();
  }

  void _startTicker() {
    if (_ticker.isActive) return;
    _frame = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    if (view.inputActive) { stop(); return; }
    final dt = ((elapsed - _frame).inMicroseconds / 1000000).clamp(0.0, .05);
    _frame = elapsed;
    if (dt == 0) return;
    final eased = _pending * (1 - math.exp(-dt / .045));
    _pending -= eased;
    final decay = math.exp(-5 * dt);
    final delta = eased + _velocity * ((1 - decay) / 5);
    _velocity *= decay;
    final before = view.offset;
    _pan(delta);
    final actual = view.offset - before;
    // A clamped axis must not keep accumulating motion at the page boundary.
    if ((actual.dx - delta.dx).abs() > .01) {
      _pending = Offset(0, _pending.dy);
      _velocity = Offset(0, _velocity.dy);
    }
    if ((actual.dy - delta.dy).abs() > .01) {
      _pending = Offset(_pending.dx, 0);
      _velocity = Offset(_velocity.dx, 0);
    }
    if (_pending.distance < .1 && _velocity.distance < 5) {
      _pan(_pending);
      stop();
    }
  }

  void _pan(Offset delta) {
    _applying = true;
    try { view.pan(delta); } finally { _applying = false; }
  }

  void dispose() {
    view.removeListener(_viewportChanged);
    _ticker.dispose();
  }
}
