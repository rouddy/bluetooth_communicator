// On-device smoke test for the native BLE channels.
//
// Run on a real phone (BLE and the native channels don't exist on the host):
//   flutter test integration_test/app_test.dart -d <device-id>
// Wirelessly connected iOS devices need `flutter drive` instead (see
// test_driver/integration_test.dart).
//
// On the first run the OS shows the Bluetooth permission dialog, which this
// test can't tap. Allow it on the phone within the timeout.

import 'package:bluetooth_communicator/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and the native BLE channels respond', (tester) async {
    // main() is `void ... async`: it runs initialize() and runApp() in the background.
    app.main();
    await pumpUntilFound(tester, find.text('기기 목록'));

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    // Give the event channel a moment to deliver the first native status.
    await tester.pump(const Duration(seconds: 2));

    expect(find.textContaining('channel unavailable'), findsNothing);
    // Both native sides send a status event once Dart listens and initializes,
    // so anything but the initial 'unknown' proves the event channel works.
    expect(backgroundStatus(tester), isNot('unknown'));
  });
}
