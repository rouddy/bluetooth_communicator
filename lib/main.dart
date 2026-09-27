import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _bleChannelName =
    'com.rouddy.bluetooth_communicator/bluetooth_control';
const String _bleEventsChannelName =
    'com.rouddy.bluetooth_communicator/bluetooth_events';
const String _prefsAdvertisingEnabled = 'prefs_advertising_enabled';
const String _prefsCentralEnabled = 'prefs_central_enabled';
const String _prefsRegisteredDevices = 'prefs_registered_devices';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = BleAppController();
  await controller.initialize();
  runApp(MyApp(controller: controller));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'Bluetooth Communicator',
          theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
          home: HomePage(controller: controller),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('기기 목록'),
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
      body: DeviceListPage(controller: controller),
    );
  }
}

class DeviceListPage extends StatelessWidget {
  const DeviceListPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.allKnownDevices;
    if (devices.isEmpty) {
      return const Center(child: Text('연결 기록이 있는 기기가 없습니다.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: devices.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final device = devices[index];
        final isConnected = controller.connectedDeviceIds.contains(device.identifier);
        final unreadCount = controller.unreadCountFor(device.identifier);
        return ListTile(
          leading: Icon(
            isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          ),
          title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
          subtitle: Text(
            '${isConnected ? "연결됨" : "연결 안 됨"} · ${device.identifier}',
          ),
          trailing: unreadCount > 0
              ? Badge(
                  label: Text(unreadCount.toString()),
                  child: const Icon(Icons.mark_chat_unread_outlined),
                )
              : null,
          onTap: () {
            controller.clearUnreadForDevice(device.identifier);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DeviceControlPage(controller: controller, device: device),
              ),
            );
          },
        );
      },
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
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
            leading: const Icon(Icons.info_outline),
            title: const Text('Background 상태'),
            subtitle: Text(controller.backgroundStatus),
          ),
          if (controller.lastError != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('오류'),
              subtitle: Text(controller.lastError!),
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
                trailing: Text(entry.message.outgoing ? 'Sent' : 'Recv'),
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

class _DeviceControlPageState extends State<DeviceControlPage> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
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
      ),
      body: Column(
        children: [
          ListTile(
            leading: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            ),
            title: Text(isConnected ? '연결됨' : '연결 안 됨'),
            subtitle: Text(widget.device.identifier),
            trailing: FilledButton.tonal(
              onPressed: isConnected
                  ? null
                  : () {
                      widget.controller.connectDevice(widget.device.identifier);
                    },
              child: Text(isConnected ? '연결됨' : '연결'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[messages.length - 1 - index];
                return ListTile(
                  title: Text(message.text),
                  subtitle: Text(
                    '${message.outgoing ? "Sent" : "Received"} · ${message.timestamp.toLocal()}',
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '메시지 입력',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () async {
                      final text = _textController.text.trim();
                      if (text.isEmpty) {
                        return;
                      }
                      _textController.clear();
                      await widget.controller.sendMessage(
                        widget.device.identifier,
                        text,
                      );
                    },
                    icon: const Icon(Icons.send),
                  ),
                ],
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
  String backgroundStatus = 'idle';
  String? lastError;

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

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _loadFromPrefs();
    _eventsSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) {
        lastError = error.toString();
        notifyListeners();
      },
    );
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

  Future<void> connectDevice(String deviceId) async {
    await _invoke('connectDevice', {'deviceId': deviceId});
  }

  Future<void> registerDevice(BleDevice device) async {
    _upsertRegisteredDevice(device);
    await _saveRegisteredDevices();
    notifyListeners();
  }

  Future<void> sendMessage(String deviceId, String text) async {
    _appendMessage(
      deviceId,
      BleMessage(text: text, timestamp: DateTime.now(), outgoing: true),
    );
    await _invoke('sendMessage', {'deviceId': deviceId, 'message': text});
    notifyListeners();
  }

  void clearUnreadForDevice(String deviceId) {
    if ((unreadCountByDevice[deviceId] ?? 0) == 0) {
      return;
    }
    unreadCountByDevice.remove(deviceId);
    notifyListeners();
  }

  int unreadCountFor(String deviceId) => unreadCountByDevice[deviceId] ?? 0;

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      lastError = '${error.code}: ${error.message}';
      notifyListeners();
    }
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
        backgroundStatus = (event['status'] as String?) ?? backgroundStatus;
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
          connectedDeviceIds.add(id);
          _upsertRegisteredDevice(_deviceById(id));
          unawaited(_saveRegisteredDevices());
        }
        break;
      case 'disconnected':
        final id = event['deviceId'] as String?;
        if (id != null) {
          connectedDeviceIds.remove(id);
        }
        break;
      case 'message':
        final id = event['deviceId'] as String?;
        final message = event['message'] as String?;
        if (id != null && message != null) {
          _appendMessage(
            id,
            BleMessage(text: message, timestamp: DateTime.now(), outgoing: false),
          );
          unreadCountByDevice[id] = (unreadCountByDevice[id] ?? 0) + 1;
        }
        break;
      case 'error':
        lastError = event['message'] as String?;
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

class BleMessage {
  BleMessage({
    required this.text,
    required this.timestamp,
    required this.outgoing,
  });

  final String text;
  final DateTime timestamp;
  final bool outgoing;
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
