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
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_test.dart -d <device-id>   # on-device smoke test (`flutter test integration_test` can't launch on wireless iOS devices)
cd android && ./gradlew :app:testDebugUnitTest   # Kotlin JVM unit tests
flutter build apk / flutter build ios
```

Native code isn't covered by `flutter analyze`. To check it, build it: `cd android && ./gradlew assembleDebug` for Kotlin, Xcode or `flutter build ios --no-codesign` for Swift.

## Architecture

This is a Flutter app for exchanging text messages between phones over BLE. Every device can act as a peripheral (advertising) and as a central (scanning and connecting). All BLE work happens in native code. Dart only holds UI state and talks to the native side over two platform channels.

### Platform channel contract (keep all three sides in sync)

- **MethodChannel** `com.rouddy.bluetooth_communicator/bluetooth_control`. Methods: `initialize`, `setAdvertisingEnabled{enabled}`, `setCentralEnabled{enabled}`, `scanNow`, `connectDevice{deviceId, pair}`, `disconnectDevice{deviceId}`, `sendMessage{deviceId, message, messageId}`.
- **EventChannel** `com.rouddy.bluetooth_communicator/bluetooth_events`. Each event is a flat map with a `type` key: `status{advertising, scanning, connectedCount, bluetoothOn}`, `discovered{deviceId, name}`, `connected{deviceId}`, `disconnected{deviceId}`, `message{deviceId, message}`, `messageSent{deviceId, messageId}`, `messageFailed{deviceId, messageId, error}`, `bonding{deviceId}` (Android only, emitted when `createBond` starts), `error{message}`.
- Shared GATT UUIDs are hard-coded on both native sides. Service `1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001`, message characteristic `DB912050-2E4E-4C4E-A543-E89121E57595`. Messages are sent as raw UTF-8 bytes.
- Both sides send the same structured `status`, and Dart builds the label (`advertising scanning connected:1`, `idle`, `bluetooth-off`; `unknown` before the first event). `connectedCount` counts distinct peers over both roles.
- `initialize` returns a Bool on both platforms. Android returns `true` once it has started the background service, or `false` if the Bluetooth permissions are missing. iOS returns whether the Bluetooth authorization is `allowedAlways`. Runtime permissions aren't part of the channel contract: Dart requests them with `permission_handler` before calling `initialize`.
- `disconnectDevice` drops every link to the device and cancels a pending connect. On Android that's the client link, the server link, and a pending `connectGatt`. On iOS it's the client link only, because CoreBluetooth can't drop a central that's connected to our service. Dart calls it when a registered device is deleted (`BleAppController.removeDevice`), after the registered list has been saved, because the Android service reads that list to decide whether to reconnect.
- Every `sendMessage` gets exactly one `messageSent` or `messageFailed` for its `messageId`. The id is generated in Dart, and the chat shows each message as 전송 중 until that event arrives. "Sent" means the peer's stack accepted it (write response, or notification handed off), not that the peer app displayed it. If Android can't even start the service action, the method call fails with `SERVICE_UNAVAILABLE`.
- `pair` is true only for user-initiated connects (the 연결 button). Android then bonds unbonded devices first via `createBond()`, which shows the system pairing dialog. Without it, Android connects only to already-bonded devices, so replaying saved devices on launch never prompts. iOS ignores it.
- `deviceId` is the MAC address on Android and the `CBPeripheral.identifier` UUID string on iOS. These IDs are not portable between platforms.

When you add a method or event, update `lib/main.dart` (`BleAppController._invoke` / `_handleEvent`), `MainActivity.kt` + `BluetoothBackgroundService.kt`, and `AppDelegate.swift`.

### Dart (`lib/main.dart`, single file)

- `BleAppController` is a `ChangeNotifier`. The whole `MaterialApp` rebuilds from it through `AnimatedBuilder`. It keeps the advertising/central toggles and the registered-device list in `shared_preferences`. On `initialize()` it replays the saved state to native code: it enables the saved modes, runs a scan, and connects to each registered device.
- Permissions: `BleAppController.checkPermissions`/`requestPermissions` use `permission_handler`. Required permissions are `bluetoothScan`/`bluetoothConnect`/`bluetoothAdvertise` on Android and `bluetooth` on iOS. `notification` is requested on Android but stays optional. If the user permanently denies a permission, the settings page offers `openAppSettings()`. On iOS (Swift Package Manager build), permission_handler enables `PERMISSION_BLUETOOTH` from the `NSBluetoothAlwaysUsageDescription` key in `Info.plist`, so there's no Podfile macro to set.
- Message history (`messagesByDevice`, newest 200 per device) and unread counts are persisted in `shared_preferences` (`prefs_messages`, `prefs_unread_counts`) on every change, and loaded once on the first `initialize()`. An outgoing message stored while it was still sending is restored as failed. Message events carry `receivedAt` (ms since epoch), which Dart uses as the timestamp.
- `HomePage` shows the device list (registered/connected devices under 연결 기록, scan results under 주변 기기). `DeviceControlPage` (connect button + chat) is pushed from it, and `SettingsPage`/`NotificationPage` from the app bar. The UI strings mix Korean and English.

### Android (`android/app/src/main/kotlin/.../bluetooth_communicator/`)

- `minSdk` is 31 (Android 12), so the app only uses the `BLUETOOTH_SCAN`/`CONNECT`/`ADVERTISE` runtime permissions and has no location-permission or pre-Oreo code paths. The remaining `SDK_INT` checks are for API 33 (`TIRAMISU`) GATT/parcel APIs.
- `compileSdk` is pinned to 37 because `permission_handler_android` 14.x requires it. `targetSdk` still follows Flutter's default.
- `MainActivity` doesn't touch BLE or request permissions. It turns each method call into an `Intent` action (`ble.action.*`) and sends it to `BluetoothBackgroundService` with `startForegroundService`.
- `BluetoothBackgroundService` is a `START_STICKY` foreground service (`connectedDevice` type). It owns advertising (plus the GATT server, opened and closed with it), scanning, and GATT client connections. Connections go through bonding: an unbonded device is bonded first (`bondStateReceiver` waits for `BOND_BONDED`) and then connected with `connectGatt(autoConnect=true)`. It reconnects bonded registered devices when they disconnect while central mode is on. It saves its own toggle state in `ble_service_prefs`, separately from Dart's prefs, so it can restore that state without Flutter running.
- Bonding is what keeps `deviceId` stable. Unbonded phones advertise with rotating random addresses. Once bonded, the stack resolves every later advertisement and incoming connection from that phone to the address it had at bonding time. So scan results, client links, and GATT server peers all report the same ID.
- Two bonded phones with central mode on usually end up linked twice, because each auto-connects to the other's server. A peer only gets `disconnected` once neither link is left (`emitDisconnectedIfUnlinked`).
- The service listens for `BluetoothAdapter.ACTION_STATE_CHANGED`. On power-off it resets its state, reports every link as `disconnected`, and the status becomes `bluetooth-off` (iOS reports the same string, and Dart shows a banner). On power-on it runs `restoreStateFromPrefs()`. Each advertising start uses a new `AdvertiseCallback`. The framework keeps the old one across a power cycle, and reusing it fails with `ALREADY_STARTED`. `advertiseCallback != null` marks a start in progress, so overlapping start requests don't create a second advertising set.
- GATT operations run through `GattOperationQueue`, one queue per link and role (`clientQueues`, `serverQueues`). Android allows a single outstanding operation per connection, so the CCCD write, message writes, and notifications each wait for their callback (`onDescriptorWrite`, `onCharacteristicWrite`, `onNotificationSent`). When a link goes away, its queued operations fail. The queue has JVM unit tests (`android/app/src/test`, `./gradlew :app:testDebugUnitTest`).
- `BluetoothBootReceiver` sends `ACTION_RESTORE` on boot.
- `BleEventBus` is a process-wide singleton. It posts events to the Flutter `EventSink` on the main looper. With no sink, message events go to a `PendingMessageStore` persisted in `ble_service_prefs`, and are delivered first when a sink attaches. Other events are dropped, because `initialize` replays that state. `MainActivity.cleanUpFlutterEngine` detaches the sink: the engine dies with the activity without calling `onCancel`, and without the detach, messages were sent into the dead engine. `appInForeground` (onResume/onPause) decides whether the service posts a message notification (channel `ble_messages`). Resuming clears those notifications.
- Automatic reconnects (on restore and on scan results) only target **bonded** devices.

### iOS (`ios/Runner/AppDelegate.swift`)

- `IOSBleBackgroundManager` handles the channel stream directly and owns a `CBCentralManager` and a `CBPeripheralManager`. Both use state-restoration identifiers, and `UIBackgroundModes` includes `bluetooth-central` and `bluetooth-peripheral`. It saves its toggles in `UserDefaults` (`pref_ios_advertising`, `pref_ios_central`).
- Peripheral role: `IOSBleBackgroundManager` publishes a `CBMutableService` with the message characteristic (write, writeWithoutResponse, notify) and starts advertising from `didAdd`. Writes become `message` events, and a subscription becomes `connected`. `sendMessage` to a subscribed central uses `updateValue`, queueing when the transmit queue is full until `peripheralManagerIsReady`. Turning advertising off removes the service, and Bluetooth power-off resets the peripheral state.
- Central role: `connectDevice` falls back to `retrievePeripherals(withIdentifiers:)` for saved devices that weren't scanned in this launch. Requests made before the manager is `poweredOn` wait in `pendingConnectIds`. `connected` is emitted when the notification subscription succeeds, not on `didConnect`. When the peer requires encryption, the first subscribe fails with insufficient authentication/encryption: iOS starts pairing but doesn't retry, so the subscribe is retried every 2 s, up to 30 times.
- The app uses the UIScene lifecycle (`SceneDelegate.swift`). So `window` is still nil in `didFinishLaunchingWithOptions`, and both the plugins and the BLE channels are registered in `didInitializeImplicitFlutterEngine` (`FlutterImplicitEngineDelegate`) on `engineBridge.applicationRegistrar.messenger()`.

## Current state / known gaps

This is scaffolding in progress on branch `copilot/implement-bluetooth-background-messaging`. Android↔Android messaging works end to end (verified on two Galaxy phones): the central writes to the peripheral's message characteristic, and the peripheral replies with notifications on the same link. Keep these gaps in mind:
- Both platforms host the message GATT server alongside advertising. Verified: Android ↔ Android, Android central (S23) ↔ iOS peripheral (AlgorigoSE, `integration_test/peripheral_exchange_test.dart`), and iOS central (AlgorigoSE) ↔ Android peripheral (Jump3, `integration_test/central_connect_test.dart`). iOS ↔ iOS is untested.
- Registered devices saved before bonding was added (random addresses) stay in the list as stale entries. There's no UI to remove a registered device.
- On both platforms the message characteristic and its CCCD require an encrypted link. An unbonded central gets "insufficient encryption" (iOS centrals then pair automatically) instead of chatting under a rotating random address.
- iOS keeps message events that arrive before Dart listens (UserDefaults `pending_messages`), but it doesn't post notifications for incoming messages. That needs a notification permission flow, which iOS doesn't have yet.
- `BLUETOOTH_SCAN` must keep `neverForLocation`. Without it, Android 12+ silently delivers zero scan results because the app doesn't hold location permission.
