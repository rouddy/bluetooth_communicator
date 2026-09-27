// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_communicator/main.dart';

void main() {
  testWidgets('App shows BLE tabs', (WidgetTester tester) async {
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pump();

    expect(find.text('Bluetooth Communicator'), findsAtLeastNWidgets(1));
    expect(find.text('Advertising'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
  });
}
