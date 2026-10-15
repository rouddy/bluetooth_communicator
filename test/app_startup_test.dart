import 'dart:async';

import 'package:bluetooth_communicator/main.dart' as app;
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Not granted yet, so initialize() has to go through the request (the
    // system permission dialog on a real device).
    permissions = FakePermissionHandler(
      checkResult: PermissionStatus.denied,
      requestResult: PermissionStatus.granted,
    );
    PermissionHandlerPlatform.instance = permissions;
  });

  void mockNativeSide(WidgetTester tester) {
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
  }

  testWidgets('main renders the home page while the permission request is '
      'still pending', (tester) async {
    mockNativeSide(tester);
    permissions.requestGate = Completer<void>();

    app.main();
    await tester.pump();

    // Previously main() awaited initialize() before runApp(), so nothing was
    // on screen until the permission dialog was answered.
    expect(find.text('기기 목록'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    permissions.requestGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a failing initialization is reported instead of leaving the '
      'app stuck', (tester) async {
    mockNativeSide(tester);
    permissions.requestError = PlatformException(code: 'PermissionHandler');

    app.main();
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    // On the settings page (and in the SnackBar, if it's still showing).
    expect(find.textContaining('초기화 실패'), findsWidgets);
  });
}
