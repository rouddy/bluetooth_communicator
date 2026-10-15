import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps frames until [finder] matches. Unlike pumpAndSettle this works while
/// an indeterminate progress indicator is animating, and it can wait for
/// things that happen outside the app (permission dialogs, a remote peer).
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out after $timeout waiting for $finder');
}

Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out after $timeout waiting for $finder to go away');
}

/// The subtitle under "Background 상태" on the settings page, i.e. the last
/// native `status` event.
String backgroundStatus(WidgetTester tester) {
  final tile = tester.widget<ListTile>(
    find.ancestor(
      of: find.text('Background 상태'),
      matching: find.byType(ListTile),
    ),
  );
  return (tile.subtitle! as Text).data!;
}

/// Turns on advertising and scanning in the settings page if they're off (a
/// fresh install starts with both off), then returns to the device list.
Future<void> ensureBleModesEnabled(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
  for (final title in [
    'Bluetooth peripheral advertising',
    'Bluetooth device scan 및 연결',
  ]) {
    final toggle = find.widgetWithText(SwitchListTile, title);
    if (!tester.widget<SwitchListTile>(toggle).value) {
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
  }
  await tester.pageBack();
  await tester.pumpAndSettle();
}
