import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _bleChannelName =
    'com.rouddy.bluetooth_communicator/bluetooth_control';
const String _bleEventsChannelName =
    'com.rouddy.bluetooth_communicator/bluetooth_events';
const String _prefsAdvertisingEnabled = 'prefs_advertising_enabled';
const String _prefsCentralEnabled = 'prefs_central_enabled';
const String _prefsDeviceName = 'prefs_device_name';
const String _prefsPairingLost = 'prefs_pairing_lost';

/// Keys that are no longer used, deleted on launch: the removed chat's message
/// history and unread counts, and the registered devices, which native code
/// now keeps (as app-paired peers).
const List<String> _obsoletePrefs = [
  'prefs_messages',
  'prefs_unread_counts',
  'prefs_registered_devices',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = BleAppController();
  // Render first: initialize() waits on the permission dialog and native code,
  // and neither should keep the app on the splash screen.
  runApp(MyApp(controller: controller));
  unawaited(controller.initialize());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.controller});

  final BleAppController controller;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _errors;
  StreamSubscription<PairingRequest>? _pairingPrompts;

  /// Devices whose pairing dialog is open, so a replayed request doesn't open a
  /// second one.
  final Set<String> _openPrompts = <String>{};

  @override
  void initState() {
    super.initState();
    // Errors used to show up only on the settings page; surface each one where the
    // user is, whatever page that is.
    _errors = widget.controller.errors.listen((message) {
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
    // Either phone can be asked to approve a pairing, whatever page is open.
    _pairingPrompts = widget.controller.pairingPrompts.listen(_showPairingDialog);
  }

  Future<void> _showPairingDialog(PairingRequest request) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !_openPrompts.add(request.deviceId)) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PairingDialog(
        controller: widget.controller,
        deviceId: request.deviceId,
      ),
    );
    _openPrompts.remove(request.deviceId);
  }

  @override
  void dispose() {
    _errors?.cancel();
    _pairingPrompts?.cancel();
    super.dispose();
  }

  // MaterialApp isn't rebuilt on controller changes (which used to rebuild the whole
  // app, including every route); each page listens to the controller itself.
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      navigatorKey: _navigatorKey,
      title: 'Bluetooth Communicator',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: HomePage(controller: controller),
    );
  }
}

/// Shows the confirmation code of an app pairing (docs/protocol.md 6.3) until
/// the user answers and the pairing ends; it closes itself when the request is
/// gone (paired, declined, timed out, or the link dropped).
class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.controller,
    required this.deviceId,
  });

  final BleAppController controller;
  final String deviceId;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final request = widget.controller.pairingRequests[widget.deviceId];
        if (request == null) {
          if (!_closing) {
            _closing = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).pop();
              }
            });
          }
          return const SizedBox.shrink();
        }
        return _buildDialog(context, request);
      },
    );
  }

  Widget _buildDialog(BuildContext context, PairingRequest request) {
    final name = request.name.isEmpty ? request.deviceId : request.name;
    return AlertDialog(
      title: Text(request.repair ? '다시 연결 요청' : '연결 요청'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            request.repair
                ? '$name와(과) 다시 연결합니다. 이전 연결 정보는 새로 바뀝니다.'
                : '$name와(과) 연결합니다.',
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              request.code,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('두 기기에 같은 코드가 표시되는지 확인하세요.'),
          if (request.approved) ...[
            const SizedBox(height: 16),
            const Row(
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('상대 기기의 승인을 기다리는 중…')),
              ],
            ),
          ],
        ],
      ),
      actions: request.approved
          ? const []
          : [
              TextButton(
                onPressed: () =>
                    widget.controller.respondPairing(widget.deviceId, false),
                child: const Text('거절'),
              ),
              FilledButton(
                onPressed: () =>
                    widget.controller.respondPairing(widget.deviceId, true),
                child: const Text('승인'),
              ),
            ],
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('기기 목록'),
        bottom: controller.initializing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(controller: controller),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (controller.bluetoothOff)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const ListTile(
                leading: Icon(Icons.bluetooth_disabled),
                title: Text('Bluetooth가 꺼져 있습니다'),
                subtitle: Text('Bluetooth를 켜면 광고와 연결을 자동으로 다시 시작합니다.'),
              ),
            ),
          Expanded(child: DeviceListPage(controller: controller)),
        ],
      ),
    );
  }
}

