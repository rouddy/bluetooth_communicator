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
  testWidgets('a registered device can be deleted from its page', (
    tester,
  ) async {
    final nativeCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_controlChannel, (call) async {
      nativeCalls.add(call);
      return null;
    });
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
    await messenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'peers',
        'peers': [
          {
            'deviceId': 'AA:BB:CC:DD:EE:FF',
            'name': 'Old phone',
            'peerId': '00112233-4455-6677-8899-aabbccddeeff',
            'state': 'paired',
            'connected': false,
          },
        ],
      }),
      (_) {},
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old phone'));
    await tester.pumpAndSettle();
    expect(find.text('00112233-4455-6677-8899-aabbccddeeff'), findsOneWidget);
    await tester.tap(find.byTooltip('기기 삭제'));
    await tester.pumpAndSettle();
    expect(find.text('기기 삭제'), findsOneWidget);
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();

    // Back on the device list, without the deleted device.
    expect(find.text('기기 목록'), findsOneWidget);
    expect(find.text('Old phone'), findsNothing);
    expect(find.text('연결 기록이 있는 기기가 없습니다.'), findsOneWidget);
    expect(nativeCalls.last.method, 'removeDevice');
    expect(nativeCalls.last.arguments, {'deviceId': 'AA:BB:CC:DD:EE:FF'});
  });

  testWidgets('a nearby device that was never registered has no delete '
      'button', (tester) async {
    final controller = BleAppController();
    final device = BleDevice(identifier: '11:22', name: 'Stranger');
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceControlPage(controller: controller, device: device),
      ),
    );

    expect(find.byTooltip('기기 삭제'), findsNothing);
  });
}
