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
  late BleAppController controller;

  Future<void> setUpApp(WidgetTester tester) async {
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
    SharedPreferences.setMockInitialValues({
      'prefs_registered_devices':
          '[{"identifier":"AA:AA","name":"Peer"},{"identifier":"BB:BB","name":"Other"}]',
    });
    controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
  }

  Future<void> incoming(WidgetTester tester, String deviceId) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'message',
        'deviceId': deviceId,
        'message': 'hello',
      }),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('messages for the open chat are not counted as unread', (
    tester,
  ) async {
    await setUpApp(tester);
    await tester.tap(find.text('Peer'));
    await tester.pumpAndSettle();

    await incoming(tester, 'AA:AA');
    // Another device's message still counts.
    await incoming(tester, 'BB:BB');
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(controller.unreadCountFor('AA:AA'), 0);
    expect(controller.unreadCountFor('BB:BB'), 1);
  });

  testWidgets('a message that arrives while the app is in the background '
      'counts until the user is back in the chat', (tester) async {
    await setUpApp(tester);
    await tester.tap(find.text('Peer'));
    await tester.pumpAndSettle();

    // Lifecycle states have to change in order.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await incoming(tester, 'AA:AA');
    expect(controller.unreadCountFor('AA:AA'), 1);

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(controller.unreadCountFor('AA:AA'), 0);
  });
}
