import 'package:bluetooth_communicator/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_permission_handler.dart';

const _controlChannel = MethodChannel(
  'com.rouddy.bluetooth_communicator/bluetooth_control',
);
const _eventsChannel = EventChannel(
  'com.rouddy.bluetooth_communicator/bluetooth_events',
);

void main() {
  Future<void> openDevicePage(WidgetTester tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_controlChannel, (call) async => null);
    messenger.setMockStreamHandler(
      _eventsChannel,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(_controlChannel, null);
      messenger.setMockStreamHandler(_eventsChannel, null);
    });
    PermissionHandlerPlatform.instance = FakePermissionHandler();
    SharedPreferences.setMockInitialValues({});
    final controller = BleAppController();
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceControlPage(
          controller: controller,
          device: BleDevice(identifier: 'AA:AA', name: 'Peer'),
        ),
      ),
    );
  }

  Future<void> nativeEvent(WidgetTester tester, String type) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': type,
        'deviceId': 'AA:AA',
      }),
      (_) {},
    );
    await tester.pump();
  }

  Finder progress() => find.descendant(
    of: find.byType(FilledButton),
    matching: find.byType(CircularProgressIndicator),
  );

  testWidgets('connect shows connecting, then pairing, then connected', (
    tester,
  ) async {
    await openDevicePage(tester);

    await tester.tap(find.widgetWithText(FilledButton, '연결'));
    await tester.pump();
    expect(find.text('연결 중…'), findsOneWidget);
    expect(progress(), findsOneWidget);

    await nativeEvent(tester, 'bonding');
    expect(find.text('페어링 중…'), findsOneWidget);

    await nativeEvent(tester, 'connected');
    expect(find.text('연결됨'), findsNWidgets(2));
    expect(progress(), findsNothing);
  });

  testWidgets('a failed pairing goes back to the connect button', (tester) async {
    await openDevicePage(tester);
    await tester.tap(find.widgetWithText(FilledButton, '연결'));
    await tester.pump();
    await nativeEvent(tester, 'bonding');

    await nativeEvent(tester, 'disconnected');

    expect(find.text('연결 안 됨'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '연결'), findsOneWidget);
  });

  testWidgets('connecting gives up after the timeout', (tester) async {
    await openDevicePage(tester);
    await tester.tap(find.widgetWithText(FilledButton, '연결'));
    await tester.pump();

    await tester.pump(BleAppController.connectingTimeout + const Duration(seconds: 1));

    expect(find.text('연결 안 됨'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '연결'), findsOneWidget);
  });
}
