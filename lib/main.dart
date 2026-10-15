import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

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
const String _prefsRegisteredDevices = 'prefs_registered_devices';
const String _prefsMessages = 'prefs_messages';
const String _prefsUnreadCounts = 'prefs_unread_counts';

/// Longest message, in UTF-8 bytes, that can be sent: a GATT attribute value holds
/// at most 512 bytes. Notifications are further limited by the link's MTU (514
/// bytes with the 517 MTU the app negotiates); native code rejects those.
const int maxMessageBytes = 512;

/// Messages kept per device in [_prefsMessages]; older ones are dropped.
const int _storedMessagesPerDevice = 200;

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
  StreamSubscription<String>? _errors;

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
  }

  @override
  void dispose() {
    _errors?.cancel();
    super.dispose();
  }

  // MaterialApp isn't rebuilt on controller changes (which used to rebuild the whole
  // app, including every route); each page listens to the controller itself.
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      title: 'Bluetooth Communicator',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: HomePage(controller: controller),
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
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationPage(controller: controller),
                ),
              );
            },
          ),
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
    final unreadCount = controller.unreadCountFor(device.identifier);
    return ListTile(
      leading: Icon(
        isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
      ),
      title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
      subtitle: Text(
        '${controller.linkLabel(device.identifier)} · ${device.identifier}',
      ),
      trailing: unreadCount > 0
          ? Badge(
              label: Text(unreadCount.toString()),
              child: const Icon(Icons.mark_chat_unread_outlined),
            )
          : null,
      onTap: () {
        controller.clearUnreadForDevice(device.identifier);
        _openDevice(context, device);
      },
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

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

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
          ListTile(
            leading: const Icon(Icons.radar),
            title: const Text('즉시 스캔 실행'),
            onTap: controller.scanNow,
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: Text(
              controller.permissionsPermanentlyDenied ? '권한 설정 열기' : '권한 요청',
            ),
            subtitle: Text(
              controller.permissionsGranted
                  ? 'Bluetooth 권한 허용됨'
                  : controller.permissionsPermanentlyDenied
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

class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final unreadDevices = controller.devicesWithUnreadMessages;
    final history = controller.messageHistory;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('읽지 않은 기기', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (unreadDevices.isEmpty)
            const Text('읽지 않은 메시지가 없습니다.')
          else
            ...unreadDevices.map(
              (device) => Card(
                child: ListTile(
                  title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
                  subtitle: Text(device.identifier),
                  trailing: Badge(
                    label: Text(
                      controller.unreadCountFor(device.identifier).toString(),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('Message history', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (history.isEmpty)
            const Text('메시지 기록이 없습니다.')
          else
            ...history.map(
              (entry) => ListTile(
                dense: true,
                title: Text(entry.message.text),
                subtitle: Text(
                  '${entry.deviceName.isEmpty ? entry.deviceId : entry.deviceName} · ${entry.message.timestamp.toLocal()}',
                ),
                trailing: Text(
                  !entry.message.outgoing
                      ? 'Recv'
                      : switch (entry.message.status) {
                          MessageStatus.sending => '전송 중',
                          MessageStatus.sent => 'Sent',
                          MessageStatus.failed => '실패',
                        },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DeviceControlPage extends StatefulWidget {
  const DeviceControlPage({
    super.key,
    required this.controller,
    required this.device,
  });

  final BleAppController controller;
  final BleDevice device;

  @override
  State<DeviceControlPage> createState() => _DeviceControlPageState();
}

class _DeviceControlPageState extends State<DeviceControlPage>
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
    widget.controller.openChat(widget.device.identifier);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Messages that arrived while the app was in the background were counted as
    // unread; the user is looking at them now.
    if (state == AppLifecycleState.resumed) {
      widget.controller.clearUnreadForDevice(widget.device.identifier);
    }
  }

  void _onControllerUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.closeChat(widget.device.identifier);
    widget.controller.removeListener(_onControllerUpdate);
    _textController.dispose();
    super.dispose();
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('기기 삭제'),
        content: const Text(
          '연결 기록과 메시지를 삭제하고 연결을 끊습니다. '
          '페어링 정보는 시스템 Bluetooth 설정에서 따로 해제해야 합니다.',
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
    await widget.controller.removeDevice(widget.device.identifier);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = widget.controller.connectedDeviceIds.contains(
      widget.device.identifier,
    );
    final messages =
        widget.controller.messagesByDevice[widget.device.identifier] ??
        <BleMessage>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name.isEmpty ? widget.device.identifier : widget.device.name),
        actions: [
          if (widget.controller.isKnownDevice(widget.device.identifier))
            IconButton(
              tooltip: '기기 삭제',
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmRemove,
            ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            leading: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            ),
            title: Text(widget.controller.linkLabel(widget.device.identifier)),
            subtitle: Text(widget.device.identifier),
            trailing: switch (widget.controller.linkStateFor(
              widget.device.identifier,
            )) {
              LinkState.connected => const FilledButton.tonal(
                onPressed: null,
                child: Text('연결됨'),
              ),
              LinkState.connecting || LinkState.bonding => const FilledButton.tonal(
                onPressed: null,
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              LinkState.disconnected => FilledButton.tonal(
                onPressed: () {
                  widget.controller.connectDevice(
                    widget.device.identifier,
                    pair: true,
                  );
                },
                child: const Text('연결'),
              ),
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[messages.length - 1 - index];
                final failed = message.status == MessageStatus.failed;
                return ListTile(
                  title: Text(message.text),
                  subtitle: Text(
                    '${message.statusLabel} · ${message.timestamp.toLocal()}',
                    style: failed
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  trailing: switch (message.status) {
                    MessageStatus.sending => const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    MessageStatus.failed => Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    MessageStatus.sent => null,
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (context, value, _) {
                  final text = value.text.trim();
                  final bytes = utf8.encode(text).length;
                  final tooLong = bytes > maxMessageBytes;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            hintText: '메시지 입력',
                            // Shown close to the limit, so it doesn't come as a surprise.
                            counterText: bytes > maxMessageBytes * 0.8
                                ? '$bytes/$maxMessageBytes bytes'
                                : null,
                            errorText: tooLong ? '메시지가 너무 깁니다' : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: text.isEmpty || tooLong
                            ? null
                            : () async {
                                final message = _textController.text.trim();
                                _textController.clear();
                                await widget.controller.sendMessage(
                                  widget.device.identifier,
                                  message,
                                );
                              },
                        icon: const Icon(Icons.send),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BleAppController extends ChangeNotifier {
  BleAppController()
      : _methodChannel = const MethodChannel(_bleChannelName),
        _eventChannel = const EventChannel(_bleEventsChannelName);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  StreamSubscription<dynamic>? _eventsSubscription;
  SharedPreferences? _prefs;

  bool advertisingEnabled = false;
  bool centralEnabled = false;
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

  final List<BleDevice> discoveredDevices = <BleDevice>[];
  final List<BleDevice> registeredDevices = <BleDevice>[];
  final Set<String> connectedDeviceIds = <String>{};
  final Map<String, List<BleMessage>> messagesByDevice = <String, List<BleMessage>>{};
  final Map<String, int> unreadCountByDevice = <String, int>{};

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

  List<BleDevice> get devicesWithUnreadMessages {
    return allKnownDevices
        .where((device) => (unreadCountByDevice[device.identifier] ?? 0) > 0)
        .toList();
  }

  List<MessageHistoryEntry> get messageHistory {
    final history = <MessageHistoryEntry>[];
    messagesByDevice.forEach((deviceId, messages) {
      final device = _deviceById(deviceId);
      for (final message in messages) {
        history.add(
          MessageHistoryEntry(
            deviceId: deviceId,
            deviceName: device.name,
            message: message,
          ),
        );
      }
    });
    history.sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    return history;
  }

  /// Permissions the native side needs before it can advertise, scan, or connect.
  static List<Permission> get _blePermissions => Platform.isIOS
      ? const [Permission.bluetooth]
      : const [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ];

  Future<bool> checkPermissions() async {
    final statuses = await Future.wait(_blePermissions.map((p) => p.status));
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
    final statuses = await [
      ..._blePermissions,
      if (Platform.isAndroid) Permission.notification,
    ].request();
    _updatePermissionState(
      _blePermissions.map((p) => statuses[p] ?? PermissionStatus.denied),
    );
    notifyListeners();
    return permissionsGranted;
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
    if (advertisingEnabled) {
      await _invoke('setAdvertisingEnabled', {'enabled': true});
    }
    if (centralEnabled) {
      await _invoke('setCentralEnabled', {'enabled': true});
      await _invoke('scanNow');
      for (final device in registeredDevices) {
        await _invoke('connectDevice', {'deviceId': device.identifier});
      }
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
    if (_bondingDeviceIds.contains(deviceId)) {
      return LinkState.bonding;
    }
    if (_connectingDeviceIds.contains(deviceId)) {
      return LinkState.connecting;
    }
    return LinkState.disconnected;
  }

  String linkLabel(String deviceId) => switch (linkStateFor(deviceId)) {
    LinkState.connected => '연결됨',
    LinkState.bonding => '페어링 중…',
    LinkState.connecting => '연결 중…',
    LinkState.disconnected => '연결 안 됨',
  };

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

  /// Forgets a device: it leaves the registered list (so it's no longer
  /// connected automatically), its messages are cleared, and any live link is
  /// dropped. An OS-level pairing stays; only the system Bluetooth settings can
  /// remove it. If the peer connects to us again, it gets registered again.
  Future<void> removeDevice(String deviceId) async {
    registeredDevices.removeWhere((d) => d.identifier == deviceId);
    connectedDeviceIds.remove(deviceId);
    messagesByDevice.remove(deviceId);
    unreadCountByDevice.remove(deviceId);
    _messagesChanged();
    // Save before disconnecting: the Android service reads this list to decide
    // whether to reconnect a dropped device.
    await _saveRegisteredDevices();
    notifyListeners();
    await _invoke('disconnectDevice', {'deviceId': deviceId});
  }

  Future<void> registerDevice(BleDevice device) async {
    _upsertRegisteredDevice(device);
    await _saveRegisteredDevices();
    notifyListeners();
  }

  int _messageCounter = 0;

  /// Shows the message right away as [MessageStatus.sending]; the native
  /// messageSent/messageFailed event for its id settles the status.
  Future<void> sendMessage(String deviceId, String text) async {
    final message = BleMessage(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_messageCounter++}',
      text: text,
      timestamp: DateTime.now(),
      outgoing: true,
      status: MessageStatus.sending,
    );
    _appendMessage(deviceId, message);
    _messagesChanged();
    notifyListeners();
    final accepted = await _invoke('sendMessage', {
      'deviceId': deviceId,
      'message': text,
      'messageId': message.id,
    });
    if (!accepted && message.status == MessageStatus.sending) {
      message
        ..status = MessageStatus.failed
        ..error = lastError;
      _messagesChanged();
      notifyListeners();
    }
  }

  void _settleMessage(Map<String, dynamic> event, MessageStatus status) {
    final messageId = event['messageId'] as String?;
    final candidates = switch (event['deviceId'] as String?) {
      final String deviceId => messagesByDevice[deviceId] ?? const <BleMessage>[],
      null => messagesByDevice.values.expand((messages) => messages),
    };
    for (final message in candidates) {
      if (message.outgoing && message.id == messageId) {
        message
          ..status = status
          ..error = event['error'] as String?;
        _messagesChanged();
        return;
      }
    }
  }

  String? _openChatDeviceId;

  /// Called by the chat page while it's open. Its messages don't count as unread
  /// while the app is in the foreground. Doesn't notify listeners (it's called
  /// from initState); opening a chat from the list clears the unread count.
  void openChat(String deviceId) => _openChatDeviceId = deviceId;

  void closeChat(String deviceId) {
    if (_openChatDeviceId == deviceId) {
      _openChatDeviceId = null;
    }
  }

  bool _isBeingRead(String deviceId) {
    final state = WidgetsBinding.instance.lifecycleState;
    return deviceId == _openChatDeviceId &&
        (state == null || state == AppLifecycleState.resumed);
  }

  void clearUnreadForDevice(String deviceId) {
    if ((unreadCountByDevice[deviceId] ?? 0) == 0) {
      return;
    }
    unreadCountByDevice.remove(deviceId);
    _messagesChanged();
    notifyListeners();
  }

  int unreadCountFor(String deviceId) => unreadCountByDevice[deviceId] ?? 0;

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

  void _appendMessage(String deviceId, BleMessage message) {
    final messages = messagesByDevice.putIfAbsent(deviceId, () => <BleMessage>[]);
    messages.add(message);
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
        final index = discoveredDevices.indexWhere((d) => d.identifier == device.identifier);
        if (index >= 0) {
          discoveredDevices[index] = device;
        } else {
          discoveredDevices.add(device);
        }
        break;
      case 'connected':
        final id = event['deviceId'] as String?;
        if (id != null) {
          _settleLink(id);
          connectedDeviceIds.add(id);
          _upsertRegisteredDevice(_deviceById(id));
          unawaited(_saveRegisteredDevices());
        }
        break;
      case 'disconnected':
        final id = event['deviceId'] as String?;
        if (id != null) {
          _settleLink(id);
          connectedDeviceIds.remove(id);
        }
        break;
      case 'bonding':
        // Android only: the system pairing dialog is up for this device.
        if (event['deviceId'] case final String id) {
          _bondingDeviceIds.add(id);
        }
        break;
      case 'message':
        final id = event['deviceId'] as String?;
        final message = event['message'] as String?;
        if (id != null && message != null) {
          // Messages that waited natively while no listener was attached carry the
          // time they actually arrived.
          final receivedAt = event['receivedAt'] as int?;
          _appendMessage(
            id,
            BleMessage(
              text: message,
              timestamp: receivedAt == null
                  ? DateTime.now()
                  : DateTime.fromMillisecondsSinceEpoch(receivedAt),
              outgoing: false,
            ),
          );
          if (!_isBeingRead(id)) {
            unreadCountByDevice[id] = (unreadCountByDevice[id] ?? 0) + 1;
          }
          _messagesChanged();
        }
        break;
      case 'messageSent':
        _settleMessage(event, MessageStatus.sent);
        break;
      case 'messageFailed':
        _settleMessage(event, MessageStatus.failed);
        break;
      case 'error':
        if (event['message'] case final String message) {
          _reportError(message);
        }
        break;
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
    final jsonText = prefs.getString(_prefsRegisteredDevices);
    if (jsonText != null) {
      final raw = jsonDecode(jsonText);
      if (raw is List) {
        registeredDevices
          ..clear()
          ..addAll(
            raw
                .whereType<Map>()
                .map((item) => BleDevice.fromMap(item.cast<String, dynamic>())),
          );
      }
    }
    // initialize() can run again (permission retry); the in-memory history is newer
    // than what's stored by then, and may hold messages still being sent.
    if (!_messagesLoaded) {
      _messagesLoaded = true;
      _loadMessages(prefs);
    }
  }

  bool _messagesLoaded = false;

  void _loadMessages(SharedPreferences prefs) {
    final messagesJson = prefs.getString(_prefsMessages);
    if (messagesJson != null) {
      final raw = jsonDecode(messagesJson);
      if (raw is Map) {
        raw.forEach((deviceId, items) {
          if (deviceId is! String || items is! List) {
            return;
          }
          messagesByDevice[deviceId] = [
            for (final item in items.whereType<Map>())
              BleMessage.fromJson(item.cast<String, dynamic>()),
          ];
        });
      }
    }
    final unreadJson = prefs.getString(_prefsUnreadCounts);
    if (unreadJson != null) {
      final raw = jsonDecode(unreadJson);
      if (raw is Map) {
        raw.forEach((deviceId, count) {
          if (deviceId is String && count is int) {
            unreadCountByDevice[deviceId] = count;
          }
        });
      }
    }
  }

  void _messagesChanged() => unawaited(_saveMessages());

  Future<void> _saveMessages() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(
      _prefsMessages,
      jsonEncode({
        for (final MapEntry(key: deviceId, value: messages)
            in messagesByDevice.entries)
          deviceId: [
            for (final message in messages.length > _storedMessagesPerDevice
                ? messages.sublist(messages.length - _storedMessagesPerDevice)
                : messages)
              message.toJson(),
          ],
      }),
    );
    await prefs.setString(_prefsUnreadCounts, jsonEncode(unreadCountByDevice));
  }

  Future<void> _saveRegisteredDevices() async {
    await _prefs?.setString(
      _prefsRegisteredDevices,
      jsonEncode(registeredDevices.map((d) => d.toMap()).toList()),
    );
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _errors.close();
    for (final timer in _connectTimeouts.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

class BleDevice {
  BleDevice({required this.identifier, required this.name});

  final String identifier;
  final String name;

  factory BleDevice.fromMap(Map<String, dynamic> map) {
    return BleDevice(
      identifier: (map['deviceId'] ?? map['identifier'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'identifier': identifier,
        'name': name,
      };
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

enum LinkState { disconnected, connecting, bonding, connected }

enum MessageStatus {
  /// Handed to native code, waiting for its messageSent/messageFailed event.
  sending,

  /// Accepted by the peer's stack (write response or notification sent).
  /// Received messages are always in this state.
  sent,
  failed,
}

class BleMessage {
  BleMessage({
    required this.text,
    required this.timestamp,
    required this.outgoing,
    this.id = '',
    this.status = MessageStatus.sent,
    this.error,
  });

  /// Restores a stored message. One stored while it was still being sent comes
  /// back as failed: the app stopped before native code reported the outcome.
  factory BleMessage.fromJson(Map<String, dynamic> json) {
    final status = MessageStatus.values.asNameMap()[json['status']] ??
        MessageStatus.sent;
    final interrupted = status == MessageStatus.sending;
    return BleMessage(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int? ?? 0),
      outgoing: json['outgoing'] as bool? ?? false,
      status: interrupted ? MessageStatus.failed : status,
      error: interrupted ? '앱이 종료되어 전송 결과를 알 수 없습니다' : json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'text': text,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'outgoing': outgoing,
    'status': status.name,
    if (error != null) 'error': error,
  };

  /// Identifies an outgoing message in native messageSent/messageFailed events.
  final String id;
  final String text;
  final DateTime timestamp;
  final bool outgoing;
  MessageStatus status;
  String? error;

  String get statusLabel {
    if (!outgoing) {
      return 'Received';
    }
    return switch (status) {
      MessageStatus.sending => '전송 중',
      MessageStatus.sent => 'Sent',
      MessageStatus.failed => '전송 실패: ${error ?? '알 수 없는 오류'}',
    };
  }
}

class MessageHistoryEntry {
  MessageHistoryEntry({
    required this.deviceId,
    required this.deviceName,
    required this.message,
  });

  final String deviceId;
  final String deviceName;
  final BleMessage message;
}
