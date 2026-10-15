# TODO

우선순위
- **P0**: 해당 플랫폼에서 앱이 아예 동작하지 않는 문제
- **P1**: 핵심 기능(연결·메시지)이 틀리거나 유실되는 문제
- **P2**: 안정성, UX, 배터리
- **P3**: 구조 개선, 품질

근거 표시
- `확인됨`: 두 Galaxy 기기에서 재현했거나 직접 관찰함
- `코드`: 코드상 확실하지만 기기에서는 재현하지 않음
- `추정`: 검증이 필요함

---

## P0: 앱이 동작하지 않음

### 1. MethodChannel 예외 처리 범위가 좁음 `코드` ✅ 해결
- 해결: `_invoke()`가 `MissingPluginException`도 잡아서 `lastError`로 보고합니다. 테스트: `test/ble_app_controller_test.dart`의 `native channel errors`.
- 권한 요청은 permission_handler로 옮겼습니다(`3caf811`). 그래서 iOS에서 `checkPermissions`가 없어 `runApp()` 전에 예외가 나던 원인은 사라졌습니다.
- 다만 `_invoke()`는 여전히 `PlatformException`만 잡습니다. 채널이 등록되지 않으면(2번) `MissingPluginException`이 그대로 올라가서 `runApp()`을 막습니다.
- 수정 방향: `_invoke()`의 catch 범위를 `MissingPluginException`까지 넓힙니다.

### 2. iOS 채널 등록이 `window?.rootViewController`에 의존함 `확인됨` ✅ 해결
- 확인: AlgorigoSE(iOS 27.0.1)에서 `integration_test/app_test.dart`가 `Native Bluetooth channel unavailable (initialize)`와 EventChannel `listen`의 `MissingPluginException`으로 실패했습니다.
- 해결: 채널을 `didInitializeImplicitFlutterEngine`에서 `engineBridge.applicationRegistrar.messenger()`로 등록합니다. 같은 테스트가 통과합니다.
- UIScene 생명주기(`SceneDelegate` + `UISceneStoryboardFile`)에서는 `didFinishLaunchingWithOptions` 시점에 AppDelegate의 `window`가 nil일 가능성이 높습니다.
- 그러면 `guard`에서 바로 return해서 MethodChannel과 EventChannel이 등록되지 않습니다.
- 수정 방향: `didInitializeImplicitFlutterEngine(_:)`에서 `engineBridge.applicationRegistrar.messenger()`로 채널을 등록합니다.
- 실제 iOS 기기에서 먼저 확인해야 합니다.

### 3. `main()`이 `initialize()`를 끝까지 기다린 뒤에 `runApp()`을 호출함 `확인됨` ✅ 해결
- 해결: `runApp()`을 먼저 호출하고 `initialize()`는 그 뒤에 비동기로 실행합니다. 초기화 중에는 AppBar 아래에 진행 표시줄을 보여주고, 예외는 `lastError`로 보고합니다. 초기화가 겹치는 호출은 무시합니다. 테스트: `test/app_startup_test.dart`. S23에서 권한 팝업 뒤에 스플래시가 아닌 홈 화면이 그려지는 것을 확인했습니다.
- 첫 실행에는 권한 팝업이 스플래시 위에 뜹니다.
- `initialize()`에서 예외가 나면 화면이 영원히 뜨지 않습니다(1번이 그 경우).
- 수정 방향: `runApp()`을 먼저 호출하고, 초기화는 그 뒤에 비동기로 진행합니다. 초기화 중 상태와 실패 상태를 UI에 표시합니다.