class DeviceListPage extends StatelessWidget {
  const DeviceListPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.allKnownDevices;
    final knownIds = devices.map((d) => d.identifier).toSet();
    final nearbyDevices = controller.discoveredDevices
        .where((d) => !knownIds.contains(d.identifier))
        .toList();
    if (devices.isEmpty && nearbyDevices.isEmpty) {
      return const Center(child: Text('연결 기록이 있는 기기가 없습니다.'));
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (devices.isNotEmpty) const _SectionHeader('연결 기록'),
        ...devices.map((device) => _buildKnownTile(context, device)),
        if (nearbyDevices.isNotEmpty) const _SectionHeader('주변 기기'),
        ...nearbyDevices.map((device) => _buildNearbyTile(context, device)),
      ],
    );
  }

  Widget _buildKnownTile(BuildContext context, BleDevice device) {
    final isConnected = controller.connectedDeviceIds.contains(device.identifier);
    return ListTile(
      leading: Icon(
        isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
      ),
      title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
      subtitle: Text(
        '${controller.linkLabel(device.identifier)} · ${device.identifier}',
      ),
      onTap: () => _openDevice(context, device),
    );
  }

  Widget _buildNearbyTile(BuildContext context, BleDevice device) {
    return ListTile(
      leading: const Icon(Icons.bluetooth_searching),
      title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
      subtitle: Text(device.identifier),
      onTap: () => _openDevice(context, device),
    );
  }

  void _openDevice(BuildContext context, BleDevice device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceControlPage(controller: controller, device: device),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppLifecycleListener _lifecycleListener;

  BleAppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The permission tiles send the user to system settings; show what they
    // changed there when they come back.
    _lifecycleListener = AppLifecycleListener(
      onResume: controller.refreshPermissions,
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildPage(context),
    );
  }

  Future<void> _editDeviceName(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(initial: controller.deviceName),
    );
    if (name != null) {
      await controller.setDeviceName(name);
    }
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Bluetooth peripheral advertising'),
            subtitle: const Text('앱 재실행 시 자동 복원'),
            value: controller.advertisingEnabled,
            onChanged: controller.setAdvertisingEnabled,
          ),
          SwitchListTile(
            title: const Text('Bluetooth device scan 및 연결'),
            subtitle: const Text('앱 재실행 시 자동 복원'),
            value: controller.centralEnabled,
            onChanged: controller.setCentralEnabled,
          ),
          if (BleAppController.canSetDeviceName)
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('기기 이름'),
              subtitle: Text(
                controller.deviceName.isEmpty ? 'iPhone (기본값)' : controller.deviceName,
              ),
              onTap: () => _editDeviceName(context),
            ),
          ListTile(
            leading: const Icon(Icons.radar),
            title: const Text('즉시 스캔 실행'),
            onTap: controller.scanNow,
          ),
          if (controller.permissionsGranted) ...[
            const ListTile(
              leading: Icon(Icons.security),
              title: Text('권한'),
              subtitle: Text('Bluetooth 권한 허용됨'),
            ),
            if (controller.notificationsDenied)
              const ListTile(
                leading: Icon(Icons.notifications_off_outlined),
                title: Text('알림 설정 열기'),
                subtitle: Text('알림이 꺼져 있어 앱을 보고 있지 않을 때 온 요청을 알려줄 수 없습니다'),
                onTap: openAppSettings,
              ),
          ] else
            ListTile(
              leading: const Icon(Icons.security),
              title: Text(
                controller.permissionsPermanentlyDenied ? '권한 설정 열기' : '권한 요청',
              ),
              subtitle: Text(
                controller.permissionsPermanentlyDenied
                    ? '거부된 권한은 시스템 설정에서 허용해야 합니다'
                    : 'Bluetooth 및 알림 권한 허용',
              ),
              onTap: () async {
                // Re-check first: the user may have granted them in system settings.
                if (await controller.checkPermissions()) {
                  await controller.initialize();
                  return;
                }
                if (controller.permissionsPermanentlyDenied) {
                  await openAppSettings();
                  return;
                }
                if (await controller.requestPermissions()) {
                  await controller.initialize();
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Background 상태'),
            subtitle: Text(controller.backgroundStatus),
          ),
          if (controller.lastError != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('오류'),
              subtitle: Text(controller.lastError!),
              trailing: IconButton(
                tooltip: '오류 지우기',
                icon: const Icon(Icons.close),
                onPressed: controller.clearError,
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.initial});

  final String initial;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('기기 이름'),
      content: TextField(
        controller: _field,
        autofocus: true,
        maxLength: 30,
        decoration: const InputDecoration(hintText: 'iPhone'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class DeviceControlPage extends StatelessWidget {
  const DeviceControlPage({
    super.key,
    required this.controller,
    required this.device,
  });

  final BleAppController controller;
  final BleDevice device;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildPage(context),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('기기 삭제'),
        content: const Text(
          '연결 기록을 삭제하고 연결을 끊습니다. 상대 기기에도 연결 해제를 알립니다. '
          'Bluetooth 페어링 정보는 시스템 Bluetooth 설정에서 따로 해제해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await controller.removeDevice(device.identifier);
    if (!context.mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  Widget _linkButton() {
    return switch (controller.linkStateFor(device.identifier)) {
      LinkState.connected => const FilledButton.tonal(
        onPressed: null,
        child: Text('연결됨'),
      ),
      LinkState.connecting ||
      LinkState.bonding ||
      LinkState.awaitingApproval => const FilledButton.tonal(
        onPressed: null,
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      LinkState.disconnected || LinkState.pairingLost => FilledButton.tonal(
        onPressed: () => controller.connectDevice(device.identifier, pair: true),
        child: const Text('연결'),
      ),
    };
  }

  Widget _buildPage(BuildContext context) {
    final isConnected = controller.connectedDeviceIds.contains(device.identifier);
    final peerId = controller.peerFor(device.identifier)?.peerId;
    return Scaffold(
      appBar: AppBar(
        title: Text(device.name.isEmpty ? device.identifier : device.name),
        actions: [
          if (controller.isKnownDevice(device.identifier))
            IconButton(
              tooltip: '기기 삭제',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmRemove(context),
            ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            ),
            title: Text(controller.linkLabel(device.identifier)),
            subtitle: Text(device.identifier),
            trailing: _linkButton(),
          ),
          if (peerId != null)
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('Peer ID'),
              subtitle: Text(peerId),
            ),
        ],
      ),
    );
  }
}

class BleAppController extends ChangeNotifier {
  /// [clock] is for tests.
  BleAppController({DateTime Function()? clock})
      : _methodChannel = const MethodChannel(_bleChannelName),
        _eventChannel = const EventChannel(_bleEventsChannelName),
        _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// A nearby device is dropped when no scan result reported it for this long.
  /// Native code repeats each device every 30 s while it's still advertising.
  static const nearbyTimeout = Duration(seconds: 90);
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};
  Timer? _pruneTimer;

  /// Drops nearby devices that stopped advertising, e.g. an old random address of
  /// a phone that has since been paired under a new one.
  void pruneNearbyDevices() {
    final cutoff = _clock().subtract(nearbyTimeout);
    final before = discoveredDevices.length;
    discoveredDevices.removeWhere((device) {
      final seen = _lastSeen[device.identifier];
      return seen == null || seen.isBefore(cutoff);
    });
    _lastSeen.removeWhere((id, seen) => seen.isBefore(cutoff));
    if (discoveredDevices.isEmpty) {
      _pruneTimer?.cancel();
      _pruneTimer = null;
    }
    if (discoveredDevices.length != before) {
      notifyListeners();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  StreamSubscription<dynamic>? _eventsSubscription;
  SharedPreferences? _prefs;

  bool advertisingEnabled = false;
  bool centralEnabled = false;

  /// The name peers see (HELLO, advertising). iOS only: since iOS 16 an app reads
  /// every phone's name as "iPhone", so the user sets one. Empty means the default.
  String deviceName = '';

  /// Whether this platform lets the user name the device ([deviceName]).
  static bool get canSetDeviceName => defaultTargetPlatform == TargetPlatform.iOS;
  /// The last native status; null until the first status event.
  BleStatus? status;

  /// [status] as text for the settings page, `unknown` before any status event.
  String get backgroundStatus => status?.label ?? 'unknown';
  /// The most recent error, shown on the settings page until cleared.
  String? lastError;
  final StreamController<String> _errors = StreamController<String>.broadcast();

  /// Each error as it happens, for transient UI (a SnackBar).
  Stream<String> get errors => _errors.stream;

  void _reportError(String message) {
    lastError = message;
    _errors.add(message);
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }
  bool initializing = false;

  bool get bluetoothOff => status?.bluetoothOn == false;
  bool permissionsGranted = false;
  bool permissionsPermanentlyDenied = false;

  /// Whether the user turned notifications off. Android only, and not part of
  /// [permissionsGranted]: without them the app still works, but the user
  /// isn't told about requests that arrive while it's in the background.
  bool notificationsDenied = false;
  bool _requestingPermissions = false;

  final List<BleDevice> discoveredDevices = <BleDevice>[];
  final List<BleDevice> registeredDevices = <BleDevice>[];
  final Set<String> connectedDeviceIds = <String>{};

  List<BleDevice> get allKnownDevices {
    final map = <String, BleDevice>{};
    for (final device in registeredDevices) {
      map[device.identifier] = device;
    }
    for (final id in connectedDeviceIds) {
      map[id] = map[id] ?? _deviceById(id);
    }
    final list = map.values.toList();
    list.sort((a, b) {
      final aConnected = connectedDeviceIds.contains(a.identifier);
      final bConnected = connectedDeviceIds.contains(b.identifier);
      if (aConnected != bConnected) {
        return aConnected ? -1 : 1;
      }
      return (a.name.isEmpty ? a.identifier : a.name).compareTo(
        b.name.isEmpty ? b.identifier : b.name,
      );
    });
    return list;
  }

  /// Permissions the native side needs before it can advertise, scan, or connect.
  static List<Permission> get _blePermissions =>
      defaultTargetPlatform == TargetPlatform.iOS
      ? const [Permission.bluetooth]
      : const [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ];

  /// iOS doesn't post notifications, so it never asks for them.
  static bool get _usesNotifications =>
      defaultTargetPlatform == TargetPlatform.android;

  Future<bool> checkPermissions() async {
    final statuses = await Future.wait(_blePermissions.map((p) => p.status));
    if (_usesNotifications) {
      notificationsDenied = !(await Permission.notification.status).isGranted;
    }
    // On Android, `status` reports a permanent denial as plain `denied` (only a
    // request reveals it), so keep an earlier permanent denial until granted.
    final wasPermanentlyDenied = permissionsPermanentlyDenied;
    _updatePermissionState(statuses);
    permissionsPermanentlyDenied =
        !permissionsGranted &&
        (permissionsPermanentlyDenied || wasPermanentlyDenied);
    notifyListeners();
    return permissionsGranted;
  }

  /// Requests the Bluetooth permissions, plus notifications on Android. The
  /// notification permission is optional: the foreground service runs without
  /// it, only its notification is hidden.
  Future<bool> requestPermissions() async {
    _requestingPermissions = true;
    try {
      final statuses = await [
        ..._blePermissions,
        if (_usesNotifications) Permission.notification,
      ].request();
      _updatePermissionState(
        _blePermissions.map((p) => statuses[p] ?? PermissionStatus.denied),
      );
      if (_usesNotifications) {
        notificationsDenied = statuses[Permission.notification]?.isGranted != true;
      }
    } finally {
      _requestingPermissions = false;
    }
    notifyListeners();
    return permissionsGranted;
  }

  /// Re-checks the permissions when the user may have changed them in system
  /// settings, and starts Bluetooth if they were granted there.
  Future<void> refreshPermissions() async {
    // A request in progress shows a system dialog, which pauses the app; its
    // caller handles the result.
    if (_requestingPermissions || initializing) {
      return;
    }
    final wasGranted = permissionsGranted;
    if (await checkPermissions() && !wasGranted) {
      await initialize();
    }
  }

  void _updatePermissionState(Iterable<PermissionStatus> statuses) {
    permissionsGranted = statuses.every((status) => status.isGranted);
    permissionsPermanentlyDenied = statuses.any(
      (status) => status.isPermanentlyDenied,
    );
  }

  /// Loads saved state, requests permissions, and replays the saved modes to
  /// native code. Runs after the first frame, so failures are reported through
  /// [lastError] instead of thrown.
  Future<void> initialize() async {
    if (initializing) {
      return;
    }
    initializing = true;
    notifyListeners();
    try {
      await _initialize();
    } catch (error) {
      _reportError('초기화 실패: $error');
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  Future<void> _initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _loadFromPrefs();

    await _eventsSubscription?.cancel();
    _eventsSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) {
        _reportError(error.toString());
        notifyListeners();
      },
    );
    final granted = await checkPermissions() || await requestPermissions();
    if (!granted) {
      _reportError('Bluetooth 권한이 없어 기기 검색과 연결을 할 수 없습니다.');
      notifyListeners();
      return;
    }
    lastError = null;
    await _invoke('initialize');
    if (canSetDeviceName && deviceName.isNotEmpty) {
      await _invoke('setDeviceName', {'name': deviceName});
    }
    if (advertisingEnabled) {
      await _invoke('setAdvertisingEnabled', {'enabled': true});
    }
    // Native code reconnects the app-paired peers itself, and replays them as a
    // `peers` event.
    if (centralEnabled) {
      await _invoke('setCentralEnabled', {'enabled': true});
      await _invoke('scanNow');
    }
    notifyListeners();
  }

  Future<void> setAdvertisingEnabled(bool enabled) async {
    advertisingEnabled = enabled;
    await _prefs?.setBool(_prefsAdvertisingEnabled, enabled);
    await _invoke('setAdvertisingEnabled', {'enabled': enabled});
    notifyListeners();
  }

  Future<void> setCentralEnabled(bool enabled) async {
    centralEnabled = enabled;
    await _prefs?.setBool(_prefsCentralEnabled, enabled);
    await _invoke('setCentralEnabled', {'enabled': enabled});
    if (enabled) {
      await _invoke('scanNow');
    }
    notifyListeners();
  }

  Future<void> scanNow() async {
    await _invoke('scanNow');
  }

  Future<void> setDeviceName(String name) async {
    deviceName = name.trim();
    await _prefs?.setString(_prefsDeviceName, deviceName);
    notifyListeners();
    await _invoke('setDeviceName', {'name': deviceName});
  }

  final Set<String> _connectingDeviceIds = <String>{};
  final Set<String> _bondingDeviceIds = <String>{};
  final Map<String, Timer> _connectTimeouts = <String, Timer>{};

  /// A user-initiated connect is shown as connecting for at most this long: a
  /// background connect to an out-of-range device never finishes on its own.
  static const connectingTimeout = Duration(seconds: 30);

  LinkState linkStateFor(String deviceId) {
    if (connectedDeviceIds.contains(deviceId)) {
      return LinkState.connected;
    }
    if (pairingRequests.containsKey(deviceId)) {
      return LinkState.awaitingApproval;
    }
    if (_bondingDeviceIds.contains(deviceId)) {
      return LinkState.bonding;
    }
    if (_connectingDeviceIds.contains(deviceId)) {
      return LinkState.connecting;
    }
    if (_pairingLostDeviceIds.contains(deviceId)) {
      return LinkState.pairingLost;
    }
    return LinkState.disconnected;
  }

  String linkLabel(String deviceId) => switch (linkStateFor(deviceId)) {
    LinkState.connected => '연결됨',
    LinkState.awaitingApproval => '승인 대기 중…',
    LinkState.bonding => '페어링 중…',
    LinkState.connecting => '연결 중…',
    LinkState.pairingLost => '페어링 해제됨',
    LinkState.disconnected => switch (peerFor(deviceId)?.state) {
      PeerState.repairNeeded => '다시 연결 필요',
      PeerState.badMac => '인증 실패',
      PeerState.unpairedByPeer => '상대가 연결을 해제함',
      _ => '연결 안 됨',
    },
  };

  /// The app-paired peer at [deviceId], if any.
  BleDevice? peerFor(String deviceId) {
    for (final device in registeredDevices) {
      if (device.identifier == deviceId && device.peerId != null) {
        return device;
      }
    }
    return null;
  }

  /// App pairings waiting for this user's answer (or, once approved, for the
  /// peer's), by device.
  final Map<String, PairingRequest> pairingRequests = <String, PairingRequest>{};
  final StreamController<PairingRequest> _pairingPrompts =
      StreamController<PairingRequest>.broadcast();

  /// Each new pairing request, to show its dialog.
  Stream<PairingRequest> get pairingPrompts => _pairingPrompts.stream;

  /// Answers the pairing request for [deviceId]. An approved request stays until
  /// the peer's user answers too (`pairingResult`).
  Future<void> respondPairing(String deviceId, bool accept) async {
    final request = pairingRequests[deviceId];
    if (request == null) {
      return;
    }
    if (accept) {
      request.approved = true;
    } else {
      pairingRequests.remove(deviceId);
    }
    notifyListeners();
    await _invoke('respondPairing', {'deviceId': deviceId, 'accept': accept});
  }

  /// Devices whose pairing was removed (on either phone). Their address belonged to
  /// that pairing, so they won't reconnect; they have to be paired again from the
  /// nearby list. Cleared when the device connects again.
  final Set<String> _pairingLostDeviceIds = <String>{};

  Future<void> _savePairingLost() async {
    await _prefs?.setStringList(_prefsPairingLost, _pairingLostDeviceIds.toList());
  }

  void _settleLink(String deviceId) {
    _connectingDeviceIds.remove(deviceId);
    _bondingDeviceIds.remove(deviceId);
    _connectTimeouts.remove(deviceId)?.cancel();
  }

  /// [pair] allows the native side to start bonding (system pairing dialog) when
  /// the device isn't bonded yet. Only pass it for user-initiated connects; those
  /// are also shown as connecting until the link is up, fails, or times out.
  Future<void> connectDevice(String deviceId, {bool pair = false}) async {
    if (pair && !connectedDeviceIds.contains(deviceId)) {
      _connectingDeviceIds.add(deviceId);
      _connectTimeouts.remove(deviceId)?.cancel();
      _connectTimeouts[deviceId] = Timer(connectingTimeout, () {
        _connectTimeouts.remove(deviceId);
        if (_connectingDeviceIds.remove(deviceId)) {
          notifyListeners();
        }
      });
      notifyListeners();
    }
    await _invoke('connectDevice', {'deviceId': deviceId, 'pair': pair});
  }

  /// Whether [deviceId] is registered or currently connected, i.e. listed under
  /// 연결 기록 and removable.
  bool isKnownDevice(String deviceId) =>
      connectedDeviceIds.contains(deviceId) ||
      registeredDevices.any((d) => d.identifier == deviceId);

  /// Forgets a device: native code tells the peer (UNPAIR), deletes the pairing
  /// key, so it's no longer connected automatically, and drops every link. An
  /// OS-level pairing stays; only the system Bluetooth settings can remove it.
  Future<void> removeDevice(String deviceId) async {
    registeredDevices.removeWhere((d) => d.identifier == deviceId);
    connectedDeviceIds.remove(deviceId);
    if (_pairingLostDeviceIds.remove(deviceId)) {
      unawaited(_savePairingLost());
    }
    notifyListeners();
    await _invoke('removeDevice', {'deviceId': deviceId});
  }

  Future<bool> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
      return true;
    } on PlatformException catch (error) {
      _reportError('${error.code}: ${error.message}');
    } on MissingPluginException {
      // The native side didn't register the channel or doesn't implement this
      // method. Report it instead of letting it escape (e.g. out of main()).
      _reportError('Native Bluetooth channel unavailable ($method)');
    }
    notifyListeners();
    return false;
  }

  BleDevice _deviceById(String deviceId) {
    for (final device in registeredDevices) {
      if (device.identifier == deviceId) {
        return device;
      }
    }
    for (final device in discoveredDevices) {
      if (device.identifier == deviceId) {
        return device;
      }
    }
    return BleDevice(identifier: deviceId, name: '');
  }

  void _upsertRegisteredDevice(BleDevice device) {
    final existing = registeredDevices.indexWhere(
      (d) => d.identifier == device.identifier,
    );
    if (existing >= 0) {
      registeredDevices[existing] = device;
    } else {
      registeredDevices.add(device);
    }
  }

  String _displayName(String deviceId, [String? name]) {
    final known = (name == null || name.isEmpty) ? _deviceById(deviceId).name : name;
    return known.isEmpty ? deviceId : known;
  }

  /// What to tell the user when an app pairing ends without success.
  static String? _pairingFailureMessage(String name, String result) => switch (result) {
    'paired' => null,
    'rejected' => '$name와(과)의 연결이 거절되었습니다.',
    'timeout' => '$name의 승인을 기다리는 시간이 지났습니다.',
    'cannotPrompt' => '$name에서 승인 화면을 띄울 수 없습니다. 상대 기기에서 앱을 열어 주세요.',
    'mismatch' || 'badMac' => '$name와(과)의 보안 확인에 실패했습니다.',
    'linkLost' => '$name와(과)의 연결이 끊어져 연결 승인을 마치지 못했습니다.',
    _ => '$name와(과)의 연결 승인에 실패했습니다 ($result).',
  };

  /// What to tell the user about a REJECT. Pairing failures come as
  /// `pairingResult`, and turning away an unknown phone is routine.
  static String? _rejectMessage(String name, String reason, bool byPeer) =>
      switch ((reason, byPeer)) {
        ('unknownPeer', true) => '$name에서 이 기기를 삭제했습니다. 다시 연결하려면 연결 버튼을 누르세요.',
        ('badMac', _) => '$name의 인증에 실패했습니다. 보안을 위해 자동으로 다시 연결하지 않습니다.',
        ('unsupportedVersion', _) => '$name의 앱 버전과 호환되지 않습니다.',
        _ => null,
      };

  void _handleEvent(dynamic data) {
    if (data is! Map) {
      return;
    }
    final event = Map<String, dynamic>.from(data.cast<String, dynamic>());
    switch (event['type']) {
      case 'status':
        status = BleStatus.fromEvent(event);
        break;
      case 'discovered':
        final device = BleDevice.fromMap(event);
        _lastSeen[device.identifier] = _clock();
        // Runs only while there's something to prune.
        _pruneTimer ??= Timer.periodic(
          const Duration(seconds: 15),
          (_) => pruneNearbyDevices(),
        );
        final index = discoveredDevices.indexWhere((d) => d.identifier == device.identifier);
        if (index >= 0) {
          discoveredDevices[index] = device;
        } else {
          discoveredDevices.add(device);
        }
        break;
      case 'connected':
        // A session with an app-paired peer; the name is the one it announced.
        final id = event['deviceId'] as String?;
        if (id != null) {
          _settleLink(id);
          if (_pairingLostDeviceIds.remove(id)) {
            unawaited(_savePairingLost());
          }
          connectedDeviceIds.add(id);
          final known = _deviceById(id);
          _upsertRegisteredDevice(
            BleDevice(
              identifier: id,
              name: event['name'] as String? ?? known.name,
              peerId: event['peerId'] as String? ?? known.peerId,
              state: PeerState.paired,
            ),
          );
        }
        break;
      case 'peers':
        // The app-paired peers native code keeps; the 연결 기록 list.
        final peers = (event['peers'] as List?)?.whereType<Map>() ?? const <Map>[];
        registeredDevices
          ..clear()
          ..addAll(peers.map((peer) => BleDevice.fromMap(peer.cast<String, dynamic>())));
        for (final peer in peers) {
          final id = peer['deviceId'];
          if (peer['connected'] == true && id is String) {
            connectedDeviceIds.add(id);
          }
        }
        break;
      case 'pairingRequest':
        if (event['deviceId'] case final String id) {
          // The connect timeout doesn't apply while the users decide.
          _connectTimeouts.remove(id)?.cancel();
          _bondingDeviceIds.remove(id);
          final isNew = !pairingRequests.containsKey(id);
          final request = PairingRequest(
            deviceId: id,
            peerId: event['peerId'] as String? ?? '',
            name: event['name'] as String? ?? '',
            code: event['code'] as String? ?? '',
            repair: event['repair'] == true,
          );
          if (!isNew) {
            request.approved = pairingRequests[id]!.approved;
          }
          pairingRequests[id] = request;
          _pairingPrompts.add(request);
        }
        break;
      case 'pairingResult':
        if (event['deviceId'] case final String id) {
          final request = pairingRequests.remove(id);
          final result = event['result'] as String? ?? '';
          if (result != 'paired') {
            _settleLink(id);
          }
          final message = _pairingFailureMessage(_displayName(id, request?.name), result);
          if (message != null) {
            _reportError(message);
          }
        }
        break;
      case 'peerRejected':
        if (event['deviceId'] case final String id) {
          _settleLink(id);
          final message = _rejectMessage(
            _displayName(id),
            event['reason'] as String? ?? '',
            event['byPeer'] == true,
          );
          if (message != null) {
            _reportError(message);
          }
        }
        break;
      case 'peerUnpaired':
        if (event['deviceId'] case final String id) {
          _reportError('${_displayName(id)}에서 연결을 해제했습니다.');
        }
        break;
      case 'disconnected':
        final id = event['deviceId'] as String?;
        if (id != null) {
          _settleLink(id);
          connectedDeviceIds.remove(id);
        }
        break;
      case 'bondLost':
        if (event['deviceId'] case final String id) {
          _settleLink(id);
          connectedDeviceIds.remove(id);
          _pairingLostDeviceIds.add(id);
          unawaited(_savePairingLost());
          final name = _deviceById(id).name;
          _reportError(
            '${name.isEmpty ? id : name}와(과)의 페어링이 해제되었습니다. '
            '주변 기기 목록에서 다시 연결해 주세요.',
          );
        }
        break;
      case 'bonding':
        // Android only: the system pairing dialog is up for this device.
        if (event['deviceId'] case final String id) {
          _bondingDeviceIds.add(id);
        }
        break;
      case 'error':
        if (event['message'] case final String message) {
          _reportError(message);
        }
        break;
      case 'log':
        // Native protocol and Bluetooth decisions, for debugging on a device.
        if (!kReleaseMode && event['message'] is String) {
          debugPrint('[native] ${event['message']}');
        }
        return;
      default:
        break;
    }
    notifyListeners();
  }

  void _loadFromPrefs() {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    advertisingEnabled = prefs.getBool(_prefsAdvertisingEnabled) ?? false;
    centralEnabled = prefs.getBool(_prefsCentralEnabled) ?? false;
    deviceName = prefs.getString(_prefsDeviceName) ?? '';
    // initialize() can run again (permission retry); the in-memory state is newer
    // than what's stored by then.
    if (!_stateLoaded) {
      _stateLoaded = true;
      _pairingLostDeviceIds.addAll(prefs.getStringList(_prefsPairingLost) ?? const []);
      for (final key in _obsoletePrefs) {
        unawaited(prefs.remove(key));
      }
    }
  }

  bool _stateLoaded = false;

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _pruneTimer?.cancel();
    _errors.close();
    _pairingPrompts.close();
    for (final timer in _connectTimeouts.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

class BleDevice {
  BleDevice({
    required this.identifier,
    required this.name,
    this.peerId,
    this.state,
  });

  final String identifier;
  final String name;

  /// The peer's install id, for app-paired peers (docs/protocol.md 2절).
  final String? peerId;

  /// Null for nearby devices that aren't app-paired.
  final PeerState? state;

  factory BleDevice.fromMap(Map<String, dynamic> map) {
    return BleDevice(
      identifier: (map['deviceId'] ?? map['identifier'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      peerId: map['peerId'] as String?,
      state: PeerState.values.asNameMap()[map['state']],
    );
  }
}

/// An app-paired peer's state (`peers` event).
enum PeerState {
  paired,

  /// The peer answered that it doesn't know this phone (it deleted it, or the
  /// app was reinstalled); the 연결 button pairs again.
  repairNeeded,

  /// The peer's authentication failed; not reconnected automatically.
  badMac,

  /// The peer deleted this phone.
  unpairedByPeer,
}

/// A `pairingRequest` event: both phones show [code] until both users approve.
class PairingRequest {
  PairingRequest({
    required this.deviceId,
    required this.peerId,
    required this.name,
    required this.code,
    required this.repair,
  });

  final String deviceId;
  final String peerId;
  final String name;
  final String code;

  /// The peer was app-paired before (it was deleted or reinstalled).
  final bool repair;

  /// This user approved; waiting for the peer's.
  bool approved = false;
}

/// The `status` event both native sides send whenever their state changes.
class BleStatus {
  const BleStatus({
    required this.advertising,
    required this.scanning,
    required this.connectedCount,
    required this.bluetoothOn,
  });

  factory BleStatus.fromEvent(Map<String, dynamic> event) => BleStatus(
    advertising: event['advertising'] == true,
    scanning: event['scanning'] == true,
    connectedCount: event['connectedCount'] as int? ?? 0,
    bluetoothOn: event['bluetoothOn'] != false,
  );

  final bool advertising;
  final bool scanning;

  /// Distinct peers with at least one link (as central or peripheral).
  final int connectedCount;
  final bool bluetoothOn;

  /// e.g. `advertising scanning connected:1`, `idle`, or `bluetooth-off`.
  String get label {
    if (!bluetoothOn) {
      return 'bluetooth-off';
    }
    final parts = [
      if (advertising) 'advertising',
      if (scanning) 'scanning',
      if (connectedCount > 0) 'connected:$connectedCount',
    ];
    return parts.isEmpty ? 'idle' : parts.join(' ');
  }
}

enum LinkState {
  disconnected,
  connecting,
  bonding,

  /// The app pairing's confirmation code is up, waiting for the users.
  awaitingApproval,
  connected,
  pairingLost,
}
