# Bluetooth Communicator

휴대폰끼리 BLE로 연결해서, 다른 앱이 페어링된 상대 폰의 같은 앱과 데이터를 주고받게 해 주는 Flutter 앱입니다(Android, iOS).

- **앱 페어링:** 두 폰에 같은 6자리 코드가 뜨고, 양쪽 사용자가 승인하면 키를 나눠 갖습니다. 그 뒤로는 자동으로 다시 연결합니다.
- **AIDL(Android):** 다른 앱이 `IBleCommunicator`로 상대 폰의 같은 앱(같은 패키지, 같은 서명)에 메시지를 보내고 받습니다. 예시는 `test_app/`에 있습니다.
- **내장 기능:** 클립보드 가져오기, 파일 보내기, 상대 폰(Android)의 음악·동영상 재생 조작.
- BLE와 프로토콜은 모두 네이티브(Kotlin, Swift)에 있어서 Flutter UI가 없어도 동작합니다. Dart는 연결과 페어링 화면만 맡습니다.

## 문서

- [docs/protocol.md](docs/protocol.md): 프로토콜 명세(프레임, 핸드셰이크, 세션, 전달, 내장 기능, AIDL)
- [CLAUDE.md](CLAUDE.md): 구조, 플랫폼 채널 계약, 빌드와 테스트 명령, 기기에서 확인한 내용과 알려진 한계
- [TODO.md](TODO.md): 남은 일과 지금까지 고친 문제

## 빌드와 테스트

```bash
flutter pub get
flutter run                                       # BLE는 실제 기기가 필요합니다
flutter test                                      # Dart 테스트
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin 테스트(프로토콜 엔진 포함)
```

iOS 프로토콜 테스트, 두 폰을 쓰는 통합 테스트, AIDL 테스트 앱 빌드 방법은 CLAUDE.md의 Commands에 있습니다.
