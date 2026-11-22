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
  late FakePermissionHandler permissions;

  Future<void> openSettings(WidgetTester tester) async {
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
    PermissionHandlerPlatform.instance = permissions;
    SharedPreferences.setMockInitialValues({});
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
  }

  ListTile tile(WidgetTester tester, String title) =>
      tester.widget<ListTile>(find.widgetWithText(ListTile, title));

  setUp(() => permissions = FakePermissionHandler());

  testWidgets('granted permissions are shown as a status, not as something '
      'to tap', (tester) async {
    await openSettings(tester);

    expect(find.text('권한 요청'), findsNothing);
    expect(find.text('Bluetooth 권한 허용됨'), findsOneWidget);
    expect(tile(tester, '권한').onTap, isNull);
    expect(find.text('알림 설정 열기'), findsNothing);
  });

  testWidgets('turned-off notifications get their own tile, which opens system '
      'settings and goes away once they are turned on', (tester) async {
    permissions.results[Permission.notification] = PermissionStatus.denied;
    await openSettings(tester);

    expect(tile(tester, '권한').onTap, isNull);
    await tester.tap(find.text('알림 설정 열기'));
    await tester.pumpAndSettle();
    expect(permissions.openSettingsCount, 1);

    // The user turns them on and comes back.
    permissions.results[Permission.notification] = PermissionStatus.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('알림 설정 열기'), findsNothing);
  });
}