### 4. iOS에 GATT server가 없음 `코드` ✅ 해결
- 해결: Android와 같은 characteristic(write, writeWithoutResponse, notify)을 가진 서비스를 등록하고, 서비스가 등록된 뒤에 광고를 시작합니다. write는 `message` 이벤트로, 구독은 `connected`로 처리하고, 답장은 notify로 보냅니다. 전송 큐가 가득 차면 다시 보냅니다. 광고 OFF·Bluetooth OFF·상태 복원도 처리합니다.
- 확인: S23(Android central) ↔ AlgorigoSE(iOS peripheral)에서 `integration_test/peripheral_exchange_test.dart` 통과. 페어링, 연결, S23→iPhone `20261015`, iPhone→S23 `reply from peripheral 안녕`을 확인했습니다. iOS central ↔ Android peripheral 조합과 iOS ↔ iOS 조합은 아직 테스트하지 않았습니다.
- iOS는 서비스 UUID를 광고만 하고 `CBMutableService`를 등록하지 않습니다.
- 그래서 Android central → iOS peripheral 조합과 iOS ↔ iOS 조합에서는 메시지가 오가지 않습니다.
- 수정 방향: Android와 같은 characteristic을 등록합니다(write, writeWithoutResponse, notify).
  - `didReceiveWrite`가 오면 `message` 이벤트를 보냅니다.
  - 구독한 central에는 `updateValue(_:for:onSubscribedCentrals:)`로 답장합니다.
  - 전송 큐가 가득 차면 `peripheralManagerIsReady(toUpdateSubscribers:)`를 기다렸다가 다시 보냅니다.

---

## P1: 기능 오류, 데이터 유실

### 5. 등록된 기기를 삭제하는 UI가 없음 `확인됨` ✅ 해결
- 해결: 기기 화면의 삭제 버튼(확인 팝업 포함)을 누르면 등록 목록, 메시지, 안 읽음 카운트에서 지우고 `disconnectDevice`로 연결을 끊습니다. Android는 대기 중인 `connectGatt`도 취소합니다(central OFF 시에도 남던 문제 포함). 테스트: `test/device_removal_test.dart`, controller의 `removeDevice` 테스트. S23에서 연결 중인 기기를 삭제하면 연결이 끊기고(`connected:2` → `1`), 30초 뒤와 앱 재시작 후에도 다시 연결되지 않는 것을 확인했습니다. iOS의 `disconnectDevice`(central 역할)는 기기에서 확인하지 못했습니다.
- createBond를 도입하기 전에 랜덤 주소로 저장된 항목(`재홍의 S23 41:88…`, `(Unknown)` 등)이 목록에 계속 남아 있습니다.
- 수정 방향
  - 기기 화면이나 목록에 삭제 기능을 넣습니다. 삭제하면 `registeredDevices`, 메시지, 안 읽음 카운트를 함께 지웁니다.
  - 페어링 해제 API(`removeBond`)는 공개 API가 아니므로, 시스템 Bluetooth 설정 화면으로 안내합니다.
  - 네이티브 서비스는 Dart prefs를 직접 읽어서 판단합니다. 그래서 삭제 후에는 자동 재연결 대상에서도 빠지는지 확인해야 합니다.

### 6. 서비스가 시스템에 의해 재시작되면 상태가 복원되지 않음 `코드`
- `START_STICKY` 서비스가 다시 시작될 때는 `intent`가 null로 들어옵니다. 그런데 `onStartCommand`의 `when (intent?.action)`에 해당하는 분기가 없습니다.
- 그 결과 알림은 계속 떠 있는데 광고, 스캔, 재연결은 하나도 동작하지 않습니다.
- 수정 방향: `intent == null`이면 `ACTION_RESTORE`처럼 처리합니다.

### 7. Bluetooth를 껐다 켜는 경우를 처리하지 않음 `코드`
- `BluetoothAdapter.ACTION_STATE_CHANGED`를 받지 않습니다.
- BT를 끄면 `isAdvertising`, `isScanning`, `gattServer` 상태가 실제와 어긋나고, 다시 켜도 아무것도 재시작되지 않습니다. 앱이나 서비스를 다시 시작해야 복구됩니다.
- 수정 방향
  - `STATE_OFF`가 오면 내부 상태와 연결을 정리하고 `disconnected` 이벤트를 보냅니다.
  - `STATE_ON`이 오면 `restoreStateFromPrefs()`를 호출합니다.

### 8. 전송 실패가 "Sent"로 표시됨 `코드`
- Android
  - GATT 작업 큐가 없습니다. Android는 연결 하나당 동시에 GATT 작업 하나만 허용하는데, `writeCharacteristic`과 `notifyCharacteristicChanged`의 반환값을 무시합니다.
  - 그래서 CCCD write가 진행 중이거나 이전 전송이 끝나기 전에 보낸 메시지는 조용히 버려집니다.
  - notify는 `onNotificationSent`를 기다려야 합니다.
