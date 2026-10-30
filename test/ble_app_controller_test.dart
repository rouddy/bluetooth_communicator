import 'dart:async';

import 'package:bluetooth_communicator/main.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late FakePermissionHandler permissions;
  late List<MethodCall> nativeCalls;

  /// Routes the control channel to a recording handler, as if native code
  /// were registered.
  void registerNativeHandler() {
    messenger.setMockMethodCallHandler(_controlChannel, (call) async {
      nativeCalls.add(call);
      return call.method == 'initialize' ? true : null;
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    permissions = FakePermissionHandler();
    PermissionHandlerPlatform.instance = permissions;
    nativeCalls = [];
    messenger.setMockStreamHandler(
      _eventsChannel,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_controlChannel, null);
    messenger.setMockStreamHandler(_eventsChannel, null);
  });

  Future<void> nativeEvent(Map<String, dynamic> event) {
    return messenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  group('BleStatus', () {
    BleStatus status({
      bool advertising = false,
      bool scanning = false,
      int connectedCount = 0,
      bool bluetoothOn = true,
    }) => BleStatus.fromEvent({
      'type': 'status',
      'advertising': advertising,
      'scanning': scanning,
      'connectedCount': connectedCount,
      'bluetoothOn': bluetoothOn,
    });

    test('labels the structured status the same on both platforms', () {
      expect(status().label, 'idle');
      expect(status(advertising: true, scanning: true).label, 'advertising scanning');
      expect(status(scanning: true, connectedCount: 2).label, 'scanning connected:2');
      expect(status(advertising: true, bluetoothOn: false).label, 'bluetooth-off');
    });

    test('the controller reports unknown until the first status event', () async {
      final controller = BleAppController();
      expect(controller.backgroundStatus, 'unknown');
      expect(controller.bluetoothOff, isFalse);
    });
  });

  group('native channel errors', () {
    test('initialize reports an unregistered native channel instead of '
        'throwing', () async {
      // No handler for the control channel: invokeMethod throws
      // MissingPluginException, which used to escape initialize() and main().
      final controller = BleAppController();

      await controller.initialize();

      expect(controller.lastError, contains('channel unavailable'));
    });

    test('a single unimplemented method does not abort initialize', () async {
      messenger.setMockMethodCallHandler(_controlChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'scanNow') {
          throw MissingPluginException();
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({'prefs_central_enabled': true});
      final controller = BleAppController();

      await controller.initialize();

      expect(nativeCalls.map((c) => c.method), [
        'initialize',
        'setCentralEnabled',
        'scanNow',
      ]);
      expect(controller.lastError, contains('scanNow'));
    });
  });

  group('initialize', () {
    test('replays saved modes to native code, which reconnects the peers '
        'itself', () async {
      registerNativeHandler();
      SharedPreferences.setMockInitialValues({
        'prefs_advertising_enabled': true,
        'prefs_central_enabled': true,
        'prefs_registered_devices':
            '[{"identifier":"AA:BB:CC:DD:EE:FF","name":"peer"}]',
      });
      final controller = BleAppController();

      await controller.initialize();
      await pumpEventQueue();

      expect(nativeCalls.map((c) => c.method), [
        'initialize',
        'setAdvertisingEnabled',
        'setCentralEnabled',
        'scanNow',
      ]);
      expect(controller.lastError, isNull);
      // The old Dart-side device list is gone; native code keeps the peers.
      expect(controller.registeredDevices, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isNot(contains('prefs_registered_devices')));
    });

    test('skips native calls and reports an error when permissions are '
        'denied', () async {
      registerNativeHandler();
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.denied;
      final controller = BleAppController();

      await controller.initialize();

      expect(permissions.requestCount, 1);
      expect(nativeCalls, isEmpty);
      expect(controller.permissionsGranted, isFalse);
      expect(controller.lastError, contains('권한'));
    });
  });

  test('the removed chat history is deleted from storage', () async {
    registerNativeHandler();
    SharedPreferences.setMockInitialValues({
      'prefs_messages': '{"AA:AA":[{"text":"hi"}]}',
      'prefs_unread_counts': '{"AA:AA":1}',
    });
    final controller = BleAppController();

    await controller.initialize();
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isNot(contains('prefs_messages')));
    expect(prefs.getKeys(), isNot(contains('prefs_unread_counts')));
  });

  group('nearby devices', () {
    test('a device that stops being reported is dropped after the timeout', () async {
      registerNativeHandler();
      var now = DateTime(2026, 10, 16, 0, 0, 0);
      final controller = BleAppController(clock: () => now);
      await controller.initialize();
      Future<void> seen(String id) => messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'discovered',
          'deviceId': id,
          'name': 'Jump3',
        }),
        (_) {},
      );

      await seen('OLD');
      await seen('NEW');
      // Native code repeats devices that are still advertising every 30 s.
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 30));
        await seen('NEW');
        controller.pruneNearbyDevices();
      }

      expect(controller.discoveredDevices.map((d) => d.identifier), ['NEW']);
    });

    test('a device reported within the timeout stays', () async {
      registerNativeHandler();
      var now = DateTime(2026, 10, 16);
      final controller = BleAppController(clock: () => now);
      await controller.initialize();
      await messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'discovered',
          'deviceId': 'AA',
          'name': 'Peer',
        }),
        (_) {},
      );

      now = now.add(BleAppController.nearbyTimeout - const Duration(seconds: 1));
      controller.pruneNearbyDevices();

      expect(controller.discoveredDevices, hasLength(1));
    });
  });

  group('removeDevice', () {
    test('forgets the device and asks native code to remove it', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();
      await nativeEvent({
        'type': 'peers',
        'peers': [
          {'deviceId': 'AA:AA', 'name': 'keep', 'peerId': 'a', 'state': 'paired', 'connected': false},
          {'deviceId': 'BB:BB', 'name': 'remove', 'peerId': 'b', 'state': 'paired', 'connected': true},
        ],
      });
      expect(controller.isKnownDevice('BB:BB'), isTrue);
      expect(controller.linkStateFor('BB:BB'), LinkState.connected);
      nativeCalls.clear();

      await controller.removeDevice('BB:BB');

      expect(controller.isKnownDevice('BB:BB'), isFalse);
      expect(controller.allKnownDevices.map((d) => d.identifier), ['AA:AA']);
      expect(nativeCalls.single.method, 'removeDevice');
      expect(nativeCalls.single.arguments, {'deviceId': 'BB:BB'});
    });
  });

  group('peers', () {
    test('the list comes from native code, with each peer\'s state', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();

      await nativeEvent({
        'type': 'peers',
        'peers': [
          {'deviceId': 'AA', 'name': 'A', 'peerId': 'pa', 'state': 'paired', 'connected': false},
          {'deviceId': 'BB', 'name': 'B', 'peerId': 'pb', 'state': 'repairNeeded', 'connected': false},
          {'deviceId': 'CC', 'name': 'C', 'peerId': 'pc', 'state': 'badMac', 'connected': false},
          {'deviceId': 'DD', 'name': 'D', 'peerId': 'pd', 'state': 'unpairedByPeer', 'connected': false},
        ],
      });

      expect(controller.registeredDevices.map((d) => d.name), ['A', 'B', 'C', 'D']);
      expect(controller.peerFor('AA')?.peerId, 'pa');
      expect(
        ['AA', 'BB', 'CC', 'DD'].map(controller.linkLabel),
        ['연결 안 됨', '다시 연결 필요', '인증 실패', '상대가 연결을 해제함'],
      );
    });

    test('a session takes the name the peer announced', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();

      await nativeEvent({
        'type': 'connected',
        'deviceId': 'AA',
        'peerId': 'pa',
        'name': '재홍의 S23',
      });

      expect(controller.allKnownDevices.single.name, '재홍의 S23');
      expect(controller.linkStateFor('AA'), LinkState.connected);
    });

    test('rejections and unpairing are explained', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();
      final errors = <String>[];
      controller.errors.listen(errors.add);
      await nativeEvent({
        'type': 'peers',
        'peers': [
          {'deviceId': 'AA', 'name': 'Peer', 'peerId': 'pa', 'state': 'paired', 'connected': false},
        ],
      });

      await nativeEvent({'type': 'peerRejected', 'deviceId': 'AA', 'reason': 'unknownPeer', 'byPeer': true});
      await nativeEvent({'type': 'peerRejected', 'deviceId': 'AA', 'reason': 'unknownPeer', 'byPeer': false});
      await nativeEvent({'type': 'peerRejected', 'deviceId': 'AA', 'reason': 'badMac', 'byPeer': false});
      await nativeEvent({'type': 'peerUnpaired', 'deviceId': 'AA'});
      await pumpEventQueue();

      expect(errors, [
        'Peer에서 이 기기를 삭제했습니다. 다시 연결하려면 연결 버튼을 누르세요.',
        'Peer의 인증에 실패했습니다. 보안을 위해 자동으로 다시 연결하지 않습니다.',
        'Peer에서 연결을 해제했습니다.',
      ]);
    });
  });

  group('pairing', () {
    test('a request waits for the user, then for the peer', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();
      final prompts = <PairingRequest>[];
      controller.pairingPrompts.listen(prompts.add);
      await controller.connectDevice('AA', pair: true);

      await nativeEvent({
        'type': 'pairingRequest',
        'deviceId': 'AA',
        'peerId': 'pa',
        'name': 'Peer',
        'code': '042517',
        'repair': false,
      });
      await pumpEventQueue();

      expect(prompts.single.code, '042517');
      expect(controller.linkLabel('AA'), '승인 대기 중…');

      nativeCalls.clear();
      await controller.respondPairing('AA', true);
      expect(nativeCalls.single.arguments, {'deviceId': 'AA', 'accept': true});
      expect(controller.pairingRequests['AA']!.approved, isTrue);

      await nativeEvent({'type': 'pairingResult', 'deviceId': 'AA', 'peerId': 'pa', 'result': 'paired'});
      expect(controller.pairingRequests, isEmpty);
      await nativeEvent({'type': 'connected', 'deviceId': 'AA', 'peerId': 'pa', 'name': 'Peer'});
      expect(controller.linkStateFor('AA'), LinkState.connected);
    });

    testWidgets('the connect timeout doesn\'t run while the users decide', (
      tester,
    ) async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();
      await controller.connectDevice('AA', pair: true);
      await nativeEvent({
        'type': 'pairingRequest',
        'deviceId': 'AA',
        'peerId': 'pa',
        'name': 'Peer',
        'code': '042517',
        'repair': false,
      });

      await tester.pump(BleAppController.connectingTimeout + const Duration(seconds: 5));

      expect(controller.linkStateFor('AA'), LinkState.awaitingApproval);
    });

    test('a failed pairing says why and ends the connecting state', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();
      await controller.connectDevice('AA', pair: true);
      await nativeEvent({
        'type': 'pairingRequest',
        'deviceId': 'AA',
        'peerId': 'pa',
        'name': 'Peer',
        'code': '042517',
        'repair': false,
      });

      await nativeEvent({'type': 'pairingResult', 'deviceId': 'AA', 'peerId': 'pa', 'result': 'rejected'});

      expect(controller.lastError, 'Peer와(과)의 연결이 거절되었습니다.');
      expect(controller.linkStateFor('AA'), LinkState.disconnected);
    });
  });

  group('initialize re-entrancy', () {
    test('a second call while the first is still running is ignored', () async {
      registerNativeHandler();
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.granted
        ..requestGate = Completer<void>();
      final controller = BleAppController();

      final first = controller.initialize();
      // Let the first call reach the pending permission request.
      await pumpEventQueue();
      expect(controller.initializing, isTrue);
      await controller.initialize();
      permissions.requestGate!.complete();
      await first;

      // Two concurrent requests make permission_handler throw on device.
      expect(permissions.requestCount, 1);
      expect(controller.initializing, isFalse);
    });
  });

  group('permissions', () {
    test('a permanent denial survives a later status check', () async {
      // Android's status check reports a permanent denial as plain `denied`;
      // only the request reveals it.
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.permanentlyDenied;
      final controller = BleAppController();

      await controller.requestPermissions();
      expect(controller.permissionsPermanentlyDenied, isTrue);

      await controller.checkPermissions();
      expect(controller.permissionsPermanentlyDenied, isTrue);
    });

    test('granting clears an earlier permanent denial', () async {
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.permanentlyDenied;
      final controller = BleAppController();
      await controller.requestPermissions();

      permissions.checkResult = PermissionStatus.granted;
      final granted = await controller.checkPermissions();

      expect(granted, isTrue);
      expect(controller.permissionsPermanentlyDenied, isFalse);
    });

    test('turned-off notifications are tracked apart from the Bluetooth '
        'permissions', () async {
      permissions.results[Permission.notification] = PermissionStatus.denied;
      final controller = BleAppController();

      expect(await controller.checkPermissions(), isTrue);
      expect(controller.notificationsDenied, isTrue);

      permissions.results[Permission.notification] = PermissionStatus.granted;
      await controller.checkPermissions();
      expect(controller.notificationsDenied, isFalse);
    });

    test('refreshPermissions starts Bluetooth once the permissions were '
        'granted in system settings', () async {
      registerNativeHandler();
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.permanentlyDenied;
      final controller = BleAppController();
      await controller.initialize();
      expect(nativeCalls, isEmpty);

      permissions.checkResult = PermissionStatus.granted;
      await controller.refreshPermissions();
      expect(controller.permissionsGranted, isTrue);
      expect(nativeCalls.where((call) => call.method == 'initialize'), hasLength(1));

      // Already running: coming back again doesn't replay the saved state.
      await controller.refreshPermissions();
      expect(nativeCalls.where((call) => call.method == 'initialize'), hasLength(1));
    });

    test('refreshPermissions leaves a pending request to its caller', () async {
      registerNativeHandler();
      permissions
        ..checkResult = PermissionStatus.denied
        ..requestResult = PermissionStatus.denied
        ..requestGate = Completer<void>();
      final controller = BleAppController();

      // The permission dialog pauses the app, and it resumes before the
      // request returns.
      final request = controller.requestPermissions();
      await pumpEventQueue();
      permissions.checkResult = PermissionStatus.granted;
      await controller.refreshPermissions();
      expect(controller.permissionsGranted, isFalse);
      expect(nativeCalls, isEmpty);

      permissions.requestGate!.complete();
      expect(await request, isFalse);
    });
  });
}
