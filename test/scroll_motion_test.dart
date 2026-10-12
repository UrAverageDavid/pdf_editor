import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:papertrail/features/pdf_viewer/scroll_motion.dart';
import 'package:papertrail/features/pdf_viewer/viewport_controller.dart';

void main() {
  ViewportController viewport() => ViewportController(List.filled(20, const Size(600, 800)))
    ..configure(const Size(800, 600))..jumpTo(5);

  testWidgets('wheel eases, accelerates repeated input, and stops at rest', (tester) async {
    final view = viewport();
    final motion = ScrollMotion(view, tester);
    final start = view.offset.dy;
    motion.wheel(const Offset(0, -100), Duration.zero);
    expect(view.offset.dy, start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(start - view.offset.dy, inExclusiveRange(0, 100));
    motion.wheel(const Offset(0, -100), const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(start - view.offset.dy, greaterThan(400));
    expect(start - view.offset.dy, lessThanOrEqualTo(600));
    final settled = view.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(view.offset, settled);
    motion.dispose();
    view.dispose();
  });

  testWidgets('touch follows the finger, coasts, and a new contact stops it', (tester) async {
    final view = viewport();
    final motion = ScrollMotion(view, tester);
    final start = view.offset;
    motion.begin(Duration.zero);
    motion.drag(const Offset(0, -50), const Duration(milliseconds: 16));
    expect(view.offset, start + const Offset(0, -50));
    motion.end(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(view.offset.dy, lessThan(start.dy - 50));
    motion.begin(const Duration(milliseconds: 60));
    final stopped = view.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(view.offset, stopped);
    motion.dispose();
    view.dispose();
  });

  testWidgets('pause before lift prevents flinging; zoom and pen cancel momentum', (tester) async {
    final view = viewport();
    final motion = ScrollMotion(view, tester);
    motion.begin(Duration.zero);
    motion.drag(const Offset(0, -100), const Duration(milliseconds: 16));
    motion.end(const Duration(milliseconds: 200));
    final stopped = view.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(view.offset, stopped);
    motion.wheel(const Offset(0, -200), const Duration(seconds: 1));
    view.setZoom(1.2);
    final zoomed = view.offset;
    await tester.pumpAndSettle();
    expect(view.offset, zoomed);
    motion.wheel(const Offset(0, -200), const Duration(seconds: 2));
    view.inputActive = true;
    await tester.pumpAndSettle();
    expect(view.offset, zoomed);
    view.inputActive = false;
    motion.dispose();
    view.dispose();
  });

  testWidgets('bounds settle and reversal discards the previous tail', (tester) async {
    final view = viewport()..jumpTo(0);
    final motion = ScrollMotion(view, tester);
    motion.wheel(const Offset(0, 500), Duration.zero);
    await tester.pumpAndSettle();
    expect(view.offset.dy, 0);
    motion.wheel(const Offset(0, -200), const Duration(milliseconds: 100));
    motion.wheel(const Offset(0, 20), const Duration(milliseconds: 116));
    await tester.pumpAndSettle();
    expect(view.offset.dy, 0);
    motion.dispose();
    view.dispose();
  });
}
