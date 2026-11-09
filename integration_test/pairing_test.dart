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
// CLIP_TEXT puts that text into this phone's clipboard first, for the peer to take.
// DEVICE_NAME (iOS) sets the name peers see. The phones must already be paired at the
// OS level, or the system pairing dialogs need a person. LIVE_MINUTES keeps the app
// drawing afterwards (a finished test's UI is frozen), to watch it while the other
// phone drives the next steps.

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pairs with $_peerName ($_mode)', (tester) async {
    expect(_peerName.isNotEmpty || _mode == 'setup', isTrue, reason: 'Pass --dart-define=PEER_NAME=…');
    app.main();
    await pumpUntilFound(tester, find.text('기기 목록'));
    await ensureBleModesEnabled(tester);
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
