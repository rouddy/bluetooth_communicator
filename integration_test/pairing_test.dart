// Two-device test: app pairing (docs/protocol.md 6.3) between this phone and a peer
// running the app, driven from this phone. The peer's user (or a script on it)
// approves on the other phone.
//
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/pairing_test.dart -d <device-id> \
//     --dart-define=PEER_NAME=S23 --dart-define=MODE=connect \
//     --dart-define=DEVICE_NAME=AlgorigoSE
//
// - MODE=connect: tap the peer (a name containing PEER_NAME) and 연결, then approve
//   the code here.
// - MODE=approve: wait for the peer to connect, then approve the code here.
// - MODE=setup: only turn on advertising and scanning and set the name. With
//   --keep-app-running the app then stays up for steps driven from the peer.
// - MODE=remove: delete the peer from its page (UNPAIR).
// - MODE=clipboard: take the peer's clipboard (클립보드 가져오기) and print it; with
//   EXPECT_CLIP, check it.
// - MODE=sendFile: send the peer a file of FILE_SIZE bytes (default 100,000) and print
//   how long it took; the peer's user approves it.
// - MODE=receiveFile: approve the next file the peer sends, wait until it's received,
//   print how long that took, and close the export screen.
// - MODE=media: on the peer's page, ask whether it's playing, press play/pause twice,
//   and print the state after each answer (the peer is an Android phone with a player).
// CENTRAL=false turns scanning off on this phone, so the peer connects to it as
// central (this phone is the peripheral; the default lets either side connect).
// CLIP_TEXT puts that text into this phone's clipboard first, for the peer to take.
// DEVICE_NAME (iOS) sets the name peers see. The phones must already be paired at the
// OS level, or the system pairing dialogs need a person. LIVE_MINUTES keeps the app
// drawing afterwards (a finished test's UI is frozen), to watch it while the other
// phone drives the next steps.

import 'dart:io';

import 'package:bluetooth_communicator/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

