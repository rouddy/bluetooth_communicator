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

- **MethodChannel** `com.rouddy.bluetooth_communicator/bluetooth_control`. Methods: `initialize`, `setAdvertisingEnabled{enabled}`, `setCentralEnabled{enabled}`, `scanNow`, `connectDevice{deviceId, pair}`, `sendMessage{deviceId, message}`.
- **EventChannel** `com.rouddy.bluetooth_communicator/bluetooth_events`. Each event is a flat map with a `type` key: `status{status}`, `discovered{deviceId, name}`, `connected{deviceId}`, `disconnected{deviceId}`, `message{deviceId, message}`, `error{message}`.
- Shared GATT UUIDs are hard-coded on both native sides. Service `1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001`, message characteristic `DB912050-2E4E-4C4E-A543-E89121E57595`. Messages are sent as raw UTF-8 bytes.
- `initialize` returns `true` once it has started the background service, or `false` if the Bluetooth permissions are missing. Runtime permissions aren't part of the channel contract: Dart requests them with `permission_handler` before calling `initialize`.
- `pair` is true only for user-initiated connects (the 연결 button). Android then bonds unbonded devices first via `createBond()`, which shows the system pairing dialog. Without it, Android connects only to already-bonded devices, so replaying saved devices on launch never prompts. iOS ignores it.
- `deviceId` is the MAC address on Android and the `CBPeripheral.identifier` UUID string on iOS. These IDs are not portable between platforms.

When you add a method or event, update `lib/main.dart` (`BleAppController._invoke` / `_handleEvent`), `MainActivity.kt` + `BluetoothBackgroundService.kt`, and `AppDelegate.swift`.

### Dart (`lib/main.dart`, single file)

- `BleAppController` is a `ChangeNotifier`. The whole `MaterialApp` rebuilds from it through `AnimatedBuilder`. It keeps the advertising/central toggles and the registered-device list in `shared_preferences`. On `initialize()` it replays the saved state to native code: it enables the saved modes, runs a scan, and connects to each registered device.
- Permissions: `BleAppController.checkPermissions`/`requestPermissions` use `permission_handler`. Required permissions are `bluetoothScan`/`bluetoothConnect`/`bluetoothAdvertise` on Android and `bluetooth` on iOS. `notification` is requested on Android but stays optional. If the user permanently denies a permission, the settings page offers `openAppSettings()`. On iOS (Swift Package Manager build), permission_handler enables `PERMISSION_BLUETOOTH` from the `NSBluetoothAlwaysUsageDescription` key in `Info.plist`, so there's no Podfile macro to set.
- Message history lives only in memory (`messagesByDevice`). It isn't persisted.
- `HomePage` shows the device list (registered/connected devices under 연결 기록, scan results under 주변 기기). `DeviceControlPage` (connect button + chat) is pushed from it, and `SettingsPage`/`NotificationPage` from the app bar. The UI strings mix Korean and English.

### Android (`android/app/src/main/kotlin/.../bluetooth_communicator/`)

- `minSdk` is 31 (Android 12), so the app only uses the `BLUETOOTH_SCAN`/`CONNECT`/`ADVERTISE` runtime permissions and has no location-permission or pre-Oreo code paths. The remaining `SDK_INT` checks are for API 33 (`TIRAMISU`) GATT/parcel APIs.
- `compileSdk` is pinned to 37 because `permission_handler_android` 14.x requires it. `targetSdk` still follows Flutter's default.
- `MainActivity` doesn't touch BLE or request permissions. It turns each method call into an `Intent` action (`ble.action.*`) and sends it to `BluetoothBackgroundService` with `startForegroundService`.
- `BluetoothBackgroundService` is a `START_STICKY` foreground service (`connectedDevice` type). It owns advertising (plus the GATT server, opened and closed with it), scanning, and GATT client connections. Connections go through bonding: an unbonded device is bonded first (`bondStateReceiver` waits for `BOND_BONDED`) and then connected with `connectGatt(autoConnect=true)`. It reconnects bonded registered devices when they disconnect while central mode is on. It saves its own toggle state in `ble_service_prefs`, separately from Dart's prefs, so it can restore that state without Flutter running.
- Bonding is what keeps `deviceId` stable. Unbonded phones advertise with rotating random addresses. Once bonded, the stack resolves every later advertisement and incoming connection from that phone to the address it had at bonding time. So scan results, client links, and GATT server peers all report the same ID.
- Two bonded phones with central mode on usually end up linked twice, because each auto-connects to the other's server. A peer only gets `disconnected` once neither link is left (`emitDisconnectedIfUnlinked`).
- `BluetoothBootReceiver` sends `ACTION_RESTORE` on boot.
- `BleEventBus` is a process-wide singleton. It posts events to the Flutter `EventSink` on the main looper, and it drops events while no Flutter listener is attached.
- Automatic reconnects (on restore and on scan results) only target **bonded** devices.

### iOS (`ios/Runner/AppDelegate.swift`)

- `IOSBleBackgroundManager` handles the channel stream directly and owns a `CBCentralManager` and a `CBPeripheralManager`. Both use state-restoration identifiers, and `UIBackgroundModes` includes `bluetooth-central` and `bluetooth-peripheral`. It saves its toggles in `UserDefaults` (`pref_ios_advertising`, `pref_ios_central`).
- Channels are registered in `didFinishLaunchingWithOptions` from `window?.rootViewController`, and plugins through `FlutterImplicitEngineDelegate`, because the app uses the UIScene lifecycle (`SceneDelegate.swift`).

## Current state / known gaps

This is scaffolding in progress on branch `copilot/implement-bluetooth-background-messaging`. Android↔Android messaging works end to end (verified on two Galaxy phones): the central writes to the peripheral's message characteristic, and the peripheral replies with notifications on the same link. Keep these gaps in mind:
- Android hosts the GATT server (opened together with advertising). iOS still doesn't, so an Android central can't talk to an iOS peripheral.
- Registered devices saved before bonding was added (random addresses) stay in the list as stale entries. There's no UI to remove a registered device.
- Unbonded centrals (e.g. iOS) can still subscribe to the Android GATT server, because the characteristic doesn't require encryption. They're registered under their rotating random address.
- `BleEventBus` drops events while no Flutter listener is attached, so messages received while the activity is destroyed are lost. Connection state is replayed on `initialize` (`ACTION_RESTORE`), but message history isn't.
- `BLUETOOTH_SCAN` must keep `neverForLocation`. Without it, Android 12+ silently delivers zero scan results because the app doesn't hold location permission.
