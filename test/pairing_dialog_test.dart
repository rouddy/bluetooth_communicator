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
  late List<MethodCall> nativeCalls;

  Future<void> startApp(WidgetTester tester) async {
    nativeCalls = [];
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
    await tester.pumpAndSettle();
  }

  Future<void> nativeEvent(WidgetTester tester, Map<String, dynamic> event) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    // Not pumpAndSettle: the dialog's waiting spinner never settles.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Map<String, dynamic> request({bool repair = false}) => {
    'type': 'pairingRequest',
    'deviceId': 'AA:AA',
    'peerId': 'pa',
    'name': '재홍의 S23',
    'code': '042517',
    'repair': repair,
  };

  testWidgets('a pairing request shows the code until both users approved', (
    tester,
  ) async {
    await startApp(tester);

    await nativeEvent(tester, request());

    expect(find.text('연결 요청'), findsOneWidget);
    expect(find.text('재홍의 S23와(과) 연결합니다.'), findsOneWidget);
    expect(find.text('042517'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '승인'));
    await tester.pump();
    expect(nativeCalls.last.method, 'respondPairing');
    expect(nativeCalls.last.arguments, {'deviceId': 'AA:AA', 'accept': true});
    expect(find.text('상대 기기의 승인을 기다리는 중…'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '승인'), findsNothing);

    // Replayed when the UI attaches again: no second dialog.
    await nativeEvent(tester, request());
    expect(find.byType(PairingDialog), findsOneWidget);

    await nativeEvent(tester, {
      'type': 'pairingResult',
      'deviceId': 'AA:AA',
      'peerId': 'pa',
      'result': 'paired',
    });
    expect(find.byType(PairingDialog), findsNothing);
  });

  testWidgets('declining closes the dialog', (tester) async {
    await startApp(tester);
    await nativeEvent(tester, request(repair: true));
    expect(find.text('다시 연결 요청'), findsOneWidget);

    await tester.tap(find.text('거절'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(nativeCalls.last.arguments, {'deviceId': 'AA:AA', 'accept': false});
    expect(find.byType(PairingDialog), findsNothing);
  });

  testWidgets('the peer declining closes the dialog and says so', (tester) async {
    await startApp(tester);
    await nativeEvent(tester, request());

    await nativeEvent(tester, {
      'type': 'pairingResult',
      'deviceId': 'AA:AA',
      'peerId': 'pa',
      'result': 'rejected',
    });

    expect(find.byType(PairingDialog), findsNothing);
    expect(find.text('재홍의 S23와(과)의 연결이 거절되었습니다.'), findsOneWidget);
  });
}
