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

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final BleAppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      AdvertisingPage(controller: widget.controller),
      DevicesPage(controller: widget.controller),
      MessageDeviceListPage(controller: widget.controller),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth Communicator')),
      body: pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            selectedIcon: Icon(Icons.campaign),
            label: 'Advertising',
          ),
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
            selectedIcon: Icon(Icons.bluetooth_connected),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Messages',
          ),
        ],
      ),
    );
  }
}

class AdvertisingPage extends StatelessWidget {
  const AdvertisingPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Peripheral advertising'),
          subtitle: const Text('앱 재시작 이후 자동 복원'),
          value: controller.advertisingEnabled,
          onChanged: controller.setAdvertisingEnabled,
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('Background status'),
            subtitle: Text(controller.backgroundStatus),
          ),
        ),
        if (controller.lastError != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              title: const Text('Error'),
              subtitle: Text(controller.lastError!),
            ),
          ),
        ],
      ],
    );
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Central auto scan/connect'),
          subtitle: const Text('앱 재시작 이후 자동 복원'),
          value: controller.centralEnabled,
          onChanged: controller.setCentralEnabled,
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: controller.scanNow,
          icon: const Icon(Icons.radar),
          label: const Text('Scan now'),
        ),
        const SizedBox(height: 16),
        Text('Discovered devices', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...controller.discoveredDevices.map(
          (device) => Card(
            child: ListTile(
              title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
              subtitle: Text(device.identifier),
              trailing: Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () => controller.registerDevice(device),
                    child: const Text('Register'),
                  ),
                  FilledButton(
                    onPressed: () => controller.connectDevice(device.identifier),
                    child: const Text('Connect'),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Registered devices', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...controller.registeredDevices.map(
          (device) => Card(
            child: ListTile(
              title: Text(device.name.isEmpty ? '(Unknown)' : device.name),
              subtitle: Text(device.identifier),
              trailing: Text(
                controller.connectedDeviceIds.contains(device.identifier)
                    ? 'Connected'
                    : 'Disconnected',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MessageDeviceListPage extends StatelessWidget {
  const MessageDeviceListPage({super.key, required this.controller});

  final BleAppController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.registeredDevices;
    if (devices.isEmpty) {
      return const Center(child: Text('등록된 기기가 없습니다.'));
    }
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        final messageCount = controller.messagesByDevice[device.identifier]?.length ?? 0;
        return ListTile(
          title: Text(device.name.isEmpty ? device.identifier : device.name),
          subtitle: Text('${controller.connectedDeviceIds.contains(device.identifier) ? 'Connected' : 'Disconnected'} · $messageCount messages'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatPage(controller: controller, device: device),
              ),
            );
          },
        );
      },
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.controller, required this.device});

  final BleAppController controller;
  final BleDevice device;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages =
        widget.controller.messagesByDevice[widget.device.identifier] ?? <BleMessage>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.name.isEmpty ? widget.device.identifier : widget.device.name)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[messages.length - 1 - index];
                return ListTile(
                  title: Text(message.text),
                  subtitle: Text('${message.outgoing ? "Sent" : "Received"} · ${message.timestamp.toLocal()}'),
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
                        hintText: '메세지 입력',
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
                      await widget.controller.sendMessage(widget.device.identifier, text);
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
    final existing = registeredDevices.indexWhere((d) => d.identifier == device.identifier);
    if (existing >= 0) {
      registeredDevices[existing] = device;
    } else {
      registeredDevices.add(device);
    }
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
