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