- Dart: `sendMessage`는 MethodChannel 호출이 끝나면 바로 "Sent"로 기록합니다. 실제 전송 결과는 비동기로 오기 때문에 둘이 연결되지 않습니다.
- 수정 방향
  - 연결별 GATT 작업 큐를 둡니다.
  - 메시지마다 ID를 붙이고 `sent`/`failed` 이벤트를 추가해서 메시지별 상태(전송 중/완료/실패)를 표시합니다. 메시지 ID는 23번(메시지 프로토콜)과 함께 정합니다.

### 9. Android characteristic이 암호화를 요구하지 않음 `코드`
- 페어링하지 않은 central(iOS 포함)도 GATT server에 연결해서 구독하고 write할 수 있습니다.
- 문제
  - 그런 central은 계속 바뀌는 랜덤 주소로 등록됩니다. 같은 기기가 다른 기기로 보이는 문제가 다시 생깁니다.
  - 근처에 있는 아무 기기나 메시지를 보낼 수 있습니다(보안 문제).
- 수정 방향
  - characteristic과 CCCD를 `PERMISSION_WRITE_ENCRYPTED`/`PERMISSION_*_ENCRYPTED`로 바꿉니다. 그러면 iOS가 자동으로 페어링 팝업을 띄웁니다.
  - 페어링된 Android central은 기존 키로 암호화된 연결을 만드는지 다시 테스트해야 합니다.

### 10. iOS central의 연결과 복원 처리가 불완전함 `코드`
- `connectDevice`가 이번 실행 중에 발견된 기기(`peripherals`)만 찾습니다. 그래서 앱 시작 시 저장된 기기에 연결하는 동작이 아무 일도 하지 않습니다.
  - 수정: `retrievePeripherals(withIdentifiers:)`를 사용합니다.
- `willRestoreState`가 `CBCentralManagerRestoredStatePeripheralsKey`를 처리하지 않습니다. 그래서 백그라운드에서 복원되면 연결 참조를 잃습니다.
- `didFailToConnect`, `didWriteValueFor`(오류), `didUpdateNotificationStateFor`를 처리하지 않습니다. 실패해도 Dart에 알려지지 않습니다.
- 발견된 기기 이름을 `peripheral.name`에서만 읽습니다. Android는 이름을 scan response에 넣으므로 `CBAdvertisementDataLocalNameKey`를 먼저 읽어야 합니다.
- `sendMessage`가 `maximumWriteValueLength(for:)`를 확인하지 않습니다.

### 11. 앱 화면이 없을 때 받은 메시지가 사라짐 `코드`
- `BleEventBus`는 Flutter listener가 없으면 이벤트를 버립니다. 메시지 기록도 Dart 메모리에만 있습니다.
- Android에서는 루트 화면에서 뒤로 가기로 Activity가 종료된 동안 받은 메시지가 사라집니다(확인됨). iOS도 엔진이 없으면 같은 문제가 생깁니다.
- 메시지를 받아도 사용자 알림이 뜨지 않습니다. `POST_NOTIFICATIONS` 권한은 포그라운드 서비스 알림에만 쓰고 있습니다.
- 수정 방향
  - 네이티브에서 메시지를 저장합니다(파일 또는 DB). Dart가 연결되면 저장된 메시지를 다시 보냅니다.
  - 메시지를 받으면 로컬 알림을 띄우고, Dart 쪽 기록도 영구 저장합니다.

---

## P2: 안정성, UX, 배터리

### 12. `onScanFailed`를 구현하지 않음 `코드`
- 스캔 시작이 실패하거나(예: 30초 안에 5번 넘게 시작) 시스템이 스캔을 중단해도 `isScanning`이 true로 남습니다.
- 그러면 `scanNow`와 `startScan`이 영원히 아무 일도 하지 않습니다.

### 13. 스캔 비용(배터리, 성능) `코드`
- central이 켜져 있는 동안 `SCAN_MODE_LOW_LATENCY` + `ALL_MATCHES` 스캔이 멈추지 않습니다. 배터리를 많이 쓰고, Android는 30분이 지나면 스캔 등급을 낮춥니다.
- 광고가 들어올 때마다 `discovered` 이벤트를 보냅니다.
  - Dart는 그때마다 `notifyListeners()`를 호출합니다. `AnimatedBuilder`가 `MaterialApp` 전체를 감싸고 있어서 앱 전체가 다시 빌드됩니다.
  - 네이티브 `onScanResult`는 결과마다 `loadRegisteredDeviceIds()`를 호출해서 SharedPreferences를 읽고 JSON을 파싱합니다.
