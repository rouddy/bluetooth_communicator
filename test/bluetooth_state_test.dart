import 'package:bluetooth_communicator/main.dart';
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
  testWidgets('the home page shows a banner while Bluetooth is off', (
    tester,
  ) async {
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

    Future<void> nativeStatus({required bool bluetoothOn}) async {
      await messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'status',
          'advertising': bluetoothOn,
          'scanning': bluetoothOn,
          'connectedCount': 0,
          'bluetoothOn': bluetoothOn,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    expect(find.text('Bluetooth가 꺼져 있습니다'), findsNothing);

    await nativeStatus(bluetoothOn: false);
    expect(find.text('Bluetooth가 꺼져 있습니다'), findsOneWidget);

    await nativeStatus(bluetoothOn: true);
    expect(find.text('Bluetooth가 꺼져 있습니다'), findsNothing);
  });
}
