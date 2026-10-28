import 'package:bluetooth_communicator/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// A phone in landscape (Jump3: 915x412 dp), optionally with the keyboard
  /// open.
  Future<void> openChat(WidgetTester tester, {required double keyboard}) async {
    tester.view
      ..devicePixelRatio = 2.625
      ..physicalSize = const Size(915, 412) * 2.625
      ..padding = const FakeViewPadding(top: 24 * 2.625)
      ..viewInsets = FakeViewPadding(bottom: keyboard * 2.625);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceControlPage(
          controller: BleAppController(),
          device: BleDevice(identifier: 'AA:AA', name: 'Peer'),
        ),
      ),
    );
  }

  Finder connectButton() => find.widgetWithText(FilledButton, '연결');

  testWidgets('landscape with the keyboard open keeps the input above the '
      'keyboard, and the link state in the app bar', (tester) async {
    await openChat(tester, keyboard: 223);

    expect(tester.takeException(), isNull);
    expect(find.text('AA:AA'), findsNothing);
    expect(find.descendant(of: find.byType(AppBar), matching: connectButton()), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('연결 안 됨')), findsOneWidget);
    final input = tester.getRect(find.byType(TextField));
    expect(input.bottom, lessThanOrEqualTo(412 - 223));
    expect(tester.getRect(find.byIcon(Icons.send)).bottom, lessThanOrEqualTo(412 - 223));

    // Near the byte limit, the counter below the field fits too.
    await tester.enterText(find.byType(TextField), 'a' * maxMessageBytes);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape without the keyboard keeps the link header', (
    tester,
  ) async {
    await openChat(tester, keyboard: 0);

    expect(tester.takeException(), isNull);
    expect(find.text('AA:AA'), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: connectButton()), findsNothing);
    expect(connectButton(), findsOneWidget);
  });

  testWidgets('the field keeps focus when the keyboard opening changes the '
      'layout', (tester) async {
    await openChat(tester, keyboard: 0);
    await tester.tap(find.byType(TextField));
    await tester.pump();

    tester.view.viewInsets = const FakeViewPadding(bottom: 223 * 2.625);
    await tester.pump();

    expect(find.text('AA:AA'), findsNothing);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
  });
}