- 수정 방향
  - 스캔은 시간 제한을 두거나, 화면에 따라 모드를 나눕니다(포그라운드는 LOW_LATENCY, 백그라운드는 LOW_POWER).
  - 네이티브에서 `discovered` 이벤트 중복을 걸러 처음 보이거나 이름이 바뀔 때만 보냅니다.
  - 등록된 기기 ID는 메모리에 캐시합니다.
  - 리빌드 범위를 줄입니다(`MaterialApp` 바깥으로 빼기).

### 14. 채팅 화면을 보고 있는데도 안 읽음 카운트가 늘어남 `확인됨`
- `_handleEvent('message')`는 항상 `unreadCountByDevice`를 올립니다.
- 그래서 채팅 화면을 보면서 받은 메시지도 목록으로 돌아가면 배지로 남아 있습니다.
- 수정 방향: 지금 열려 있는 채팅의 기기 ID를 controller가 알고, 그 기기 메시지는 안 읽음으로 세지 않습니다.

### 15. 오류가 설정 화면에서만 보이고 지워지지 않음 `코드`
- `lastError`는 설정 화면에만 표시되고, 한 번 생기면 계속 남습니다.
- 채팅 화면에서 전송에 실패하거나("No writable BLE connection") 페어링에 실패해도 사용자는 알 수 없습니다.
- 수정 방향: 오류가 나면 SnackBar 같은 일회성 알림으로 보여주고, 오류 이벤트에 `deviceId`를 붙여서 해당 기기 화면에 표시합니다.

### 16. 연결 중이나 페어링 중 상태를 표시하지 않음 `코드`
- `autoConnect` 연결은 오래 걸릴 수 있는데, 버튼은 "연결" 그대로 다시 누를 수 있습니다.
- 수정 방향: `connecting`/`bonding` 상태 이벤트를 추가하고, 그 동안 버튼을 비활성화합니다.

### 17. 메시지 길이 제한을 막지 않음 `코드`
- 쓸 수 있는 값은 최대 512바이트이고, notify는 MTU-3(협상하지 못하면 20바이트)까지입니다.
- Dart 입력창에는 길이 제한이 없어서 긴 메시지는 실패하거나 오류만 납니다.
- 수정 방향: 입력 단계에서 UTF-8 바이트 수를 제한하거나, 프로토콜 차원에서 분할 전송합니다(23번 참고).

### 18. 광고 시작이 겹칠 수 있음 `확인됨`
- S23에서 권한을 허용한 직후 설정 화면에 `Advertising failed: 3`(`ALREADY_STARTED`)이 표시되는 것을 확인했습니다.
- Dart `initialize()`는 `ACTION_RESTORE`(광고 시작)와 `ACTION_START_ADVERTISING`을 연달아 보냅니다.
- `isAdvertising`은 `onStartSuccess`가 와야 true가 되므로, 두 번째 시작이 `ADVERTISE_FAILED_ALREADY_STARTED`로 실패할 수 있습니다.
- 그러면 실제로는 광고 중인데 `isAdvertising=false`가 되고, 오류 이벤트도 나갑니다.
- 수정 방향: "광고 요청됨" 상태를 따로 두고, 코드 3(`ALREADY_STARTED`)은 성공으로 처리합니다.

### 19. 플랫폼 채널 계약이 서로 다름 `코드`
- `status` 문자열 형식이 다릅니다. Android는 `advertising scanning connected:N`, iOS는 `ios-ready`, `advertising-off` 같은 값을 씁니다.
- `initialize` 반환값도 다릅니다. Android는 Bool(권한이 없으면 false), iOS는 nil을 돌려줍니다.
- 수정 방향: 계약 문서를 정리하고, `status`를 구조화된 필드(`advertising`, `scanning`, `connectedCount`)로 바꿉니다.

### 20. 한쪽에서만 페어링을 해제한 경우 복구가 안 됨 `추정`
- 상대 폰에서만 페어링을 해제하면, 이쪽에는 페어링 정보가 남아 있어 `autoConnect`로 계속 재연결을 시도합니다. 하지만 암호화에 실패해서 연결과 끊김이 반복될 수 있습니다.
- 수정 방향: 인증·암호화 관련 오류 status(5, 137 등)를 감지하면 사용자에게 다시 페어링하도록 안내합니다.

