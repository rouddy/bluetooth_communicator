# 앱 배포 (fastlane + GitHub Actions)

태그 `app/<pubspec.yaml의 버전>`을 push하면 [.github/workflows/release.yml](../.github/workflows/release.yml)이 [fastlane/Fastfile](../fastlane/Fastfile)로 두 앱을 배포합니다.

| 플랫폼 | lane | 결과 |
|---|---|---|
| Android | `bundle exec fastlane android internal` | upload 키로 서명한 AAB를 Play **내부 테스트** 트랙에 올립니다 |
| iOS | `bundle exec fastlane ios beta` | App Store용으로 서명한 IPA를 **TestFlight**에 올립니다(심사 제출은 사람이 함) |

- 버전 이름은 `pubspec.yaml`의 `version`에서 가져옵니다. 태그는 `app/x.y.z` 형태여야 하고(접미사 없음), `x.y.z`가 그 버전 이름과 같아야 합니다. 다르면 workflow가 멈춥니다.
- 빌드 번호는 각 스토어에서 정합니다. Play는 모든 트랙의 version code 중 가장 큰 값 + 1이고, TestFlight는 최신 빌드 번호 + 1입니다. 그래서 `version`의 `+n`은 쓰이지 않습니다.
- Actions 화면의 **Run workflow**로 한 플랫폼만 실행할 수도 있습니다. 이때는 태그를 확인하지 않습니다.

## 배포하기

1. `pubspec.yaml`의 `version`을 올립니다(예: `1.2.0+1`).
2. release 브랜치를 master에 병합합니다.
3. 태그를 push합니다.

```bash
git tag app/1.2.0
git push origin app/1.2.0
```

## 처음 한 번 준비할 것

### Android

