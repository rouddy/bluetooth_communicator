# BLE Test App

BLE Communicator의 AIDL 서비스(docs/protocol.md 11절)를 써서, 페어링된 상대 폰에 설치된 **같은 앱**과 텍스트를 주고받는 테스트 앱입니다.

## 빌드와 설치

```bash
cd test_app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

- `local.properties`에 `sdk.dir`이 필요합니다(Android Studio로 열면 만들어집니다).
- AIDL 파일은 따로 복사하지 않고 `android/app/src/main/aidl`을 그대로 컴파일합니다.
- 상대 앱의 인증서 해시가 같아야 하므로, 두 폰에 같은 키(같은 컴퓨터의 debug 키 등)로 빌드한 APK를 설치합니다.

## 사용법

1. 두 폰에 BLE Communicator와 이 앱을 설치합니다.
2. BLE Communicator에서 상대 기기와 연결(앱 페어링)합니다.
3. 이 앱을 열면 상대 기기가 목록에 나옵니다. 메시지를 입력하고 보내기를 누릅니다.

- 보낸 메시지에는 결과(`전달됨`, `받을 앱 없음`, `보내지 못함(시간 초과)` 등)가 표시됩니다.
- 앱이 열려 있으면 등록한 listener로, 닫혀 있으면 `ReceiveService`로 받습니다. 닫혀 있는 동안 받은 메시지는 앱을 열면 보입니다.
- 스크립트용: `adb shell "am start -n com.rouddy.bluetooth_communicator.testapp/.MainActivity --es text '보낼 내용'"`은 연결된 첫 기기로 보냅니다. 결과는 `adb logcat -s TestApp`에 남습니다.