const _peerName = String.fromEnvironment('PEER_NAME');
const _mode = String.fromEnvironment('MODE', defaultValue: 'connect');
const _deviceName = String.fromEnvironment('DEVICE_NAME');
const _liveMinutes = int.fromEnvironment('LIVE_MINUTES');
const _clipText = String.fromEnvironment('CLIP_TEXT');
const _expectClip = String.fromEnvironment('EXPECT_CLIP');
const _fileSize = int.fromEnvironment('FILE_SIZE', defaultValue: 100000);
const _central = bool.fromEnvironment('CENTRAL', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pairs with $_peerName ($_mode)', (tester) async {
    expect(_peerName.isNotEmpty || _mode == 'setup', isTrue, reason: 'Pass --dart-define=PEER_NAME=…');
    app.main();
    await pumpUntilFound(tester, find.text('기기 목록'));
    await ensureBleModesEnabled(tester, central: _central);
    if (_deviceName.isNotEmpty && app.BleAppController.canSetDeviceName) {
      await setDeviceName(tester, _deviceName);
    }

    if (_clipText.isNotEmpty) {
      await Clipboard.setData(const ClipboardData(text: _clipText));
    }
    if (_mode == 'setup') {
      return stayLive(tester);
    }
    final peer = find.textContaining(_peerName);
    if (_mode == 'clipboard') {
      await pumpUntilFound(tester, peer);
      await tester.tap(peer.first);
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('상대 기기의 클립보드를 이 기기에 복사합니다'));
      await tester.tap(find.text('클립보드 가져오기'));
      await pumpUntilFound(tester, find.textContaining('클립보드를 가져왔습니다'), timeout: const Duration(seconds: 70));
      final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      debugPrint('[clipboard] $copied');
      if (_expectClip.isNotEmpty) {
        expect(copied, _expectClip);
      }
      return stayLive(tester);
    }
    if (_mode == 'sendFile') {
      await pumpUntilFound(tester, peer);
      await tester.tap(peer.first);
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('파일을 골라 상대 기기로 보냅니다. 상대가 승인하면 전송됩니다'));
      final file = File('${Directory.systemTemp.path}/rbc-test-$_fileSize.bin')
        ..writeAsBytesSync(List.generate(_fileSize, (i) => i * 7 & 0xFF));
      final page = tester.widget<app.DeviceControlPage>(find.byType(app.DeviceControlPage));
      await page.controller.sendFile(page.device.identifier, path: file.path);
      await pumpUntilFound(tester, find.text('상대 기기의 승인을 기다리는 중…'), timeout: const Duration(seconds: 30));
      final started = DateTime.now();
      // The approval, then the transfer itself.
      await pumpUntilFound(tester, find.byType(LinearProgressIndicator), timeout: const Duration(seconds: 130));
      final accepted = DateTime.now();
      await pumpUntilFound(tester, find.textContaining('파일을 보냈습니다'), timeout: const Duration(minutes: 30));
      final seconds = DateTime.now().difference(accepted).inMilliseconds / 1000;
      debugPrint('[file] sent $_fileSize bytes in ${seconds}s after approval '
          '(${(_fileSize / 1024 / seconds).toStringAsFixed(1)} KB/s; approval took '
          '${accepted.difference(started).inSeconds}s)');
      return stayLive(tester);
    }
    if (_mode == 'receiveFile') {
      await pumpUntilFound(tester, find.text('파일 받기 요청'), timeout: const Duration(minutes: 5));
      await tester.tap(find.widgetWithText(FilledButton, '승인'));
      final started = DateTime.now();
      await pumpUntilFound(tester, find.text('파일을 받았습니다'), timeout: const Duration(minutes: 30));
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
      final transfer = tester
          .widget<app.FileTransferDialog>(find.byType(app.FileTransferDialog))
          .controller
          .fileTransfers
          .values
          .last;
      debugPrint('[file] received ${transfer.name} (${transfer.size} bytes) in ${seconds}s '
          '(${(transfer.size / 1024 / seconds).toStringAsFixed(1)} KB/s) at ${transfer.path}');
      expect(File(transfer.path!).lengthSync(), transfer.size);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      return stayLive(tester);
    }
    if (_mode == 'media') {
      await pumpUntilFound(tester, peer);
      await tester.tap(peer.first);
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('상대 기기의 음악·동영상 재생을 조작합니다'), timeout: const Duration(seconds: 60));
      final page = tester.widget<app.DeviceControlPage>(find.byType(app.DeviceControlPage));
      final controller = page.controller;
      final id = page.device.identifier;
      Future<app.MediaPlayback> press(String tooltip) async {
        final started = DateTime.now();
        await tester.tap(find.byTooltip(tooltip));
        await tester.pump();
        await pumpUntilGone(tester, find.text('보내는 중…'), timeout: const Duration(seconds: 15));
        final playback = controller.mediaStates[id]!.playback;
        debugPrint('[media] $tooltip -> $playback in ${DateTime.now().difference(started).inMilliseconds} ms');
        return playback;
      }

      final before = await press('상태 새로고침');
      final toggle = before == app.MediaPlayback.playing ? '일시정지' : '재생';
      final after = await press(toggle);
      expect(after, isNot(before), reason: 'pressing $toggle should change the state');
      await press(after == app.MediaPlayback.playing ? '일시정지' : '재생');
      return stayLive(tester);
    }
    if (_mode == 'remove') {
      await pumpUntilFound(tester, peer);
      await tester.tap(peer.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('기기 삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await pumpUntilFound(tester, find.text('기기 목록'));
      return stayLive(tester);
    }
    if (_mode == 'connect') {
      await pumpUntilFound(tester, peer, timeout: const Duration(seconds: 60));
      await tester.tap(peer.first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '연결'));
    }

    // The code dialog; approve it here, and wait for the peer's approval.
    await pumpUntilFound(tester, find.byType(app.PairingDialog), timeout: const Duration(seconds: 90));
    expect(find.textContaining(RegExp(r'^\d{6}$')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '승인'));
    await pumpUntilGone(tester, find.byType(app.PairingDialog), timeout: const Duration(seconds: 70));

    if (_mode == 'connect') {
      await pumpUntilFound(tester, find.widgetWithText(FilledButton, '연결됨'));
      await tester.pageBack();
    } else {
      await pumpUntilFound(tester, find.textContaining('연결됨'));
      expect(peer, findsWidgets);
    }
    await stayLive(tester);
    // The phone's accessibility features (e.g. AssistiveTouch) keep semantics on,
    // which the test framework would report as a leak.
  }, semanticsEnabled: false);
}

Future<void> stayLive(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(minutes: _liveMinutes));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