1. **upload 키**를 만들고 안전한 곳에 백업합니다. 잃어버리면 Play Console에서 키 재설정을 요청해야 합니다.
   ```bash
   keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Play Console에서 앱(`com.rouddy.bluetooth_communicator.bluetooth_communicator`)을 만들고, Play 앱 서명을 사용합니다.
3. **첫 AAB는 직접 올립니다.** API는 이미 업로드가 있는 앱에만 올릴 수 있습니다.
   - `android/key.properties`를 만듭니다(`.gitignore`에 들어 있음). `storeFile`은 `android/` 기준 경로입니다.
     ```properties
     storeFile=upload-keystore.jks
     storePassword=…
     keyAlias=upload
     keyPassword=…
     ```
   - `flutter build appbundle --release`로 만든 `build/app/outputs/bundle/release/app-release.aab`를 내부 테스트 트랙에 올립니다.
4. **서비스 계정**을 준비합니다.
   - Google Cloud 콘솔에서 서비스 계정을 만들고 JSON 키를 발급합니다. 그 프로젝트에서 Google Play Android Developer API를 사용 설정합니다.
   - Play Console의 **사용자 및 권한**에서 그 계정의 이메일을 초대하고, 이 앱의 테스트 트랙 출시 권한을 줍니다.
5. 앱이 아직 한 번도 공개되지 않았다면 Play는 `draft` 출시만 받습니다. 그동안은 저장소 Variables에 `PLAY_RELEASE_STATUS=draft`를 두고, Play Console에서 출시 버튼을 직접 누릅니다.

### iOS

1. App Store Connect에 앱을 등록합니다(번들 ID `com.rouddy.bluetoothcommunicator.bluetoothCommunicator`, 팀 `B56B7YRWDS`). 번들 ID는 한 팀에만 등록될 수 있으므로, 예전 팀(`7AZGU4T6FD`)에 이미 등록돼 있다면 그쪽에서 지운 뒤 등록합니다.
2. **App Store Connect API 키**를 만듭니다.
   - Users and Access > Integrations > App Store Connect API에서 팀 키를 만듭니다.
   - 역할은 App Manager 이상이어야 하고, 프로파일을 만들려면 인증서·식별자·프로파일 접근 권한이 있어야 합니다.
   - `.p8` 파일은 한 번만 내려받을 수 있습니다. Key ID와 Issuer ID도 적어 둡니다.
3. **Apple Distribution 인증서**를 `.p12`로 내보냅니다.
   - 인증서가 없으면 Xcode > Settings > Accounts > Manage Certificates에서 Apple Distribution 인증서를 만듭니다.
   - 키체인 접근에서 인증서와 개인 키를 함께 `.p12`로 내보내고 암호를 정합니다.
   - 인증서는 1년 동안 유효하므로, 만료되면 새로 만들어 Secret을 바꿉니다.
   - API 키만으로는 부족합니다. Apple은 서명 개인 키를 보관하지 않으므로, 매번 새로 만들어지는 CI 머신은 이 인증서 없이는 서명하지 못합니다. 프로파일은 lane이 API 키로 만들거나 내려받습니다.
4. **수출 규정(암호화)**: 이 앱은 자체 프로토콜에서 CryptoKit(Apple OS 내장)의 표준 알고리즘(AES-GCM, P-256 ECDH, HKDF)을 씁니다. 이를 수출 서류가 필요 없는 사용으로 판단해서, `Info.plist`에 `ITSAppUsesNonExemptEncryption = false`를 넣었습니다. 그래서 빌드마다 수출 규정 질문을 묻지 않습니다.
   - 암호화 사용이 바뀌면 다시 판단합니다. 예를 들어 Apple OS가 아닌 암호 라이브러리를 쓰거나 비표준 알고리즘을 쓰는 경우입니다.
   - 서류를 제출해야 한다면, 값을 `true`로 바꾸고 Apple이 준 코드를 `ITSEncryptionExportComplianceCode`에 넣습니다.
5. TestFlight 내부 테스터는 처리가 끝나면 바로 받습니다. 외부 테스터에게는 베타 심사가 필요합니다.

### GitHub Secrets

Settings > Secrets and variables > Actions에 넣습니다. 두 job은 `release` environment에서 실행되므로, 그 environment에 넣고 승인자를 지정할 수도 있습니다. environment는 첫 실행 때 자동으로 만들어집니다. 공개 저장소지만, fork에서 온 PR에는 Secrets가 전달되지 않습니다.

| 이름 | 내용 |
|---|---|
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | `base64 -i upload-keystore.jks` |
| `ANDROID_UPLOAD_KEYSTORE_PASSWORD` | keystore 암호 |
| `ANDROID_UPLOAD_KEY_ALIAS` | 키 alias(위 예에서는 `upload`) |
| `ANDROID_UPLOAD_KEY_PASSWORD` | 키 암호 |
| `PLAY_SERVICE_ACCOUNT_JSON` | 서비스 계정 JSON 키 파일 내용 그대로 |
| `ASC_KEY_ID` | API 키의 Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_<KEY_ID>.p8` |
| `IOS_DIST_CERT_P12_BASE64` | `base64 -i distribution.p12` |
| `IOS_DIST_CERT_PASSWORD` | `.p12` 암호 |

Variables(선택): `PLAY_RELEASE_STATUS`(기본값 `completed`, 위 Android 5번 참고).

macOS에서는 `base64 -i <파일> | pbcopy`로 복사해서 붙여 넣으면 됩니다.

## 주의할 점

- **Android 서명이 바뀝니다.**
  - `android/key.properties`가 있으면 release 빌드는 upload 키로 서명됩니다. 없으면 예전처럼 debug 키로 서명됩니다.
  - Play에서 설치한 앱은 Google의 앱 서명 키로 서명되어 있습니다. 그래서 개발용(debug 키) 빌드와는 서로 덮어 설치할 수 없습니다. 바꾸려면 앱을 지우고 설치해야 하고, 그러면 페어링과 peerId가 사라집니다.
  - 연동 앱에는 영향이 없습니다. AIDL은 연동 앱의 인증서만 확인하고 Communicator 자신의 인증서는 확인하지 않습니다.
