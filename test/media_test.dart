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

  Future<BleAppController> openDevicePage(WidgetTester tester, {bool connected = true, int platform = 1}) async {
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
    await nativeEvent(tester, {
      'type': 'peers',
      'peers': [
        {
          'deviceId': 'AA:AA',
          'name': 'Peer',
          'peerId': 'pa',
          'state': 'paired',
          'platform': platform,
          'connected': connected,
        },
      ],
    });
    await tester.tap(find.text('Peer'));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> mediaEvent(WidgetTester tester, Map<String, dynamic> event) =>
      nativeEvent(tester, {'type': 'mediaControl', 'deviceId': 'AA:AA', ...event});

  MethodCall lastMediaCall() => nativeCalls.lastWhere((call) => call.method == 'controlMedia');

  testWidgets('the buttons press keys on the peer and show what it answered', (tester) async {
    await openDevicePage(tester);
    expect(find.text('상대 기기의 음악·동영상 재생을 조작합니다'), findsOneWidget);

    // Not knowing whether it plays, the middle button toggles.
    await tester.tap(find.byTooltip('재생/일시정지'));
    await tester.pump();
    expect(lastMediaCall().arguments, {'deviceId': 'AA:AA', 'op': 'playPause'});
    expect(find.text('보내는 중…'), findsOneWidget);

    await mediaEvent(tester, {'op': 'playPause', 'result': 'ok', 'state': 'playing'});
    expect(find.text('상대 기기에서 재생 중'), findsOneWidget);

    // Now it pauses, then plays.
    await tester.tap(find.byTooltip('일시정지'));
    await tester.pump();
    expect(lastMediaCall().arguments, {'deviceId': 'AA:AA', 'op': 'pause'});
    await mediaEvent(tester, {'op': 'pause', 'result': 'ok', 'state': 'notPlaying'});
    expect(find.text('상대 기기에서 재생 중이 아님'), findsOneWidget);
    await tester.tap(find.byTooltip('재생'));
    await tester.pump();
    expect(lastMediaCall().arguments, {'deviceId': 'AA:AA', 'op': 'play'});
    await mediaEvent(tester, {'op': 'play', 'result': 'ok', 'state': 'playing'});

    for (final (tooltip, op) in [('이전 곡', 'previous'), ('다음 곡', 'next'), ('상태 새로고침', 'getState')]) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
      expect(lastMediaCall().arguments, {'deviceId': 'AA:AA', 'op': op});
      await mediaEvent(tester, {'op': op, 'result': 'ok', 'state': 'playing'});
    }
  });

  testWidgets('one command at a time', (tester) async {
    await openDevicePage(tester);

    await tester.tap(find.byTooltip('다음 곡'));
    await tester.pump();
    await tester.tap(find.byTooltip('다음 곡'));
    await tester.pump();

    expect(nativeCalls.where((call) => call.method == 'controlMedia'), hasLength(1));
  });

  testWidgets('each failure says why', (tester) async {
    await openDevicePage(tester);
    const cases = {
      {'result': 'failed'}: 'Peer에서 미디어 키를 누르지 못했습니다.',
      {'result': 'unsupportedOp'}: 'Peer의 앱이 이 미디어 명령을 지원하지 않습니다.',
      {'result': 'unsupported'}: 'Peer의 앱이 미디어 조작을 지원하지 않습니다. 앱을 업데이트해 주세요.',
      {'result': 'timeout'}: 'Peer에서 응답이 없습니다.',
      {'result': 'undelivered', 'status': 2}: 'Peer의 앱이 미디어 조작을 지원하지 않습니다. 앱을 업데이트해 주세요.',
      {'result': 'undelivered', 'status': 1000}: 'Peer와(과) 연결되어 있지 않습니다.',
      {'result': 'undelivered', 'status': 4}: 'Peer에 미디어 명령을 보내지 못했습니다.',
    };
    for (final MapEntry(key: event, value: message) in cases.entries) {
      await tester.tap(find.byTooltip('상태 새로고침'));
      await tester.pump();
      await mediaEvent(tester, {'op': 'getState', ...event});
      expect(find.text(message), findsOneWidget, reason: '$event');
      // The controls are usable again.
      expect(find.text('보내는 중…'), findsNothing);
    }
  });

  testWidgets('it needs a connection', (tester) async {
    await openDevicePage(tester, connected: false);

    expect(
      find.descendant(of: find.widgetWithText(ListTile, '미디어 조작'), matching: find.text('연결되면 쓸 수 있습니다')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('다음 곡'));
    await tester.pump();
    expect(nativeCalls.where((call) => call.method == 'controlMedia'), isEmpty);
  });

  testWidgets('an iPhone that turns a command away is explained', (tester) async {
    final controller = await openDevicePage(tester, platform: 2);

    // No controls for an iPhone, but a command from elsewhere still gets an answer.
    await controller.controlMedia('AA:AA', MediaOp.getState);
    await nativeEvent(tester, {'type': 'mediaControl', 'deviceId': 'AA:AA', 'op': 'getState', 'result': 'unsupported'});
    await tester.pump();

    expect(find.text('Peer은(는) 미디어 조작을 지원하지 않습니다. iPhone은 다른 앱의 재생을 조작할 수 없습니다.'), findsOneWidget);
  });

  testWidgets('an iPhone peer has no media controls', (tester) async {
    await openDevicePage(tester, platform: 2);

    expect(find.text('미디어 조작'), findsNothing);
    expect(find.text('파일 보내기'), findsOneWidget);
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
