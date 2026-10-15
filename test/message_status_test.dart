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
  testWidgets('the chat shows each message as sending, then sent or failed', (
    tester,
  ) async {
    final sendCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_controlChannel, (call) async {
      if (call.method == 'sendMessage') {
        sendCalls.add(call);
      }
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
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceControlPage(
          controller: controller,
          device: BleDevice(identifier: 'AA:AA', name: 'Peer'),
        ),
      ),
    );

    Future<void> send(String text) async {
      await tester.enterText(find.byType(TextField), text);
      // The send button is enabled by the next frame.
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
    }

    Future<void> nativeEvent(Map<String, dynamic> event) async {
      await messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
      await tester.pump();
    }

    await send('hello');
    await send('again');
    expect(find.textContaining('전송 중'), findsNWidgets(2));

    await nativeEvent({
      'type': 'messageSent',
      'deviceId': 'AA:AA',
      'messageId': sendCalls[0].arguments['messageId'],
    });
    await nativeEvent({
      'type': 'messageFailed',
      'deviceId': 'AA:AA',
      'messageId': sendCalls[1].arguments['messageId'],
      'error': 'Disconnected',
    });

    expect(find.textContaining('전송 중'), findsNothing);
    expect(find.textContaining('Sent ·'), findsOneWidget);
    expect(find.textContaining('전송 실패: Disconnected'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
