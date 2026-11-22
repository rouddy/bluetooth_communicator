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

  /// What `sendFile` and `exportFile` answer, or the error code they throw.
  late Object nativeAnswer;

  Future<BleAppController> openApp(WidgetTester tester, {bool connected = true}) async {
    nativeCalls = [];
    nativeAnswer = true;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_controlChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'sendFile' || call.method == 'exportFile') {
        final answer = nativeAnswer;
        if (answer is String) {
          throw PlatformException(code: answer);
        }
        return answer;
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
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await nativeEvent(tester, {
      'type': 'peers',
      'peers': [
        {'deviceId': 'AA:AA', 'name': 'Peer', 'peerId': 'pa', 'state': 'paired', 'connected': connected},
      ],
    });
    return controller;
  }

  Future<void> openDevicePage(WidgetTester tester) async {
    await tester.tap(find.text('Peer'));
    await tester.pumpAndSettle();
  }

  Future<void> transferEvent(WidgetTester tester, Map<String, dynamic> event) async {
    await nativeEvent(tester, {
      'type': 'fileTransfer',
      'id': 7,
      'deviceId': 'AA:AA',
      'peerId': 'pa',
      'name': '사진.jpg',
      'size': 40000,
      'mime': 'image/jpeg',
      'bytes': 0,
      'byPeer': false,
      ...event,
    });
    await tester.pumpAndSettle();
  }

  Iterable<MethodCall> callsTo(String method) => nativeCalls.where((call) => call.method == method);

  group('sending', () {
    testWidgets('the device page offers a picked file and shows how it goes', (tester) async {
      await openApp(tester);
      await openDevicePage(tester);

      await tester.tap(find.text('파일 보내기'));
      await tester.pump();
      expect(callsTo('sendFile').single.arguments, {'deviceId': 'AA:AA'});

      await transferEvent(tester, {'direction': 'send', 'state': 'waiting'});
      expect(find.text('사진.jpg'), findsOneWidget);
      expect(find.text('상대 기기의 승인을 기다리는 중…'), findsOneWidget);

      await transferEvent(tester, {'direction': 'send', 'state': 'transferring', 'bytes': 16384});
      expect(find.text('16.4 KB / 40.0 KB'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.41, 0.01));

      await transferEvent(tester, {'direction': 'send', 'state': 'completed', 'bytes': 40000});
      expect(find.text('사진.jpg'), findsNothing);
      expect(find.text('Peer에 파일을 보냈습니다: 사진.jpg'), findsOneWidget);
    });

    testWidgets('a transfer can be canceled from the device page', (tester) async {
      await openApp(tester);
      await openDevicePage(tester);
      await transferEvent(tester, {'direction': 'send', 'state': 'transferring', 'bytes': 100});

      await tester.tap(find.byTooltip('전송 취소'));
      await tester.pumpAndSettle();

      expect(callsTo('cancelFile').single.arguments, {'id': 7});
      expect(find.text('사진.jpg'), findsNothing);
      // An update that was already on its way doesn't bring it back, and the
      // cancel the user asked for isn't reported as a failure.
      await transferEvent(tester, {'direction': 'send', 'state': 'transferring', 'bytes': 200});
      expect(find.text('사진.jpg'), findsNothing);
      await transferEvent(tester, {'direction': 'send', 'state': 'canceled'});
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('each way it can fail says why', (tester) async {
      await openApp(tester);
      await openDevicePage(tester);
      const cases = <Map<String, dynamic>, String>{
        {'state': 'declined', 'byPeer': true}: 'Peer에서 파일을 거절했습니다.',
        {'state': 'canceled', 'byPeer': true}: 'Peer에서 파일 받기를 취소했습니다.',
        {'state': 'failed', 'reason': 'timeout'}: 'Peer에서 응답이 없어 파일을 보내지 못했습니다.',
        {'state': 'failed', 'reason': 'unsupported', 'status': 1}: 'Peer의 앱이 파일 받기를 지원하지 않습니다. 앱을 업데이트해 주세요.',
        {'state': 'failed', 'reason': 'notConnected', 'status': 1000}: 'Peer와(과) 연결되어 있지 않아 파일을 보내지 못했습니다.',
        {'state': 'failed', 'reason': 'peer'}: 'Peer에서 파일을 저장하지 못했습니다.',
      };
      var id = 100;
      for (final MapEntry(key: event, value: message) in cases.entries) {
        await transferEvent(tester, {'id': ++id, 'direction': 'send', 'state': 'waiting'});
        await transferEvent(tester, {'id': id, 'direction': 'send', ...event});
        expect(find.text(message), findsOneWidget, reason: '$event');
      }
      expect(find.text('사진.jpg'), findsNothing);
    });

    testWidgets('a file that can\'t be opened is reported', (tester) async {
      await openApp(tester);
      await openDevicePage(tester);
      nativeAnswer = 'READ_FAILED';

      await tester.tap(find.text('파일 보내기'));
      await tester.pumpAndSettle();

      expect(find.text('파일을 열지 못했습니다.'), findsOneWidget);
    });

    testWidgets('it needs a connection', (tester) async {
      await openApp(tester, connected: false);
      await openDevicePage(tester);

      await tester.tap(find.text('파일 보내기'));
      await tester.pump();

      expect(callsTo('sendFile'), isEmpty);
    });
  });

  group('receiving', () {
    testWidgets('an offer asks the user; the accepted file can be saved or shared', (tester) async {
      await openApp(tester);

      await transferEvent(tester, {'direction': 'receive', 'state': 'offered'});
      expect(find.byType(FileTransferDialog), findsOneWidget);
      expect(find.text('파일 받기 요청'), findsOneWidget);
      expect(find.text('Peer에서 파일을 보내려고 합니다.'), findsOneWidget);
      expect(find.text('사진.jpg'), findsOneWidget);
      expect(find.text('40.0 KB'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '승인'));
      await tester.pump();
      expect(callsTo('respondFile').single.arguments, {'id': 7, 'accept': true});

      await transferEvent(tester, {'direction': 'receive', 'state': 'transferring', 'bytes': 32768});
      expect(find.text('파일 받는 중'), findsOneWidget);
      expect(find.text('32.8 KB / 40.0 KB'), findsOneWidget);

      await transferEvent(tester, {
        'direction': 'receive',
        'state': 'completed',
        'bytes': 40000,
        'path': '/cache/received/1/사진.jpg',
      });
      expect(find.text('파일을 받았습니다'), findsOneWidget);

      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(callsTo('exportFile').last.arguments, {'id': 7, 'action': 'save'});
      // Said in the dialog: a SnackBar would be hidden behind it.
      expect(find.descendant(of: find.byType(FileTransferDialog), matching: find.text('파일을 저장했습니다.')), findsOneWidget);

      await tester.tap(find.text('앱으로 보내기'));
      await tester.pumpAndSettle();
      expect(callsTo('exportFile').last.arguments, {'id': 7, 'action': 'share'});
      // The export screen stays up until it's closed.
      expect(find.text('파일을 받았습니다'), findsOneWidget);

      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(callsTo('dismissFile').single.arguments, {'id': 7});
      expect(find.byType(FileTransferDialog), findsNothing);
    });

    testWidgets('declining closes the dialog quietly', (tester) async {
      await openApp(tester);
      await transferEvent(tester, {'direction': 'receive', 'state': 'offered'});

      await tester.tap(find.text('거절'));
      await tester.pumpAndSettle();

      expect(callsTo('respondFile').single.arguments, {'id': 7, 'accept': false});
      expect(find.byType(FileTransferDialog), findsNothing);
      await transferEvent(tester, {'direction': 'receive', 'state': 'declined'});
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the download can be canceled', (tester) async {
      await openApp(tester);
      await transferEvent(tester, {'direction': 'receive', 'state': 'transferring', 'bytes': 100});

      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      expect(callsTo('cancelFile').single.arguments, {'id': 7});
      expect(find.byType(FileTransferDialog), findsNothing);
    });

    testWidgets('a transfer that ends early closes the dialog and says why', (tester) async {
      await openApp(tester);
      await transferEvent(tester, {'direction': 'receive', 'state': 'offered'});
      await transferEvent(tester, {'direction': 'receive', 'state': 'failed', 'reason': 'timeout'});
      expect(find.byType(FileTransferDialog), findsNothing);
      expect(find.text('Peer의 파일 받기 요청이 시간이 지나 거절되었습니다.'), findsOneWidget);

      await transferEvent(tester, {'id': 8, 'direction': 'receive', 'state': 'transferring'});
      await transferEvent(tester, {'id': 8, 'direction': 'receive', 'state': 'canceled', 'byPeer': true});
      expect(find.byType(FileTransferDialog), findsNothing);
      expect(find.text('Peer에서 파일 보내기를 취소했습니다.'), findsOneWidget);
    });

    testWidgets('a file received while the app was closed opens the export screen', (tester) async {
      await openApp(tester);

      // Replayed on initialize: it finished downloading in the background.
      await transferEvent(tester, {'direction': 'receive', 'state': 'completed', 'bytes': 40000, 'path': '/p'});

      expect(find.text('파일을 받았습니다'), findsOneWidget);
      expect(find.text('앱으로 보내기'), findsOneWidget);
    });
  });

  test('sizes read like the system\'s, in decimal units', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(200000), '200.0 KB');
    expect(formatBytes(16384), '16.4 KB');
    expect(formatBytes(3565158), '3.6 MB');
    expect(formatBytes(5 * 1024 * 1024 * 1024), '5.4 GB');
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
