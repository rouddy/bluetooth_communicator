// Two-device test for the central role: this phone scans for, connects to,
// and chats with a peripheral running the app (e.g. an Android phone with
// advertising on).
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/central_connect_test.dart -d <device-id> \
//     --dart-define=MODE=connect --dart-define=PEER=<peripheral name>
//
// MODE=connect: find PEER under 주변 기기 by its advertised name, connect
//   (accept the pairing dialogs on both phones), send `fromCentralText`, and
//   wait for any reply from the peer (`IT_STEP sent` is printed when it's
//   time to reply).
// MODE=relaunch: run after `connect` in a fresh launch. The peer is now a
//   registered device and must reconnect on its own, without scanning or
//   tapping anything.

import 'package:bluetooth_communicator/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

const mode = String.fromEnvironment('MODE', defaultValue: 'connect');
const peer = String.fromEnvironment('PEER');
const fromCentralText = 'hello from central';

/// The device list tile (title + subtitle) for [peer], if any.
Finder peerTile() => find.ancestor(
  of: find.textContaining(peer),
  matching: find.byType(ListTile),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('central $mode', (tester) async {
    expect(peer, isNotEmpty, reason: 'pass --dart-define=PEER=<name>');
    app.main();
    await pumpUntilFound(tester, find.text('기기 목록'));
    await pumpUntilGone(
      tester,
      find.byType(LinearProgressIndicator),
      timeout: const Duration(minutes: 3),
    );

    if (mode == 'relaunch') {
      // Registered devices are reconnected by initialize(); nothing is tapped.
      debugPrint(
        'IT_STEP list: ${tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.title as Text?)?.data).toList()}',
      );
      try {
        await pumpUntilFound(
          tester,
          find.descendant(of: peerTile(), matching: find.textContaining('연결됨')),
          timeout: const Duration(minutes: 2),
        );
      } on TestFailure {
        await tester.tap(find.byIcon(Icons.settings));
        await tester.pumpAndSettle();
        final error = find.ancestor(
          of: find.text('오류'),
          matching: find.byType(ListTile),
        );
        debugPrint(
          'IT_STEP not reconnected: status=${backgroundStatus(tester)} error=${error.evaluate().isEmpty ? '-' : (tester.widget<ListTile>(error).subtitle! as Text).data}',
        );
        rethrow;
      }
      debugPrint('IT_STEP reconnected');
      return;
    }

    await ensureBleModesEnabled(tester);
    debugPrint('IT_STEP scanning');
    // Found by name: the peer must show up with its advertised name.
    await pumpUntilFound(tester, peerTile(), timeout: const Duration(minutes: 2));
    debugPrint('IT_STEP found');
    await tester.tap(peerTile().first);
    await tester.pumpAndSettle();
    if (find.widgetWithText(FilledButton, '연결').evaluate().isNotEmpty) {
      await tester.tap(find.widgetWithText(FilledButton, '연결'));
    }
    await pumpUntilFound(
      tester,
      find.widgetWithText(FilledButton, '연결됨'),
      timeout: const Duration(minutes: 3),
    );
    debugPrint('IT_STEP connected');

    // The first write may be held up by pairing (the peer requires an
    // encrypted link); it has to end up Sent rather than fail.
    await tester.enterText(find.byType(TextField), fromCentralText);
    await tester.tap(find.byIcon(Icons.send));
    await pumpUntilGone(
      tester,
      find.textContaining('전송 중'),
      timeout: const Duration(minutes: 3),
    );
    expect(find.textContaining('전송 실패'), findsNothing);
    expect(find.textContaining('Sent'), findsOneWidget);
    debugPrint('IT_STEP sent');

    await pumpUntilFound(
      tester,
      find.textContaining('Received'),
      timeout: const Duration(minutes: 5),
    );
    final reply = tester.widget<ListTile>(
      find.ancestor(
        of: find.textContaining('Received').first,
        matching: find.byType(ListTile),
      ),
    );
    debugPrint('IT_STEP received: ${(reply.title! as Text).data}');
  });
}
