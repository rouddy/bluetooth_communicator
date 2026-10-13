# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get                      # install deps
flutter analyze                      # lint (flutter_lints; android/ and ios/ are excluded)
flutter test                         # all tests
flutter test test/widget_test.dart   # single file
flutter test --plain-name "App shows BLE tabs"   # single test by name
flutter run                          # run on a connected device (BLE needs real hardware)
flutter build apk / flutter build ios
```

Native code isn't covered by `flutter analyze`. To check it, build it: `cd android && ./gradlew assembleDebug` for Kotlin, Xcode or `flutter build ios --no-codesign` for Swift.

## Architecture

This is a Flutter app for exchanging text messages between phones over BLE. Every device can act as a peripheral (advertising) and as a central (scanning and connecting). All BLE work happens in native code. Dart only holds UI state and talks to the native side over two platform channels.

### Platform channel contract (keep all three sides in sync)

- **MethodChannel** `com.rouddy.bluetooth_communicator/bluetooth_control`. Methods: `initialize`, `setAdvertisingEnabled{enabled}`, `setCentralEnabled{enabled}`, `scanNow`, `connectDevice{deviceId}`, `sendMessage{deviceId, message}`.
- **EventChannel** `com.rouddy.bluetooth_communicator/bluetooth_events`. Each event is a flat map with a `type` key: `status{status}`, `discovered{deviceId, name}`, `connected{deviceId}`, `disconnected{deviceId}`, `message{deviceId, message}`, `error{message}`.
- Shared GATT UUIDs are hard-coded on both native sides. Service `1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001`, message characteristic `DB912050-2E4E-4C4E-A543-E89121E57595`. Messages are sent as raw UTF-8 bytes.
- `deviceId` is the MAC address on Android and the `CBPeripheral.identifier` UUID string on iOS. These IDs are not portable between platforms.

When you add a method or event, update `lib/main.dart` (`BleAppController._invoke` / `_handleEvent`), `MainActivity.kt` + `BluetoothBackgroundService.kt`, and `AppDelegate.swift`.

### Dart (`lib/main.dart`, single file)

- `BleAppController` is a `ChangeNotifier`. The whole `MaterialApp` rebuilds from it through `AnimatedBuilder`. It keeps the advertising/central toggles and the registered-device list in `shared_preferences`. On `initialize()` it replays the saved state to native code: it enables the saved modes, runs a scan, and connects to each registered device.
- Message history lives only in memory (`messagesByDevice`). It isn't persisted.
- `HomePage` shows the device list (registered/connected devices under 연결 기록, scan results under 주변 기기). `DeviceControlPage` (connect button + chat) is pushed from it, and `SettingsPage`/`NotificationPage` from the app bar. The UI strings mix Korean and English.

### Android (`android/app/src/main/kotlin/.../bluetooth_communicator/`)

- `MainActivity` doesn't touch BLE. It turns each method call into an `Intent` action (`ble.action.*`) and sends it to `BluetoothBackgroundService` with `startForegroundService`.
- `BluetoothBackgroundService` is a `START_STICKY` foreground service (`connectedDevice` type). It owns advertising (plus the GATT server, opened and closed with it), scanning, and GATT client connections. Bonded devices use `connectGatt(autoConnect=true)`, and unbonded ones connect directly, because background connect rejects random addresses. It reconnects bonded registered devices when they disconnect while central mode is on. It saves its own toggle state in `ble_service_prefs`, separately from Dart's prefs, so it can restore that state without Flutter running.
- `BluetoothBootReceiver` sends `ACTION_RESTORE` on boot.
- `BleEventBus` is a process-wide singleton. It posts events to the Flutter `EventSink` on the main looper, and it drops events while no Flutter listener is attached.
- Automatic reconnects (on restore and on scan results) only target **bonded** devices.

### iOS (`ios/Runner/AppDelegate.swift`)

- `IOSBleBackgroundManager` handles the channel stream directly and owns a `CBCentralManager` and a `CBPeripheralManager`. Both use state-restoration identifiers, and `UIBackgroundModes` includes `bluetooth-central` and `bluetooth-peripheral`. It saves its toggles in `UserDefaults` (`pref_ios_advertising`, `pref_ios_central`).
- Channels are registered in `didFinishLaunchingWithOptions` from `window?.rootViewController`, and plugins through `FlutterImplicitEngineDelegate`, because the app uses the UIScene lifecycle (`SceneDelegate.swift`).

## Current state / known gaps

This is scaffolding in progress on branch `copilot/implement-bluetooth-background-messaging`. Android↔Android messaging works end to end (verified on two Galaxy phones): the central writes to the peripheral's message characteristic, and the peripheral replies with notifications on the same link. Keep these gaps in mind:
- Android hosts the GATT server (opened together with advertising). iOS still doesn't, so an Android central can't talk to an iOS peripheral.
- Unbonded Android peers advertise and connect with rotating resolvable private addresses, so the same phone shows up under a new `deviceId` after a restart or every ~15 minutes, and saved devices go stale. The peripheral side also sees the central under a different address than the one it advertises with, and without a name (`(Unknown)`).
- `BleEventBus` drops events while no Flutter listener is attached, so messages received while the activity is destroyed are lost. Connection state is replayed on `initialize` (`ACTION_RESTORE`), but message history isn't.
- `BLUETOOTH_SCAN` must keep `neverForLocation`. Without it, Android 12+ silently delivers zero scan results because the app doesn't hold location permission.
