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
