import 'package:bluetooth_communicator/main.dart';
import 'package:flutter/foundation.dart';
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
  Future<BleAppController> openSettings(WidgetTester tester) async {
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
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> nativeEvent(WidgetTester tester, Map<String, dynamic> event) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> showAppsSection(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('연동된 앱'), 200);
    await tester.pumpAndSettle();
  }

  testWidgets('the settings page lists the apps native code registered', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final controller = await openSettings(tester);
      await showAppsSection(tester);
      expect(find.text('이 기기를 사용하는 앱이 없습니다'), findsOneWidget);

      await nativeEvent(tester, {
        'type': 'apps',
        'apps': [
          {
            'packageName': 'com.example.model',
            'label': 'Decision Model Runner',
            'listening': true,
            'receiveService': true,
            'registeredAt': 1,
            'lastUsedAt': 2,
          },
          {'packageName': 'com.example.chat', 'label': '', 'listening': false, 'receiveService': false},
        ],
      });
      await tester.scrollUntilVisible(find.text('com.example.chat\n앱을 열면 메시지를 받습니다'), 200);

      expect(controller.registeredApps.map((app) => app.packageName), ['com.example.model', 'com.example.chat']);
      expect(find.text('Decision Model Runner'), findsOneWidget);
      expect(find.text('com.example.model\n실행 중 · 메시지 받는 중'), findsOneWidget);
      // No label: the package name stands in for it.
      expect(find.text('com.example.chat\n앱을 열면 메시지를 받습니다'), findsOneWidget);

      // An uninstalled app is gone from the next list.
      await nativeEvent(tester, {
        'type': 'apps',
        'apps': [
          {'packageName': 'com.example.model', 'label': 'Decision Model Runner', 'receiveService': true},
        ],
      });
      expect(find.textContaining('com.example.chat'), findsNothing);
      expect(find.text('com.example.model\n앱이 꺼져 있어도 메시지를 받습니다'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS has no AIDL, so no app section', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await openSettings(tester);
      expect(find.text('연동된 앱', skipOffstage: false), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
