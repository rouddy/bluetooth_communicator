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
    test('replays saved modes and registered devices to native code', () async {
      registerNativeHandler();
      SharedPreferences.setMockInitialValues({
        'prefs_advertising_enabled': true,
        'prefs_central_enabled': true,
        'prefs_registered_devices':
            '[{"identifier":"AA:BB:CC:DD:EE:FF","name":"peer"}]',
      });
      final controller = BleAppController();

      await controller.initialize();

      expect(nativeCalls.map((c) => c.method), [
        'initialize',
        'setAdvertisingEnabled',
        'setCentralEnabled',
        'scanNow',
        'connectDevice',
      ]);
      // Replaying saved devices must never trigger the pairing dialog.
      final connectArgs = nativeCalls.last.arguments as Map;
      expect(connectArgs['deviceId'], 'AA:BB:CC:DD:EE:FF');
      expect(connectArgs['pair'], isNot(true));
      expect(controller.lastError, isNull);
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

  group('sendMessage', () {
    Future<void> nativeEvent(Map<String, dynamic> event) {
      return messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    test('shows the message as sending until native code reports the '
        'outcome', () async {
      registerNativeHandler();
      final controller = BleAppController();
      await controller.initialize();

      await controller.sendMessage('AA:AA', 'first');
      await controller.sendMessage('AA:AA', 'second');
      final [first, second] = controller.messagesByDevice['AA:AA']!;
      expect([first.status, second.status], [
        MessageStatus.sending,
        MessageStatus.sending,
      ]);
      final sendCall = nativeCalls.lastWhere((c) => c.method == 'sendMessage');
      expect(sendCall.arguments, {
        'deviceId': 'AA:AA',
        'message': 'second',
        'messageId': second.id,
      });
      expect(first.id, isNot(second.id));

      await nativeEvent({
        'type': 'messageFailed',
        'deviceId': 'AA:AA',
        'messageId': second.id,
        'error': 'Write failed (status 133)',
      });
      await nativeEvent({
        'type': 'messageSent',
        'deviceId': 'AA:AA',
        'messageId': first.id,
      });

      expect(first.status, MessageStatus.sent);
      expect(first.statusLabel, 'Sent');
      expect(second.status, MessageStatus.failed);
      expect(second.statusLabel, '전송 실패: Write failed (status 133)');
    });

    test('fails the message when native code rejects the call', () async {
      messenger.setMockMethodCallHandler(_controlChannel, (call) async {
        if (call.method == 'sendMessage') {
          throw PlatformException(
            code: 'SERVICE_UNAVAILABLE',
            message: 'Bluetooth service unavailable',
          );
        }
        return null;
      });
      final controller = BleAppController();
      await controller.initialize();

      await controller.sendMessage('AA:AA', 'hello');

      final message = controller.messagesByDevice['AA:AA']!.single;
      expect(message.status, MessageStatus.failed);
      expect(message.error, contains('Bluetooth service unavailable'));
    });
  });

  test('a message delivered late keeps the time it arrived natively', () async {
    registerNativeHandler();
    final controller = BleAppController();
    await controller.initialize();
    final arrived = DateTime(2026, 10, 15, 16, 3, 53);

    await messenger.handlePlatformMessage(
      _eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'message',
        'deviceId': 'AA:AA',
        'message': 'while closed',
        'receivedAt': arrived.millisecondsSinceEpoch,
      }),
      (_) {},
    );

    final message = controller.messagesByDevice['AA:AA']!.single;
    expect(message.text, 'while closed');
    expect(message.timestamp, arrived);
    expect(controller.unreadCountFor('AA:AA'), 1);
  });

  group('message history', () {
    Future<void> incoming(String deviceId, String text) {
      return messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'message',
          'deviceId': deviceId,
          'message': text,
        }),
        (_) {},
      );
    }

    test('survives a restart, including unread counts and send status', () async {
      registerNativeHandler();
      final first = BleAppController();
      await first.initialize();
      await incoming('AA:AA', 'hi');
      await first.sendMessage('AA:AA', 'reply');
      final reply = first.messagesByDevice['AA:AA']!.last;
      await messenger.handlePlatformMessage(
        _eventsChannel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'messageSent',
          'deviceId': 'AA:AA',
          'messageId': reply.id,
        }),
        (_) {},
      );
      await pumpEventQueue();

      // A new controller over the same storage, like the next app launch.
      final restarted = BleAppController();
      await restarted.initialize();

      final messages = restarted.messagesByDevice['AA:AA']!;
      expect(messages.map((m) => (m.text, m.outgoing, m.status)), [
        ('hi', false, MessageStatus.sent),
        ('reply', true, MessageStatus.sent),
      ]);
      expect(messages.last.id, reply.id);
      expect(restarted.unreadCountFor('AA:AA'), 1);
    });

    test('a message still being sent when the app stopped comes back as '
        'failed', () async {
      registerNativeHandler();
      final first = BleAppController();
      await first.initialize();
      await first.sendMessage('AA:AA', 'in flight');
      await pumpEventQueue();

      final restarted = BleAppController();
      await restarted.initialize();

      final message = restarted.messagesByDevice['AA:AA']!.single;
      expect(message.status, MessageStatus.failed);
      expect(message.statusLabel, contains('전송 결과를 알 수 없습니다'));
    });

    test('keeps only the newest messages per device', () async {
      registerNativeHandler();
      final first = BleAppController();
      await first.initialize();
      for (var i = 0; i < 205; i++) {
        await incoming('AA:AA', 'm$i');
      }
      await pumpEventQueue();

      final restarted = BleAppController();
      await restarted.initialize();

      final texts = restarted.messagesByDevice['AA:AA']!.map((m) => m.text);
      expect(texts.length, 200);
      expect(texts.first, 'm5');
      expect(texts.last, 'm204');
    });

    test('deleting a device also deletes its stored messages', () async {
      registerNativeHandler();
      final first = BleAppController();
      await first.initialize();
      await incoming('AA:AA', 'hi');
      await first.removeDevice('AA:AA');
      await pumpEventQueue();

      final restarted = BleAppController();
      await restarted.initialize();

      expect(restarted.messagesByDevice['AA:AA'], isNull);
      expect(restarted.unreadCountFor('AA:AA'), 0);
    });
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
    test('forgets the device, persists it, and disconnects it natively', () async {
      registerNativeHandler();
      SharedPreferences.setMockInitialValues({
        'prefs_registered_devices':
            '[{"identifier":"AA:AA","name":"keep"},'
            '{"identifier":"BB:BB","name":"remove"}]',
      });
      final controller = BleAppController();
      await controller.initialize();
      final events = <Map<String, dynamic>>[
        {'type': 'connected', 'deviceId': 'BB:BB'},
        {'type': 'message', 'deviceId': 'BB:BB', 'message': 'hi'},
      ];
      for (final event in events) {
        await messenger.handlePlatformMessage(
          _eventsChannel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) {},
        );
      }
      expect(controller.isKnownDevice('BB:BB'), isTrue);
      expect(controller.unreadCountFor('BB:BB'), 1);
      nativeCalls.clear();

      await controller.removeDevice('BB:BB');

      expect(controller.isKnownDevice('BB:BB'), isFalse);
      expect(controller.allKnownDevices.map((d) => d.identifier), ['AA:AA']);
      expect(controller.messagesByDevice['BB:BB'], isNull);
      expect(controller.unreadCountFor('BB:BB'), 0);
      expect(nativeCalls.single.method, 'disconnectDevice');
      expect(nativeCalls.single.arguments, {'deviceId': 'BB:BB'});
      // The Android service reads this list to decide what to reconnect.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs_registered_devices'), isNot(contains('BB:BB')));
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
  });
}
