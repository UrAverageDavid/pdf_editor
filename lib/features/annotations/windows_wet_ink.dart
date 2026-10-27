import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'ink.dart';
import 'pen_preset.dart';

/// Native preview with one confirmed-sample transfer at pen-up. Flutter keeps
/// collecting fallback input if the native device or channel becomes unavailable.
class WindowsWetInk extends ChangeNotifier {
  static const _channel = MethodChannel('papertrail/wet_ink');
  static int _sequence = 0;
  static WindowsWetInk? _owner;
  int? _token;
  int? _lastToken;
  int? _invalidatedToken;
  final _pending = <int>{};
  final _pendingStrokes = <int, InkStroke>{};
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
    if (call.method == 'requestFrame' &&
        (_pending.contains(call.arguments) || call.arguments == _lastToken) && !_disposed) {
      SchedulerBinding.instance.scheduleFrame();
    }
    if (call.method == 'retired') {
      _pending.remove(call.arguments);
      _pendingStrokes.remove(call.arguments);
    }
    if (call.method == 'failed' && call.arguments == _token) {
      _invalidatedToken = _token;
      _visible = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> begin({required Offset position, required Rect clip,
    required double devicePixelRatio, required double width,
    required int color, required PenStyle style, Rect? referenceRect}) async {
    if (!_supported || _disposed) return;
    // Independent compositor surfaces cannot atomically exchange translucent
    // ink: even identical pixels double its opacity during overlap. Use the
    // same Flutter renderer throughout these strokes, with prediction intact.
    if (style.type == PenType.highlighter || (color >>> 24) != 255) return;
    final token = ++_sequence;
    _token = token;
    _lastToken = token;
    final accepted = await _invoke<bool>('begin', {
      'token': token,
      'x': position.dx * devicePixelRatio,
      'y': position.dy * devicePixelRatio,
      'clip': [clip.left * devicePixelRatio, clip.top * devicePixelRatio,
        clip.right * devicePixelRatio, clip.bottom * devicePixelRatio],
      'reference': [(referenceRect ?? clip).left * devicePixelRatio,
        (referenceRect ?? clip).top * devicePixelRatio,
        (referenceRect ?? clip).width * devicePixelRatio,
        (referenceRect ?? clip).height * devicePixelRatio],
      'dpr': devicePixelRatio,
      'width': width * devicePixelRatio,
      'color': color,
      'type': style.type.name,
      'pressure': style.pressureSensitivity,
      'sharpness': style.tipSharpness,
    });
    if (_disposed || token != _token || token == _invalidatedToken) return;
    _visible = accepted == true;
    if (!_visible) _token = null;
    notifyListeners();
  }

  /// Reconcile confirmed native samples before submitting the replacement.
  /// Completion means the document is ready to save, not that DWM has presented.
  Future<void> finish({InkStroke? stroke, void Function(List<InkPoint>)? onSamples}) async {
    final token = _token;
    final wasVisible = _visible;
    _token = null;
    _visible = false;
    if (token == null) return;
    _pending.add(token);
    if (stroke != null) _pendingStrokes[token] = stroke;
    final frozen = _invoke<Object>('freeze', token);
    // An unavailable/unaccepted preview must never delay saving fallback ink.
    // Still send freeze/retire in channel order to clean up a late acceptance.
    if (!wasVisible) unawaited(frozen);
    final response = wasVisible ? await frozen.timeout(const Duration(seconds: 1),
      onTimeout: () => null) : null;
    if (response is List && response.isNotEmpty) {
      try {
        final points = response.map((p) => InkPoint.fromJson(p as List<dynamic>, extended: true)).toList();
        onSamples?.call(points);
      } on FormatException { /* Keep the complete Flutter fallback stroke. */ }
        on RangeError { /* Truncated native payload: retain fallback ink. */ }
        on TypeError { /* Older/incompatible native host: use fallback ink. */ }
    }
    if (_disposed) return;
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      if (_disposed) return;
      await _invoke<void>('retire', token);
      // The runner has armed its next-frame callback before replying.
      if (!_disposed) SchedulerBinding.instance.scheduleFrame();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Screen-space previews must not survive scrolling, zooming or undo.
  void invalidate() {
    if (!_supported || _disposed || (_token == null && _pending.isEmpty)) return;
    _invalidatedToken = _token;
    _visible = false;
    unawaited(_invoke<void>('invalidate', 0));
  }

  void removeMissingStrokes(bool Function(InkStroke) exists) {
    for (final entry in _pendingStrokes.entries.toList()) {
      if (exists(entry.value)) continue;
      unawaited(_invoke<void>('discard', entry.key));
      _pendingStrokes.remove(entry.key);
      // Keep servicing frame requests until its queued retirement is drained.
    }
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
      for (final token in {..._pending, if (_lastToken != null) _lastToken!}) {
        unawaited(_invoke<void>('discard', token));
      }
      _pending.clear();
      _pendingStrokes.clear();
    }
    super.dispose();
  }
}
