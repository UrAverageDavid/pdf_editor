import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'pen_preset.dart';

/// Optional native preview. Flutter remains the authority for document samples.
/// No pointer-move messages cross this channel: Windows reads them directly.
class WindowsWetInk extends ChangeNotifier {
  static const _channel = MethodChannel('papertrail/wet_ink');
  static int _sequence = 0;
  static WindowsWetInk? _owner;
  int? _token;
  int? _lastToken;
  bool _disposed = false;
  bool _visible = false;
  bool get visible => _visible;
  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  WindowsWetInk() {
    if (_supported) {
      _owner = this;
      _channel.setMethodCallHandler(_nativeCall);
      unawaited(_invoke<bool>('initialize', 0));
    }
  }

  Future<void> _nativeCall(MethodCall call) async {
    if (call.method == 'requestFrame' && call.arguments == _lastToken && !_disposed) {
      SchedulerBinding.instance.scheduleFrame();
    }
    if (call.method == 'failed' && call.arguments == _token) {
      _visible = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> begin({required Offset position, required Rect clip,
    required double devicePixelRatio, required double width,
    required int color, required PenStyle style}) async {
    if (!_supported || _disposed) return;
    final token = ++_sequence;
    _token = token;
    _lastToken = token;
    final accepted = await _invoke<bool>('begin', {
      'token': token,
      'x': position.dx * devicePixelRatio,
      'y': position.dy * devicePixelRatio,
      'clip': [clip.left * devicePixelRatio, clip.top * devicePixelRatio,
        clip.right * devicePixelRatio, clip.bottom * devicePixelRatio],
      'dpr': devicePixelRatio,
      'width': width * devicePixelRatio,
      'color': color,
      'type': style.type.name,
      'pressure': style.pressureSensitivity,
      'sharpness': style.tipSharpness,
    });
    if (_disposed || token != _token) return;
    _visible = accepted == true;
    notifyListeners();
  }

  /// Freeze native input immediately. Retire the preview only after submitting
  /// the committed Flutter frame, then ask the runner to observe a raster frame.
  void finish() {
    final token = _token;
    _token = null;
    _visible = false;
    if (token == null) return;
    unawaited(_invoke<void>('freeze', token));
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      if (_disposed) return;
      await _invoke<void>('retire', token);
      // The runner has armed its next-frame callback before replying.
      if (!_disposed) SchedulerBinding.instance.scheduleFrame();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<T?> _invoke<T>(String method, Object arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _token = null;
    if (_supported) {
      if (identical(_owner, this)) {
        _owner = null;
        _channel.setMethodCallHandler(null);
      }
      if (_lastToken != null) unawaited(_invoke<void>('discard', _lastToken!));
    }
    super.dispose();
  }
}
