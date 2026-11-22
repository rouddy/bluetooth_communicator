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

  Future<BleAppController> openSettings(WidgetTester tester) async {
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
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('on iOS the user names the phone, and the name is kept', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await openSettings(tester);
    expect(find.text('iPhone (기본값)'), findsOneWidget);

    await tester.tap(find.text('기기 이름'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  재홍의 iPhone ');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('재홍의 iPhone'), findsOneWidget);
    expect(nativeCalls.last.method, 'setDeviceName');
    expect(nativeCalls.last.arguments, {'name': '재홍의 iPhone'});

    // The next launch tells native code again.
    final restarted = BleAppController();
    nativeCalls.clear();
    await restarted.initialize();
    expect(restarted.deviceName, '재홍의 iPhone');
    expect(
      nativeCalls.map((call) => call.method),
      containsAllInOrder(['initialize', 'setDeviceName']),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android uses the system name and has no setting for it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await openSettings(tester);

    expect(find.text('기기 이름'), findsNothing);
  });
}
