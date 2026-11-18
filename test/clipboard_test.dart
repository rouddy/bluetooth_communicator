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
  late List<String> clipboardWrites;

  Future<BleAppController> openDevicePage(WidgetTester tester, {bool connected = true}) async {
    nativeCalls = [];
    clipboardWrites = [];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_controlChannel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      _eventsChannel,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    // The system clipboard (Clipboard.setData goes through the platform channel).
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_controlChannel, null);
      messenger.setMockStreamHandler(_eventsChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    PermissionHandlerPlatform.instance = FakePermissionHandler();
    SharedPreferences.setMockInitialValues({});
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await nativeEvent(tester, {
      'type': 'peers',
      'peers': [
        {'deviceId': 'AA:AA', 'name': 'Peer', 'peerId': 'pa', 'state': 'paired', 'connected': connected},
      ],
    });
    await tester.tap(find.text('Peer'));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> clipboardEvent(WidgetTester tester, Map<String, dynamic> event) =>
      nativeEvent(tester, {'type': 'clipboard', 'deviceId': 'AA:AA', ...event});

  testWidgets('the peer\'s clipboard lands in this phone\'s clipboard', (tester) async {
    await openDevicePage(tester);
    expect(find.text('상대 기기의 클립보드를 이 기기에 복사합니다'), findsOneWidget);

    await tester.tap(find.text('클립보드 가져오기'));
    await tester.pump();
    expect(nativeCalls.last.method, 'requestClipboard');
    expect(nativeCalls.last.arguments, {'deviceId': 'AA:AA'});
    expect(find.text('가져오는 중…'), findsOneWidget);

    // The peer's app wasn't on screen; its user is asked first.
    await clipboardEvent(tester, {'result': 'waiting'});
    expect(find.text('상대 기기에서 확인을 기다리는 중…'), findsOneWidget);

    await clipboardEvent(tester, {'result': 'ok', 'text': '복사한 텍스트'});
    await tester.pump();
    expect(clipboardWrites, ['복사한 텍스트']);
    expect(find.text('Peer의 클립보드를 가져왔습니다. 붙여넣을 수 있습니다.'), findsOneWidget);
    expect(find.text('상대 기기의 클립보드를 이 기기에 복사합니다'), findsOneWidget);
  });

  testWidgets('each failure says why and leaves the clipboard alone', (tester) async {
    await openDevicePage(tester);
    const cases = {
      'empty': 'Peer의 클립보드가 비어 있습니다.',
      'notText': 'Peer의 클립보드에 텍스트가 없습니다.',
      'unavailable': 'Peer에서 앱을 열어야 클립보드를 가져올 수 있습니다.',
      'denied': 'Peer에서 클립보드 공유를 허용하지 않았습니다.',
      'tooLarge': 'Peer의 클립보드 내용이 너무 깁니다.',
      'timeout': 'Peer에서 응답이 없습니다.',
    };
    for (final MapEntry(key: result, value: message) in cases.entries) {
      await tester.tap(find.text('클립보드 가져오기'));
      await tester.pump();
      await clipboardEvent(tester, {'result': result});
      expect(find.text(message), findsOneWidget, reason: result);
    }
    await tester.tap(find.text('클립보드 가져오기'));
    await tester.pump();
    await clipboardEvent(tester, {'result': 'failed', 'status': 1});
    expect(find.text('Peer의 앱이 클립보드 가져오기를 지원하지 않습니다. 앱을 업데이트해 주세요.'), findsOneWidget);
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('it needs a connection', (tester) async {
    await openDevicePage(tester, connected: false);

    expect(find.text('연결되면 쓸 수 있습니다'), findsOneWidget);
    await tester.tap(find.text('클립보드 가져오기'));
    await tester.pump();
    expect(nativeCalls.where((call) => call.method == 'requestClipboard'), isEmpty);
  });

  testWidgets('sending this phone\'s clipboard is announced', (tester) async {
    await openDevicePage(tester);

    await nativeEvent(tester, {'type': 'clipboardShared', 'deviceId': 'AA:AA'});
    await tester.pump();

    expect(find.text('Peer에 클립보드를 보냈습니다.'), findsOneWidget);
  });

  testWidgets('sharing can be turned off in the settings, and stays off', (tester) async {
    final controller = await openDevicePage(tester);
    expect(nativeCalls.firstWhere((call) => call.method == 'setClipboardSharing').arguments, {'enabled': true});
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('클립보드 공유'));
    await tester.pumpAndSettle();

    expect(controller.clipboardSharing, isFalse);
    expect(nativeCalls.last.method, 'setClipboardSharing');
    expect(nativeCalls.last.arguments, {'enabled': false});
    final restarted = BleAppController();
    nativeCalls.clear();
    await restarted.initialize();
    expect(nativeCalls.firstWhere((call) => call.method == 'setClipboardSharing').arguments, {'enabled': false});
  });
}

Future<void> nativeEvent(WidgetTester tester, Map<String, dynamic> event) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'com.rouddy.bluetooth_communicator/bluetooth_events',
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );
  await tester.pump();
}
