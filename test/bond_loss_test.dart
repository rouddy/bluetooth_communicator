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
  Future<BleAppController> startApp(WidgetTester tester) async {
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
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    return controller;
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

  testWidgets('a lost pairing is explained, remembered, and cleared by a new '
      'connection', (tester) async {
    SharedPreferences.setMockInitialValues({
      'prefs_registered_devices': '[{"identifier":"AA:AA","name":"Peer"}]',
    });
    await startApp(tester);
    await nativeEvent(tester, 'connected');

    await nativeEvent(tester, 'bondLost');

    expect(find.widgetWithText(SnackBar, 'Peer와(과)의 페어링이 해제되었습니다. 주변 기기 목록에서 다시 연결해 주세요.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('페어링 해제됨 · AA:AA'), findsOneWidget);

    // Still shown after a restart.
    final restarted = BleAppController();
    await tester.pumpWidget(MyApp(controller: restarted));
    await restarted.initialize();
    await tester.pumpAndSettle();
    expect(restarted.linkStateFor('AA:AA'), LinkState.pairingLost);

    await nativeEvent(tester, 'connected');
    expect(restarted.linkStateFor('AA:AA'), LinkState.connected);
    await nativeEvent(tester, 'disconnected');
    expect(restarted.linkLabel('AA:AA'), '연결 안 됨');
  });
}
