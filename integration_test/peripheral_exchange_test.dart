// Two-device test: this phone acts as the BLE peripheral (GATT server) and a
// second phone, driven by hand or over adb, acts as the central.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/peripheral_exchange_test.dart -d <device-id>
//
// Steps the test waits for, printed as `IT_STEP ...` lines in the drive log:
//   1. `advertising`: connect to this phone from the other one (the 연결
//      button pairs first; accept the pairing dialog on both phones).
//   2. `connected`: send a message from the other phone.
//   3. `received: <text>`: this phone replies with [replyText], which should
//      show up as Received on the other phone.

import 'package:bluetooth_communicator/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

const replyText = 'reply from peripheral 안녕';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exchanges messages with a remote central', (tester) async {
    app.main();
    await pumpUntilFound(tester, find.text('기기 목록'));
    // Initialization waits on the Bluetooth permission dialog on a fresh install.
    await pumpUntilGone(
      tester,
      find.byType(LinearProgressIndicator),
      timeout: const Duration(minutes: 3),
    );

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    final advertising = find.widgetWithText(
      SwitchListTile,
      'Bluetooth peripheral advertising',
    );
    if (!tester.widget<SwitchListTile>(advertising).value) {
      await tester.tap(advertising);
      await tester.pumpAndSettle();
    }
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!backgroundStatus(tester).contains('advertising')) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Advertising never started: ${backgroundStatus(tester)}');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
    debugPrint('IT_STEP advertising');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await pumpUntilFound(
      tester,
      find.textContaining('연결됨'),
      timeout: const Duration(minutes: 10),
    );
    debugPrint('IT_STEP connected');

    await tester.tap(find.textContaining('연결됨').first);
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.textContaining('Received'),
      timeout: const Duration(minutes: 10),
    );
    final receivedTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.textContaining('Received').first,
        matching: find.byType(ListTile),
      ),
    );
    debugPrint('IT_STEP received: ${(receivedTile.title! as Text).data}');

    await tester.enterText(find.byType(TextField), replyText);
    await tester.tap(find.byIcon(Icons.send));
    await pumpUntilFound(tester, find.textContaining('Sent'));
    debugPrint('IT_STEP sent');
    // Leave time for the notification to reach the central before the app is
    // torn down.
    await tester.pump(const Duration(seconds: 10));
  });
}
