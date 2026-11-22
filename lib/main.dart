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
const String _prefsClipboardSharing = 'prefs_clipboard_sharing';
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
  StreamSubscription<String>? _notices;
  StreamSubscription<PairingRequest>? _pairingPrompts;
  StreamSubscription<int>? _fileDialogs;

  /// Devices whose pairing dialog is open, so a replayed request doesn't open a
  /// second one.
  final Set<String> _openPrompts = <String>{};

  /// Incoming file transfers whose dialog is open.
  final Set<int> _openFileDialogs = <int>{};

  @override
  void initState() {
    super.initState();
    // Errors used to show up only on the settings page; surface each one where the
    // user is, whatever page that is.
    _errors = widget.controller.errors.listen(_showSnackBar);
    _notices = widget.controller.notices.listen(_showSnackBar);
    // Either phone can be asked to approve a pairing, whatever page is open.
    _pairingPrompts = widget.controller.pairingPrompts.listen(_showPairingDialog);
    // A peer can offer a file whatever page is open.
    _fileDialogs = widget.controller.fileDialogs.listen(_showFileDialog);
  }

  void _showSnackBar(String message) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _showFileDialog(int id) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !_openFileDialogs.add(id)) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FileTransferDialog(controller: widget.controller, id: id),
    );
    _openFileDialogs.remove(id);
  }

  @override
  void dispose() {
    _errors?.cancel();
    _notices?.cancel();
    _pairingPrompts?.cancel();
    _fileDialogs?.cancel();
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

/// A file a peer sends (docs/protocol.md 10절, `/file`): the offer to approve, the
/// download's progress, then the export screen, where the user saves the file or
/// sends it to another app. It closes itself when the transfer is gone (declined,
/// canceled, failed, or dismissed); why it failed shows as a SnackBar.
class FileTransferDialog extends StatefulWidget {
  const FileTransferDialog({
    super.key,
    required this.controller,
    required this.id,
  });

  final BleAppController controller;
  final int id;

  @override
  State<FileTransferDialog> createState() => _FileTransferDialogState();
}

class _FileTransferDialogState extends State<FileTransferDialog> {
  bool _closing = false;
  bool _exporting = false;

  /// Saved at least once; said in the dialog, where a SnackBar would be hidden.
  bool _saved = false;

  BleAppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final transfer = controller.fileTransfers[widget.id];
        if (transfer == null) {
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
        return switch (transfer.state) {
          FileTransferState.completed => _buildReceived(context, transfer),
          FileTransferState.transferring => _buildProgress(context, transfer),
          _ => _buildOffer(context, transfer),
        };
      },
    );
  }

  Widget _summary(BuildContext context, FileTransfer transfer) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(transfer.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(formatBytes(transfer.size)),
    );
  }

  Widget _buildOffer(BuildContext context, FileTransfer transfer) {
    return AlertDialog(
      title: const Text('파일 받기 요청'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${controller.displayName(transfer.deviceId)}에서 파일을 보내려고 합니다.'),
          const SizedBox(height: 8),
          _summary(context, transfer),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => controller.respondFile(widget.id, false),
          child: const Text('거절'),
        ),
        FilledButton(
          onPressed: () => controller.respondFile(widget.id, true),
          child: const Text('승인'),
        ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context, FileTransfer transfer) {
    return AlertDialog(
      title: const Text('파일 받는 중'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(context, transfer),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: transfer.progress),
          const SizedBox(height: 8),
          Text('${formatBytes(transfer.bytes)} / ${formatBytes(transfer.size)}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => controller.cancelFile(widget.id),
          child: const Text('취소'),
        ),
      ],
    );
  }

  Future<void> _export(FileExportAction action) async {
    setState(() => _exporting = true);
    var done = false;
    try {
      done = await controller.exportFile(widget.id, action);
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _saved |= done && action == FileExportAction.save;
        });
      }
    }
  }

  /// The export screen: save the file, or hand it to another app.
  Widget _buildReceived(BuildContext context, FileTransfer transfer) {
    return AlertDialog(
      title: const Text('파일을 받았습니다'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(context, transfer),
          const SizedBox(height: 8),
          const Text('기기에 저장하거나 다른 앱으로 보낼 수 있습니다. 닫은 뒤에는 다시 열 수 없습니다.'),
          if (_saved) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.check_circle, size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(child: Text('파일을 저장했습니다.')),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _exporting ? null : () => controller.dismissFile(widget.id),
          child: const Text('닫기'),
        ),
        TextButton(
          onPressed: _exporting ? null : () => _export(FileExportAction.save),
          child: const Text('저장'),
        ),
        FilledButton(
          onPressed: _exporting ? null : () => _export(FileExportAction.share),
          child: const Text('앱으로 보내기'),
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
          SwitchListTile(
            title: const Text('클립보드 공유'),
            subtitle: const Text('연결된 기기가 이 기기의 클립보드를 가져갈 수 있습니다'),
            value: controller.clipboardSharing,
            onChanged: controller.setClipboardSharing,
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
          // Other apps reach their peers through the AIDL service (Android only).
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            const _SectionHeader('연동된 앱'),
            if (controller.registeredApps.isEmpty)
              const ListTile(
                leading: Icon(Icons.apps_outlined),
                title: Text('이 기기를 사용하는 앱이 없습니다'),
                subtitle: Text('다른 앱이 연결 기기와 통신하려고 등록하면 여기에 표시됩니다'),
              )
            else
              for (final app in controller.registeredApps)
                ListTile(
                  leading: Icon(app.canReceive ? Icons.apps : Icons.apps_outlined),
                  title: Text(app.label),
                  subtitle: Text('${app.packageName}\n${app.receiveStatus}'),
                  isThreeLine: true,
                ),
          ],
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

  /// Copies the peer's clipboard to this phone's (docs/protocol.md 10절).
  Widget _clipboardTile(bool isConnected) {
    final state = controller.clipboardRequests[device.identifier];
    return ListTile(
      leading: const Icon(Icons.content_paste_go),
      title: const Text('클립보드 가져오기'),
      subtitle: Text(switch (state) {
        ClipboardRequestState.requesting => '가져오는 중…',
        ClipboardRequestState.waiting => '상대 기기에서 확인을 기다리는 중…',
        null when isConnected => '상대 기기의 클립보드를 이 기기에 복사합니다',
        null => '연결되면 쓸 수 있습니다',
      }),
      enabled: isConnected && state == null,
      trailing: state == null
          ? null
          : const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
      onTap: () => controller.requestClipboard(device.identifier),
    );
  }

  /// Sends a file the user picks (docs/protocol.md 10절, `/file`).
  Widget _sendFileTile(bool isConnected) {
    return ListTile(
      leading: const Icon(Icons.upload_file),
      title: const Text('파일 보내기'),
      subtitle: Text(isConnected ? '파일을 골라 상대 기기로 보냅니다. 상대가 승인하면 전송됩니다' : '연결되면 쓸 수 있습니다'),
      enabled: isConnected,
      onTap: () => controller.sendFile(device.identifier),
    );
  }

  Widget _outgoingTile(FileTransfer transfer) {
    return ListTile(
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(transfer.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: transfer.state == FileTransferState.transferring
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(value: transfer.progress),
                const SizedBox(height: 4),
                Text('${formatBytes(transfer.bytes)} / ${formatBytes(transfer.size)}'),
              ],
            )
          : const Text('상대 기기의 승인을 기다리는 중…'),
      trailing: IconButton(
        tooltip: '전송 취소',
        icon: const Icon(Icons.close),
        onPressed: () => controller.cancelFile(transfer.id),
      ),
    );
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
          if (peerId != null || isConnected) _clipboardTile(isConnected),
          if (peerId != null || isConnected) _sendFileTile(isConnected),
          ...controller.outgoingTransfersTo(device.identifier).map(_outgoingTile),
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

  /// Whether peers may take this phone's clipboard (`/clipboard`).
  bool clipboardSharing = true;

  /// Our clipboard requests in progress, by device.
  final Map<String, ClipboardRequestState> clipboardRequests = <String, ClipboardRequestState>{};

  /// File transfers by id: ours until they end, and the peers' until the dialog
  /// is closed (a received file stays for the export screen until dismissed).
  final Map<int, FileTransfer> fileTransfers = <int, FileTransfer>{};
  final StreamController<int> _fileDialogs = StreamController<int>.broadcast();

  /// Transfers this user canceled, declined, or dismissed: updates already on
  /// their way from native code mustn't bring them back.
  final Set<int> _closedFileIds = <int>{};

  /// Each incoming transfer that's new to this side, to open its dialog.
  Stream<int> get fileDialogs => _fileDialogs.stream;

  /// Our transfers to [deviceId] in progress, oldest first.
  List<FileTransfer> outgoingTransfersTo(String deviceId) => fileTransfers.values
      .where((transfer) => transfer.outgoing && transfer.deviceId == deviceId)
      .toList();

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

  final StreamController<String> _notices = StreamController<String>.broadcast();

  /// Things that went well, for a SnackBar; unlike [errors], not kept.
  Stream<String> get notices => _notices.stream;

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

  /// The other apps on this phone that use the AIDL service (Android; `apps`
  /// event). Native code keeps the list and drops uninstalled apps.
  final List<RegisteredApp> registeredApps = <RegisteredApp>[];

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
    await _invoke('setClipboardSharing', {'enabled': clipboardSharing});
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

  Future<void> setClipboardSharing(bool enabled) async {
    clipboardSharing = enabled;
    await _prefs?.setBool(_prefsClipboardSharing, enabled);
    notifyListeners();
    await _invoke('setClipboardSharing', {'enabled': enabled});
  }

  /// Asks [deviceId] for its clipboard; the text lands in this phone's clipboard
  /// (`clipboard` events).
  Future<void> requestClipboard(String deviceId) async {
    if (clipboardRequests.containsKey(deviceId)) {
      return;
    }
    clipboardRequests[deviceId] = ClipboardRequestState.requesting;
    notifyListeners();
    if (!await _invoke('requestClipboard', {'deviceId': deviceId})) {
      clipboardRequests.remove(deviceId);
      notifyListeners();
    }
  }

  Future<void> _onClipboard(String deviceId, Map<String, dynamic> event) async {
    final result = event['result'] as String? ?? 'failed';
    if (result == 'waiting') {
      clipboardRequests[deviceId] = ClipboardRequestState.waiting;
      return;
    }
    clipboardRequests.remove(deviceId);
    final name = _displayName(deviceId);
    final text = event['text'] as String?;
    if (result == 'ok' && text != null) {
      await Clipboard.setData(ClipboardData(text: text));
      _notices.add('$name의 클립보드를 가져왔습니다. 붙여넣을 수 있습니다.');
    } else {
      _reportError(_clipboardFailure(name, result, event['status'] as int?));
    }
    notifyListeners();
  }

  static String _clipboardFailure(String name, String result, int? status) => switch (result) {
    'empty' => '$name의 클립보드가 비어 있습니다.',
    'notText' => '$name의 클립보드에 텍스트가 없습니다.',
    'unavailable' => '$name에서 앱을 열어야 클립보드를 가져올 수 있습니다.',
    'denied' => '$name에서 클립보드 공유를 허용하지 않았습니다.',
    'tooLarge' => '$name의 클립보드 내용이 너무 깁니다.',
    'timeout' => '$name에서 응답이 없습니다.',
    // NO_RECEIVER/UNSUPPORTED: an app version without /clipboard.
    _ when status == 1 || status == 2 => '$name의 앱이 클립보드 가져오기를 지원하지 않습니다. 앱을 업데이트해 주세요.',
    _ when status == 1000 => '$name와(과) 연결되어 있지 않습니다.',
    _ => '$name의 클립보드를 가져오지 못했습니다.',
  };

  /// Lets the user pick a file and offers it to [deviceId]; its user has to
  /// approve it (`fileTransfer` events follow). [path] skips the picker (tests).
  Future<void> sendFile(String deviceId, {String? path}) async {
    try {
      await _methodChannel.invokeMethod<bool>('sendFile', {'deviceId': deviceId, 'path': ?path});
    } on PlatformException catch (error) {
      _reportError(switch (error.code) {
        'READ_FAILED' => '파일을 열지 못했습니다.',
        'NOT_PAIRED' => '${_displayName(deviceId)}와(과) 연결된 적이 없습니다.',
        'BUSY' => '파일 선택 화면이 이미 열려 있습니다.',
        _ => '파일을 보내지 못했습니다: ${error.message ?? error.code}',
      });
      notifyListeners();
    } on MissingPluginException {
      _reportError('Native Bluetooth channel unavailable (sendFile)');
      notifyListeners();
    }
  }

  /// Answers a peer's file offer; an accepted file downloads, then the dialog
  /// offers to save or share it.
  Future<void> respondFile(int id, bool accept) async {
    final transfer = fileTransfers[id];
    if (transfer == null || transfer.state != FileTransferState.offered) {
      return;
    }
    if (!accept) {
      fileTransfers.remove(id);
      _closedFileIds.add(id);
      notifyListeners();
    }
    await _invoke('respondFile', {'id': id, 'accept': accept});
  }

  /// Stops a transfer in either direction; the peer is told.
  Future<void> cancelFile(int id) async {
    final transfer = fileTransfers.remove(id);
    if (transfer == null) {
      return;
    }
    _closedFileIds.add(id);
    notifyListeners();
    await _invoke('cancelFile', {'id': id});
  }

  /// Closes a received file's export screen; native code forgets it.
  Future<void> dismissFile(int id) async {
    if (fileTransfers.remove(id) == null) {
      return;
    }
    _closedFileIds.add(id);
    notifyListeners();
    await _invoke('dismissFile', {'id': id});
  }

  /// Saves the received file [id] where the user picks, or sends it to an app.
  /// Returns whether it was saved (false if the user closed the picker), or
  /// whether the share sheet opened.
  Future<bool> exportFile(int id, FileExportAction action) async {
    try {
      return await _methodChannel.invokeMethod<bool>('exportFile', {'id': id, 'action': action.name}) ?? false;
    } on PlatformException catch (error) {
      _reportError(switch (error.code) {
        'NOT_FOUND' => '받은 파일이 더 이상 없습니다.',
        'BUSY' => '파일 선택 화면이 이미 열려 있습니다.',
        _ => action == FileExportAction.save ? '파일을 저장하지 못했습니다.' : '파일을 다른 앱으로 보내지 못했습니다.',
      });
      notifyListeners();
    } on MissingPluginException {
      _reportError('Native Bluetooth channel unavailable (exportFile)');
      notifyListeners();
    }
    return false;
  }

  void _onFileTransfer(FileTransfer transfer) {
    if (_closedFileIds.contains(transfer.id)) {
      // The user's own cancel or decline ending it needs no message.
      if (transfer.finished) {
        _closedFileIds.remove(transfer.id);
      }
      return;
    }
    final previous = fileTransfers[transfer.id];
    final keep = !transfer.finished || (!transfer.outgoing && transfer.state == FileTransferState.completed);
    if (keep) {
      fileTransfers[transfer.id] = transfer;
    } else {
      fileTransfers.remove(transfer.id);
    }
    if (!transfer.outgoing && keep && previous == null) {
      _fileDialogs.add(transfer.id);
    }
    if (!transfer.finished) {
      return;
    }
    final name = _displayName(transfer.deviceId);
    if (transfer.outgoing && transfer.state == FileTransferState.completed) {
      _notices.add('$name에 파일을 보냈습니다: ${transfer.name}');
      return;
    }
    final message = transfer.outgoing
        ? _sendFailure(name, transfer)
        : _receiveFailure(name, transfer, wasOffered: previous?.state == FileTransferState.offered);
    if (message != null) {
      _reportError(message);
    }
  }

  /// Why our file didn't go through; null when this user canceled it.
  static String? _sendFailure(String name, FileTransfer transfer) => switch (transfer.state) {
    FileTransferState.declined => '$name에서 파일을 거절했습니다.',
    FileTransferState.canceled => transfer.byPeer ? '$name에서 파일 받기를 취소했습니다.' : null,
    _ => switch (transfer.reason) {
      'timeout' => '$name에서 응답이 없어 파일을 보내지 못했습니다.',
      'unsupported' => '$name의 앱이 파일 받기를 지원하지 않습니다. 앱을 업데이트해 주세요.',
      'notConnected' => '$name와(과) 연결되어 있지 않아 파일을 보내지 못했습니다.',
      'linkLost' => '$name와(과)의 연결이 끊어져 파일을 보내지 못했습니다.',
      'read' => '파일을 읽지 못했습니다: ${transfer.name}',
      'peer' => '$name에서 파일을 저장하지 못했습니다.',
      'busy' => '$name에 대기 중인 파일 요청이 너무 많습니다.',
      _ => '$name에 파일을 보내지 못했습니다.',
    },
  };

  /// Why a peer's file didn't arrive; null when this user declined or canceled.
  static String? _receiveFailure(String name, FileTransfer transfer, {required bool wasOffered}) =>
      switch (transfer.state) {
        FileTransferState.declined => null,
        FileTransferState.canceled => transfer.byPeer ? '$name에서 파일 보내기를 취소했습니다.' : null,
        _ => switch (transfer.reason) {
          'timeout' when wasOffered => '$name의 파일 받기 요청이 시간이 지나 거절되었습니다.',
          'timeout' => '$name에서 파일이 더 오지 않아 받기를 멈췄습니다.',
          'storage' => '받은 파일을 저장하지 못했습니다. 저장 공간을 확인해 주세요.',
          'notConnected' || 'linkLost' => '$name와(과)의 연결이 끊어져 파일을 받지 못했습니다.',
          _ => '$name에서 파일을 받지 못했습니다.',
        },
      };

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

  /// The name to show for [deviceId]: the peer's, or the ID.
  String displayName(String deviceId) => _displayName(deviceId);

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
      case 'apps':
        final apps = (event['apps'] as List?)?.whereType<Map>() ?? const <Map>[];
        registeredApps
          ..clear()
          ..addAll(apps.map((app) => RegisteredApp.fromMap(app.cast<String, dynamic>())));
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
      case 'clipboard':
        if (event['deviceId'] case final String id) {
          unawaited(_onClipboard(id, event));
        }
        break;
      case 'fileTransfer':
        if (event['id'] is int && event['deviceId'] is String) {
          _onFileTransfer(FileTransfer.fromEvent(event));
        }
        break;
      case 'clipboardShared':
        if (event['deviceId'] case final String id) {
          _notices.add('${_displayName(id)}에 클립보드를 보냈습니다.');
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
    clipboardSharing = prefs.getBool(_prefsClipboardSharing) ?? true;
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
    _notices.close();
    _pairingPrompts.close();
    _fileDialogs.close();
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

/// An app that uses the AIDL service (`apps` event; Android only).
class RegisteredApp {
  const RegisteredApp({
    required this.packageName,
    required this.label,
    this.listening = false,
    this.receiveService = false,
  });

  factory RegisteredApp.fromMap(Map<String, dynamic> map) => RegisteredApp(
    packageName: map['packageName'] as String? ?? '',
    label: (map['label'] as String?)?.trim().isNotEmpty == true
        ? map['label'] as String
        : map['packageName'] as String? ?? '',
    listening: map['listening'] == true,
    receiveService: map['receiveService'] == true,
  );

  final String packageName;
  final String label;

  /// It has a listener registered now (the app is running).
  final bool listening;

  /// It declares a RECEIVE service, so it gets messages while it isn't running.
  final bool receiveService;

  bool get canReceive => listening || receiveService;

  String get receiveStatus => switch ((listening, receiveService)) {
    (true, _) => '실행 중 · 메시지 받는 중',
    (false, true) => '앱이 꺼져 있어도 메시지를 받습니다',
    (false, false) => '앱을 열면 메시지를 받습니다',
  };
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

/// Where a file transfer is (`fileTransfer.state`).
enum FileTransferState {
  /// A peer offered it; waiting for this user.
  offered,

  /// We offered it; waiting for the peer's user.
  waiting,
  transferring,
  completed,
  declined,
  canceled,
  failed,
}

/// A `fileTransfer` event: one file to or from a peer (docs/protocol.md 10절).
class FileTransfer {
  const FileTransfer({
    required this.id,
    required this.deviceId,
    required this.outgoing,
    required this.name,
    required this.size,
    required this.mime,
    required this.state,
    this.bytes = 0,
    this.byPeer = false,
    this.reason,
    this.status,
    this.path,
  });

  factory FileTransfer.fromEvent(Map<String, dynamic> event) => FileTransfer(
    id: event['id'] as int,
    deviceId: event['deviceId'] as String,
    outgoing: event['direction'] == 'send',
    name: event['name'] as String? ?? '',
    size: event['size'] as int? ?? 0,
    mime: event['mime'] as String? ?? '',
    state: FileTransferState.values.asNameMap()[event['state']] ?? FileTransferState.failed,
    bytes: event['bytes'] as int? ?? 0,
    byPeer: event['byPeer'] == true,
    reason: event['reason'] as String?,
    status: event['status'] as int?,
    path: event['path'] as String?,
  );

  /// Local to this phone; what the `*File` methods take.
  final int id;
  final String deviceId;

  /// Whether this phone sends it.
  final bool outgoing;
  final String name;
  final int size;
  final String mime;
  final FileTransferState state;

  /// Sent and confirmed, or received and written.
  final int bytes;

  /// Declined or canceled by the peer's user, not this one.
  final bool byPeer;

  /// Why it failed: `timeout`, `unsupported`, `notConnected`, `linkLost`,
  /// `storage`, `read`, `peer`, `busy`, or `unpaired`.
  final String? reason;
  final int? status;

  /// Where a received file is, once completed.
  final String? path;

  bool get finished => state.index >= FileTransferState.completed.index;

  /// 0–1, or null when there's nothing to measure (an empty file).
  double? get progress => size > 0 ? (bytes / size).clamp(0.0, 1.0) : null;
}

/// What the export screen does with a received file (`exportFile.action`).
enum FileExportAction {
  /// Into a folder the user picks (Android's document picker, iOS Files).
  save,

  /// To another app, through the share sheet.
  share,
}

/// e.g. `512 B`, `16.4 KB`, `3.6 MB`. Decimal units, like the sizes Android and
/// iOS show (in the notifications, for one).
String formatBytes(int bytes) {
  const units = ['KB', 'MB', 'GB'];
  if (bytes < 1000) {
    return '$bytes B';
  }
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

enum ClipboardRequestState {
  /// Sent; no answer yet.
  requesting,

  /// The peer's app couldn't read its clipboard yet and asked its user.
  waiting,
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
