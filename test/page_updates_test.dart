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
  // MaterialApp no longer rebuilds on controller changes; pages pushed on top
  // of the home page have to update on their own.
  testWidgets('pushed pages follow controller changes', (tester) async {
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
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();

    Future<void> nativeEvent(Map<String, dynamic> event) async {
      await messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await nativeEvent({
      'type': 'status',
      'advertising': true,
      'scanning': true,
      'connectedCount': 0,
      'bluetoothOn': true,
    });
    expect(find.text('advertising scanning'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.notifications_none));
    await tester.pumpAndSettle();
    await nativeEvent({'type': 'connected', 'deviceId': 'AA:AA'});
    await nativeEvent({'type': 'message', 'deviceId': 'AA:AA', 'message': 'hi'});
    expect(find.text('hi'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('AA:AA'), findsOneWidget);
  });
}
