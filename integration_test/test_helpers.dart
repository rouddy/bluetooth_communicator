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
/// fresh install starts with both off), then returns to the device list. With
/// `central: false` scanning is turned off instead, so peers can only reach this
/// phone as its centrals.
Future<void> ensureBleModesEnabled(WidgetTester tester, {bool central = true}) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
  for (final (title, on) in [
    ('Bluetooth peripheral advertising', true),
    ('Bluetooth device scan 및 연결', central),
  ]) {
    final toggle = find.widgetWithText(SwitchListTile, title);
    if (tester.widget<SwitchListTile>(toggle).value != on) {
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
  }
  await tester.pageBack();
  await tester.pumpAndSettle();
}

/// Sets the name peers see (iOS's 기기 이름 setting), then returns to the device list.
Future<void> setDeviceName(WidgetTester tester, String name) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
  await tester.tap(find.text('기기 이름'));
  await tester.pumpAndSettle();
  // Not enterText: on a device the integration binding uses the real keyboard.
  tester.widget<TextField>(find.byType(TextField)).controller!.text = name;
  await tester.tap(find.text('저장'));
  await tester.pumpAndSettle();
  await tester.pageBack();
  await tester.pumpAndSettle();
}
