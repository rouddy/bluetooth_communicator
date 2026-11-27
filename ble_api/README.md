# ble-api

Bluetooth Communicator의 AIDL 인터페이스(`IBleCommunicator`, docs/protocol.md 11절)와, 설치된 Communicator와 이 앱이 같은 인터페이스로 통신할 수 있는지 알려 주는 `BleApi`입니다. 다른 앱은 `.aidl` 파일을 복사하지 말고 이 라이브러리를 씁니다.

- 좌표: `com.rouddy.bluetooth_communicator:ble-api:<version>`. 버전은 `x.y.z`이고 뒤에 접미사가 붙을 수 있습니다(예: `2.0.0-beta.1`). major는 `IBleCommunicator.API_VERSION`입니다.
- Communicator(`android/`)와 `test_app/`은 배포본 대신 이 디렉터리를 `:ble-api` 프로젝트로 포함해서 빌드합니다.

## 앱에서 쓰기

GitHub Packages의 Maven 저장소는 공개 패키지라도 받을 때 토큰이 필요합니다. `read:packages` 권한의 classic PAT를 `~/.gradle/gradle.properties`에 넣습니다.

```properties
gpr.user=<GitHub 사용자 이름>
gpr.key=<read:packages 권한의 PAT>
```

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/rouddy/bluetooth_communicator")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                password = providers.gradleProperty("gpr.key").orNull
            }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("com.rouddy.bluetooth_communicator:ble-api:2.0.0")
}
```

다른 저장소의 GitHub Actions에서 받으려면, 패키지 설정의 **Manage Actions access**에 그 저장소를 추가하고 `GITHUB_TOKEN`을 씁니다.

라이브러리의 manifest가 Communicator 패키지의 `<queries>`와, 상대가 읽는 `<meta-data>`(버전, 최소 호환 버전, AIDL 해시)를 앱에 병합합니다. 앱에서 따로 넣을 것은 없습니다.

### 호환성 확인

bind하기 전에 확인합니다. Communicator가 업데이트되면 `onBindingDied`가 오므로, 다시 bind하기 전에도 확인합니다.

```kotlin
when (BleApi.checkCommunicator(context)) {
    BleCompatibility.COMPATIBLE -> bind()
    BleCompatibility.NOT_INSTALLED -> // Communicator 설치 안내
    BleCompatibility.COMMUNICATOR_UPDATE_REQUIRED -> // Communicator 업데이트 안내
    BleCompatibility.LIBRARY_UPDATE_REQUIRED -> // 이 앱의 업데이트 안내
    BleCompatibility.AIDL_MISMATCH -> // 개발 빌드끼리의 불일치: 같은 API_VERSION, 다른 AIDL
}
```

| 결과 | 뜻 |
|---|---|
| `COMPATIBLE` | 같은 인터페이스이거나, 더 새로운 쪽이 오래된 쪽을 아직 지원합니다 |
| `COMMUNICATOR_UPDATE_REQUIRED` | Communicator가 이 앱의 ble-api보다 너무 오래됐거나, 이 확인이 생기기 전 빌드입니다 |
| `LIBRARY_UPDATE_REQUIRED` | 앱의 ble-api가 Communicator보다 너무 오래됐거나, 앱이 ble-api 없이 AIDL을 복사해 씁니다 |
| `AIDL_MISMATCH` | `API_VERSION`은 같은데 AIDL이 다릅니다. 버전을 올리지 않고 인터페이스를 바꾼 빌드입니다 |
| `NOT_INSTALLED` | 상대가 설치되어 있지 않거나 보이지 않습니다 |

- 판정은 더 새로운 쪽이 합니다. 무엇이 바뀌었는지는 그쪽만 알기 때문입니다. 오래된 쪽의 `API_VERSION`이 새로운 쪽의 `MIN_COMPATIBLE_VERSION` 이상이면 호환입니다.
- 오래된 Communicator와 `COMPATIBLE`이어도, 그 Communicator의 `getApiVersion()`보다 새로운 메서드는 없습니다.
- 결과는 예외가 아니라 값입니다. 호환되지 않는 것은 실패가 아니라 앱이 사용자에게 안내할 상태이고, `when`이 모든 경우를 다루게 합니다. bind를 막을지는 앱이 정합니다.
- Communicator도 같은 방법으로 등록된 앱을 확인해서, 설정 화면의 **연동된 앱**에 표시합니다(`BleApi.checkApp`).

## AIDL을 바꿀 때

1. 메서드의 transaction id(`= n`)는 바꾸지 않습니다. 새 메서드는 다음 id로 끝에 추가하고, parcelable 필드도 끝에만 추가합니다.
2. `IBleCommunicator.API_VERSION`을 올리고, `gradle.properties`의 `bleApi.version` major를 맞춥니다.
3. 오래된 앱이나 Communicator가 더는 동작하지 않는 변경이면 `bleApi.minCompatibleVersion`을 올립니다.
4. 배포하기 전에 `./gradlew freezeBleApi`로 해시를 `frozen-api.properties`에 기록하고 커밋합니다.

빌드가 이 규칙을 지키게 합니다.
- 해시는 AIDL 파일들에서 주석과 서식을 뺀 SHA-256입니다(`./gradlew bleApiInfo`로 출력). 주석만 고치면 바뀌지 않습니다.
- 모든 빌드(`checkBleApi`)는 동결된 버전의 AIDL이 바뀌면 실패합니다.
- release 빌드(`checkBleApiFrozen`: 배포, Communicator의 release APK)는 지금 버전이 동결되지 않았어도 실패합니다. 그래서 배포되는 것은 언제나 동결된 인터페이스입니다.

## 배포

`.github/workflows/ble-api.yml`이 `ble_api/`가 바뀔 때마다 검사, 테스트, 빌드를 합니다. 태그 `bleApi/<x.y.z><접미사>`를 push하면 GitHub Packages에 배포합니다.

- `x.y.z`는 `gradle.properties`의 `bleApi.version`과 같아야 합니다. 다르면 workflow가 멈춥니다.
- 배포 버전은 `bleApi/` 뒤의 전체입니다. 접미사는 없어도 되고, Maven 버전에 쓸 수 있는 문자(영문, 숫자, `.`, `_`, `+`, `-`)만 됩니다.

```bash
git tag bleApi/2.0.0           # 2.0.0으로 배포
git tag bleApi/2.0.0-beta.1    # 2.0.0-beta.1로 배포
git push origin bleApi/2.0.0
```

- 같은 버전은 다시 배포할 수 없습니다. AIDL은 그대로이고 라이브러리만 고쳤다면 patch(`2.0.1`)를 올립니다.
- 로컬에서 접미사가 붙은 버전으로 빌드하려면 `-PbleApi.publishVersion=2.0.0-beta.1`을 넘깁니다. 이 값도 앞부분이 `bleApi.version`과 같아야 합니다.
- 로컬 확인: `./gradlew checkBleApi testDebugUnitTest assembleRelease` (`local.properties`의 `sdk.dir` 또는 `ANDROID_HOME`이 필요합니다).