- release 빌드는 ble-api의 지금 `API_VERSION`이 동결되어 있어야 합니다(`checkBleApiFrozen`, [ble_api/README.md](../ble_api/README.md)).
- `ios beta` lane은 CI에서만 실행됩니다. checkout의 `Runner` 서명을 수동(Apple Distribution과 그 프로파일)으로 바꾸기 때문입니다. 저장소의 프로젝트는 개발용 자동 서명 그대로입니다.
- `Gemfile.lock`이 아직 없어서 CI는 매번 fastlane 2.x의 최신 버전을 설치합니다. 로컬에서 `bundle install`을 한 번 하고 `Gemfile.lock`을 커밋하면 버전이 고정됩니다. 그 뒤에는 workflow의 `bundle install` 단계를 `ruby/setup-ruby`의 `bundler-cache: true`로 바꿔 캐시할 수 있습니다.
- 업로드가 실패하면 다시 실행하면 됩니다. 빌드 번호는 매번 스토어에서 다시 읽습니다.

## 문제 해결

### Android: `Google Api Error: ... The caller does not have permission`

Play가 서비스 계정의 요청을 거부한 것입니다. lane은 트랙을 하나도 읽지 못하면 빌드하기 전에 멈춥니다.

- Play Console의 **사용자 및 권한**에 서비스 계정 이메일(`PLAY_SERVICE_ACCOUNT_JSON`의 `client_email`)이 초대돼 있는지 확인합니다.
- 이 앱(`com.rouddy.bluetooth_communicator.bluetooth_communicator`)에 대한 테스트 트랙 출시 권한이 있는지 확인합니다. 앱을 지정하지 않고 계정 권한만 주면 이 앱에는 적용되지 않을 수 있습니다.
- JSON 키를 만든 Google Cloud 프로젝트에서 Google Play Android Developer API가 사용 설정돼 있는지 확인합니다.
- 권한을 방금 줬다면 적용되기까지 시간이 걸릴 수 있습니다(최대 하루 정도).
- 로그에 패키지 이름이 `com.***.…`처럼 보이는 것은, 값이 `rouddy`인 Secret이 있어서 GitHub가 가린 것입니다. 패키지 이름이 틀린 것은 아닙니다.

### iOS: `No valid Apple Distribution identity of team B56B7YRWDS`

가져온 `.p12`로 서명할 수 없는 것입니다. 에러에 키체인의 identity 목록이 나오고, 유효하지 않은 identity는 이유(`CSSMERR_TP_NOT_TRUSTED`, `CSSMERR_TP_CERT_EXPIRED` 등)가 함께 나옵니다. 목록이 비어 있다면 `.p12`에 개인 키가 없는 것입니다.

원본 `.p12`를 로컬에서 확인합니다(OpenSSL 3이면 `-legacy`가 필요할 수 있습니다).

```bash
# 1 이상이어야 합니다: 개인 키가 들어 있음
openssl pkcs12 -in distribution.p12 -nodes -nocerts | grep -c "PRIVATE KEY"
# subject가 "Apple Distribution: … (B56B7YRWDS)"이고, notAfter가 지나지 않아야 합니다
openssl pkcs12 -in distribution.p12 -nokeys | openssl x509 -noout -subject -enddate
```

- 키체인 접근에서 내보낼 때는 **내 인증서** 항목에서 인증서를 펼쳐 개인 키가 함께 있는지 확인하고, 인증서와 개인 키를 함께 내보냅니다. 개인 키가 없는 인증서(다른 Mac에서 만든 것)는 만든 Mac에서 내보내거나 새로 만듭니다.
- 팀을 `B56B7YRWDS`로 바꾨으므로, 예전 팀(`7AZGU4T6FD`)의 인증서는 쓸 수 없습니다.
- 새 `.p12`를 넣을 때는 `IOS_DIST_CERT_P12_BASE64`와 `IOS_DIST_CERT_PASSWORD`를 함께 바꿉니다.