### 21. 주변 기기 목록이 정리되지 않음 `코드`
- `discoveredDevices`는 앱이 실행되는 동안 계속 쌓이기만 합니다. 페어링 안 된 기기는 주소가 바뀔 때마다 항목이 하나씩 늘어납니다.
- 페어링한 기기도 페어링 전에 스캔된 주소의 항목이 앱을 재시작할 때까지 `주변 기기`에 남습니다(`확인됨`). 이미 `연결 기록`에 있는 같은 폰이 다른 주소로 한 번 더 보이는 셈입니다.
- 수정 방향: 마지막으로 본 시각을 기록해서 오래된 항목을 지웁니다. 페어링에 성공하면 페어링 전 주소의 항목도 지웁니다. RSSI를 표시해도 좋습니다.

### 22. 권한이 허용된 뒤에도 권한 항목의 제목이 `권한 요청`으로 남음 `확인됨`
- 설정 화면의 권한 항목은 권한을 허용한 뒤에도 제목이 `권한 요청` 그대로이고, 부제만 `Bluetooth 권한 허용됨`으로 바뀝니다. 누를 일이 없는 상태인데 누르라는 문구로 보입니다.
- 수정 방향: 허용 상태에서는 제목을 `권한`(또는 `권한 상태`)으로 바꾸고 누를 수 없게 합니다. 알림 권한만 거부된 경우는 따로 표시하고, 알림 설정으로 이동하는 기능을 넣을 수 있습니다.
- 위치: `lib/main.dart` `SettingsPage`의 권한 `ListTile`

---

## P3: 구조, 품질

### 23. 메시지 프로토콜 정의
- 지금은 UTF-8 바이트만 그대로 보냅니다. 메시지 ID, 타임스탬프, 보낸 기기 이름, 버전, 수신 확인(ack)이 없습니다.
- 이런 문제와 연결됩니다.
  - 중복 수신을 거를 수 없습니다(이중 링크나 재전송 시).
  - 상대가 받았는지 확인할 수 없습니다(8번).
  - 긴 메시지를 나눠 보낼 수 없습니다(17번).
  - iOS central처럼 이름이 없는 peer가 `(Unknown)`으로 보입니다.
- 간단한 프레임(JSON이나 TLV)에 메시지 ID와 ack를 넣는 방식을 권장합니다.

### 24. 페어링된 두 Android 폰 사이에 링크가 두 개 생김
- 두 폰 모두 central이 켜져 있으면 서로의 server에 연결해서 링크가 두 개 생깁니다. 지금은 `emitDisconnectedIfUnlinked`로 연결 상태를 맞추고 있습니다.
- 동작에는 문제가 없지만 연결 슬롯과 배터리를 낭비합니다. 주소를 비교하는 식의 규칙으로 한쪽만 central이 되게 할 수 있습니다.

### 25. 네이티브가 Dart prefs 저장 형식에 의존함
- 서비스가 `FlutterSharedPreferences`의 `flutter.prefs_registered_devices` 키를 직접 파싱합니다.
- 저장 방식이 바뀌면(예: `SharedPreferencesAsync`/DataStore로 이전) 자동 재연결이 조용히 깨집니다.
- 수정 방향: 등록 기기 목록을 메서드 채널로 네이티브에 넘기고, 네이티브가 자체 저장소에 보관합니다.

### 26. 테스트
- 지금은 위젯 스모크 테스트 하나뿐입니다.
- 수정 방향
  - `BleAppController`가 MethodChannel과 EventChannel을 주입받게 해서 `_handleEvent`, 등록, 안 읽음, 메시지 상태 로직을 단위 테스트합니다.
  - 네이티브 쪽은 GATT 작업 큐와 이벤트 중복 제거 로직을 분리해서 테스트합니다.

### 27. 포그라운드 서비스 알림
- 알림을 눌러도 앱이 열리지 않습니다(`contentIntent` 없음).
- 내용도 내부 상태 문자열(`advertising scanning connected:1`)을 그대로 보여줍니다. 사용자가 이해할 수 있는 문구로 바꿔야 합니다.

### 28. 프로젝트 메타데이터
- `README.md`와 `pubspec.yaml`의 description이 Flutter 템플릿 그대로입니다.
- Android의 앱 이름(`android:label`)이 `bluetooth_communicator`입니다.
