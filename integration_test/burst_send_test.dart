// Two-device test: one phone sends a burst of messages back to back, the other
// counts what arrives. Android allows one outstanding GATT operation per link,
// so a burst exposes writes/notifications that get dropped.
//
// Start the receiver first, then the sender:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/burst_send_test.dart -d <receiver> \
//     --dart-define=ROLE=receiver --dart-define=PEER=<sender name>
//   flutter drive ... -d <sender> \
//     --dart-define=ROLE=sender --dart-define=PEER=<receiver name>
// PEER is a substring of the other phone's name in the device list. The two
// phones must already be paired (connect them once through the app).

import 'package:bluetooth_communicator/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

const role = String.fromEnvironment('ROLE', defaultValue: 'sender');
const peer = String.fromEnvironment('PEER');
const count = int.fromEnvironment('COUNT', defaultValue: 5);

String burstText(int i) => 'burst $i/$count';

/// Text of the subtitles of all message tiles on the chat page, oldest first
/// (the list is reversed, so the widgets come newest first).
List<String> messageLines(WidgetTester tester) {
  final tiles = tester
      .widgetList<ListTile>(
        find.ancestor(
          of: find.textContaining(RegExp(r'burst \d+/')),
          matching: find.byType(ListTile),
        ),
      )
      .map((tile) {
        final title = (tile.title! as Text).data;
        final subtitle = (tile.subtitle! as Text).data!.split(' · ').first;
        return '$title [$subtitle]';
      })
      .toList();
  return tiles.reversed.toList();
}

Future<void> openPeerChat(WidgetTester tester) async {
  app.main();
  await pumpUntilFound(tester, find.text('기기 목록'));
  await pumpUntilGone(tester, find.byType(LinearProgressIndicator));
  final peerTile = find.textContaining(peer);
  await pumpUntilFound(tester, peerTile, timeout: const Duration(minutes: 5));
  await tester.tap(peerTile.first);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('burst send ($role)', (tester) async {
    expect(peer, isNotEmpty, reason: 'pass --dart-define=PEER=<name>');
    await openPeerChat(tester);

    if (role == 'receiver') {
      debugPrint('IT_STEP ready');
      final received = find.textContaining(RegExp(r'burst \d+/'));
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (received.evaluate().length < count &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // Late stragglers.
      await tester.pump(const Duration(seconds: 5));
      final lines = messageLines(tester);
      debugPrint('IT_RESULT received ${lines.length}/$count: $lines');
      expect(lines, [for (var i = 1; i <= count; i++) '${burstText(i)} [Received]']);
      return;
    }

    if (find.widgetWithText(FilledButton, '연결').evaluate().isNotEmpty) {
      await tester.tap(find.widgetWithText(FilledButton, '연결'));
    }
    await pumpUntilFound(
      tester,
      find.widgetWithText(FilledButton, '연결됨'),
      timeout: const Duration(minutes: 2),
    );
    // Let service discovery and the notification subscription finish.
    await tester.pump(const Duration(seconds: 3));
    debugPrint('IT_STEP sending');
    for (var i = 1; i <= count; i++) {
      await tester.enterText(find.byType(TextField), burstText(i));
      await tester.tap(find.byIcon(Icons.send));
      // One frame only: the sends must overlap on the native side.
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 15));
    // Close the keyboard: the list is lazy, and with the keyboard up the oldest
    // messages scroll out of view and aren't built.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    debugPrint('IT_RESULT sender sees: ${messageLines(tester)}');
  });
}
