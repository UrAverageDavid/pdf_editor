import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/annotations/pen_preset.dart';
import 'package:papertrail/features/annotations/windows_wet_ink.dart';

const channel = MethodChannel('papertrail/wet_ink');

Future<void> begin(WindowsWetInk ink) => ink.begin(
  position: const Offset(15, 25), clip: const Rect.fromLTRB(10, 20, 300, 400),
  devicePixelRatio: 2, width: 3, color: 0xff123456,
  style: const PenStyle(type: PenType.brush));

void main() {
  testWidgets('native preview is never requested on other platforms', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final ink = WindowsWetInk();
    await begin(ink);
    ink.finish();
    ink.dispose();
    await tester.pump();
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.linux}));

  testWidgets('preview waits for acceptance and uses physical window coordinates', (tester) async {
    final accepted = Completer<bool>();
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'begin' ? accepted.future : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final ink = WindowsWetInk();
    final pending = begin(ink);
    expect(ink.visible, isFalse);
    accepted.complete(true);
    await pending;
    expect(ink.visible, isTrue);
    final args = calls.singleWhere((c) => c.method == 'begin').arguments as Map;
    expect(args['x'], 30);
    expect(args['y'], 50);
    expect(args['clip'], [20, 40, 600, 800]);
    expect(args['width'], 6);
    expect(args['type'], 'brush');
    ink.finish();
    await tester.idle();
    expect(ink.visible, isFalse);
    expect(calls.where((c) => c.method == 'freeze').single.arguments, args['token']);
    expect(calls.where((c) => c.method == 'retire'), isEmpty);
    await tester.pump();
    expect(calls.where((c) => c.method == 'retire').single.arguments, args['token']);
    ink.dispose();
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  for (final failure in ['unavailable', 'missing plugin', 'device error']) {
    testWidgets('$failure keeps Flutter rendering active', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (failure == 'missing plugin') throw MissingPluginException();
        if (failure == 'device error') throw PlatformException(code: 'device-lost');
        return false;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final ink = WindowsWetInk();
      await begin(ink);
      expect(ink.visible, isFalse);
      ink.dispose();
      await tester.pump();
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }

  testWidgets('late acceptance cannot revive a finished or disposed stroke', (tester) async {
    final replies = <Completer<bool>>[];
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method != 'begin') return null;
      final reply = Completer<bool>();
      replies.add(reply);
      return reply.future;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final ink = WindowsWetInk();
    final first = begin(ink);
    await tester.idle();
    ink.finish();
    final second = begin(ink);
    await tester.idle();
    replies[1].complete(true);
    await second;
    replies[0].complete(false);
    await first;
    expect(ink.visible, isTrue);
    await tester.pump();
    final starts = calls.where((c) => c.method == 'begin').toList();
    expect(calls.singleWhere((c) => c.method == 'retire').arguments, (starts.first.arguments as Map)['token']);
    ink.finish();
    final third = begin(ink);
    await tester.idle();
    ink.dispose();
    replies[2].complete(true);
    await third;
    expect(ink.visible, isFalse);
    await tester.pump();
    expect(calls.where((c) => c.method == 'discard'), hasLength(1));
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('device loss restores Flutter ink and stale failures are ignored', (tester) async {
    int? token;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') token = (call.arguments as Map)['token'] as int;
      return call.method == 'begin';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final ink = WindowsWetInk();
    await begin(ink);
    final oldToken = token!;
    ink.finish();
    await begin(ink);
    Future<void> nativeCall(String method, int id) {
      final reply = Completer<void>();
      tester.binding.channelBuffers.push(channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, id)),
        (_) => reply.complete());
      return reply.future;
    }
    await tester.pumpAndSettle();
    await nativeCall('requestFrame', oldToken);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await nativeCall('requestFrame', token!);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpAndSettle();
    await nativeCall('failed', oldToken);
    expect(ink.visible, isTrue);
    await nativeCall('failed', token!);
    expect(ink.visible, isFalse);
    ink.dispose();
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));
}
