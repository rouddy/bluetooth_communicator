import 'package:bluetooth_communicator/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openChat(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceControlPage(
          controller: BleAppController(),
          device: BleDevice(identifier: 'AA:AA', name: 'Peer'),
        ),
      ),
    );
  }

  IconButton sendButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));

  testWidgets('a message over the byte limit can\'t be sent', (tester) async {
    await openChat(tester);

    // 171 Korean characters are 513 UTF-8 bytes: one over the limit.
    await tester.enterText(find.byType(TextField), '가' * 171);
    await tester.pump();

    expect(find.text('메시지가 너무 깁니다'), findsOneWidget);
    expect(find.text('513/$maxMessageBytes bytes'), findsOneWidget);
    expect(sendButton(tester).onPressed, isNull);
  });

  testWidgets('a message at the limit can be sent, and the counter only shows '
      'near it', (tester) async {
    await openChat(tester);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.textContaining('bytes'), findsNothing);
    expect(sendButton(tester).onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), 'a' * maxMessageBytes);
    await tester.pump();
    expect(find.text('$maxMessageBytes/$maxMessageBytes bytes'), findsOneWidget);
    expect(find.text('메시지가 너무 깁니다'), findsNothing);
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('an empty message can\'t be sent', (tester) async {
    await openChat(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();

    expect(sendButton(tester).onPressed, isNull);
  });
}
