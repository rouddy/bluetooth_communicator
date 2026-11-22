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
    PermissionHandlerPlatform.instance = permissions;
    SharedPreferences.setMockInitialValues({});
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    return controller;
  }

  setUp(() => permissions = FakePermissionHandler());

  testWidgets('a native error shows up where the user is, and can be cleared '
      'in settings', (tester) async {
    await startApp(tester);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'error',
        'message': 'Pairing with AA:AA failed',
      }),
      (_) {},
    );
    await tester.pump();

    // On the home page, not only in settings.
    expect(find.widgetWithText(SnackBar, 'Pairing with AA:AA failed'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('Pairing with AA:AA failed'), findsWidgets);
    await tester.tap(find.byTooltip('오류 지우기'));
    await tester.pumpAndSettle();
    expect(find.text('오류'), findsNothing);
  });

  testWidgets('denied permissions are reported on the home page', (tester) async {
    permissions
      ..checkResult = PermissionStatus.denied
      ..requestResult = PermissionStatus.denied;
    await startApp(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Bluetooth 권한이 없어'), findsOneWidget);
  });
}
