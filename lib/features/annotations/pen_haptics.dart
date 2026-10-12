import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows resolves the actual native pen ID; Flutter pointer IDs are unrelated.
class PenHaptics {
  static const _channel = MethodChannel('papertrail/pen_haptics');

  Future<void> start() => _send('start');
  Future<void> stop() => _send('stop');

  Future<void> _send(String method) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Older runners and unsupported platforms keep normal pen input.
    } on PlatformException {
      // Haptics are optional; a disconnected pen must not interrupt a stroke.
    }
  }
}
