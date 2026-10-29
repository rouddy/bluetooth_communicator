# BLE 메시지 프로토콜 v1

> 상태: **설계만 끝났고 아직 구현하지 않았습니다.** 관련 TODO: 23번(17, 24번과도 연결).
> 지금 구현은 메시지를 UTF-8 바이트 그대로 write 또는 notify 한 번으로 보냅니다. 이 문서의 프로토콜과는 호환되지 않습니다.

## 1. 목표와 범위

지금의 텍스트 채팅은 이 프로토콜을 만들고 검증하기 위한 수단입니다. 실제로 만들려는 기능은 두 가지입니다.

1. **원격 조작**: 상대 폰의 음악 재생, 정지 같은 간단한 조작
2. **앱 간 통신 중계**: 다른 Android 앱이 AIDL로 이 앱을 거쳐 상대 폰에 있는 **같은 앱**과 데이터를 주고받음

범위에서 뺀 것
- **Wi-Fi 테더링**: 일반 앱은 켜고 끌 수 없습니다. `TetheringManager`는 시스템 API이고 `TETHER_PRIVILEGED`가 필요합니다. 일반 앱이 쓸 수 있는 `startLocalOnlyHotspot`은 인터넷을 공유하지 않습니다. iOS도 개인용 핫스팟을 앱에서 제어할 수 없습니다.
- **대용량 전송**: GATT 처리량은 초당 수 KB에서 수십 KB 정도입니다. 파일 전송이 필요해지면 L2CAP CoC(Android 10+, iOS 11+)로 Frame 계층만 바꿉니다.
- **iOS의 앱 간 통신**: iOS에는 AIDL에 해당하는 수단이 없습니다. iOS는 원격 조작을 하는 쪽과 `/debug/chat`만 지원합니다.
- **오래 보관했다가 전달(store-and-forward)**: v1의 TTL은 최대 60초입니다.

설계 원칙
- 프로토콜은 네이티브(Android `BluetoothBackgroundService`, iOS `IOSBleBackgroundManager`)에 구현합니다. 명령 실행과 AIDL은 Flutter가 실행 중이 아니어도 동작해야 하기 때문입니다. Dart는 UI와 디버그용 클라이언트입니다.
- 정수는 모두 little-endian입니다.
- 블루투스 bond는 계속 필요합니다. bond가 있어야 주소가 고정되고(RPA 해석) 링크가 암호화됩니다. 그 위에 앱 수준 인증을 얹습니다(6절).

## 2. 용어

| 용어 | 뜻 |
|---|---|
| deviceId | 링크 수준 주소. Android는 MAC, iOS는 `CBPeripheral`/`CBCentral`의 identifier. 연결할 때만 씁니다 |
| peerId | 앱을 설치할 때 한 번 만드는 16바이트 UUID. 공개 값입니다 |
| K | peer 쌍마다 앱 페어링으로 만드는 32바이트 비밀 키 |
| 링크 | 한 역할로 맺은 GATT 연결 하나. 두 폰 사이에는 하나만 둡니다(9절) |
| C / P | 그 링크의 central / peripheral |
| 세션 | 링크 하나 위에서 인증을 마친 상태와 그 세션 키 |
| low / high | 두 peerId를 바이트 순서로 비교했을 때 작은 쪽 / 큰 쪽. 두 링크가 동시에 생겼을 때 하나를 고르는 데만 씁니다(9절) |

표기: `‖`는 이어 붙이기, `H`는 SHA-256, `HMAC(k, m)`은 HMAC-SHA256입니다. 따옴표 안의 문자열은 ASCII 바이트입니다.

## 3. 계층 구조

```
payload    /control/media, /debug/chat, <패키지명>/...
Envelope   DATA, ACK, CAPS, UNPAIR             ← SEALED record 안에만 있음
Record     핸드셰이크(평문): HELLO, AUTH, PAIR_*, REJECT
           SEALED(AES-GCM): Envelope 하나
Frame      record를 ATT 패킷 크기로 나누고 다시 합침
GATT       message characteristic (central은 write, peripheral은 notify)
```

평문으로 오가는 것은 핸드셰이크 record뿐이고, 그 뒤의 모든 메시지는 SEALED record로 감쌉니다.

## 4. Frame

ATT 패킷(write 하나 또는 notification 하나)마다 프레임 하나가 실립니다.

| byte | 내용 |
|---|---|
| 0 | bit7 `S`(첫 조각), bit6 `E`(마지막 조각), bit0–5 `tid`(전송 번호 0–63) |
| 1–4 | record 전체 길이 u32. `S=1, E=0`일 때만 있습니다 |
| 나머지 | 조각 데이터 |

- 조각 하나의 최대 크기(헤더 포함)는 그 링크의 ATT MTU − 3입니다.

  | 링크 | MTU를 얻는 곳 |
  |---|---|
  | Android client | `onMtuChanged` (`requestMtu(517)` 결과) |
  | Android server | `BluetoothGattServerCallback.onMtuChanged`. 오지 않으면 23 |
  | iOS central | `maximumWriteValueLength(for: .withoutResponse)`. `.withResponse`는 MTU와 상관없이 512(long write 한도)를 돌려주므로 쓰지 않습니다 |
  | iOS peripheral | `CBCentral.maximumUpdateValueLength` |

- record가 한 조각에 들어가면 `S=1, E=1`이고 길이 필드가 없습니다. 오버헤드는 1바이트입니다.
- 보내는 쪽은 링크마다 `tid` 0–63을 돌려 쓰고, 끝나지 않은 tid는 다시 쓰지 않습니다. 받는 쪽은 (링크, tid)마다 버퍼를 둡니다.
- 서로 다른 tid의 조각은 섞여 올 수 있고, 받는 쪽은 이것을 반드시 처리해야 합니다. 같은 tid 안에서는 순서대로 옵니다. 그래서 큰 record를 보내는 중에도 ACK이나 명령을 끼워 보낼 수 있습니다.
- 한 record의 조각은 모두 같은 링크로 보냅니다. 링크가 끊기면 그 링크의 미완성 버퍼를 모두 버립니다.
- 받는 쪽은 이런 경우 그 tid의 버퍼를 버립니다.
  - `S` 없이 시작한 조각이 옴
  - 진행 중인 tid에 `S`가 다시 옴. 이전 버퍼를 버리고 새로 시작합니다
  - 누적 길이가 선언한 길이나 `maxMessageSize`를 넘음
  - `E`가 왔는데 길이가 선언한 값과 다름
- 전송 방식: central은 지금처럼 write with response를 `GattOperationQueue`로 하나씩 보내고, peripheral은 notification을 씁니다. 모든 조각이 MTU − 3 이하이므로 long write(prepared write)는 더 이상 쓰지 않습니다.
- `maxMessageSize`는 다시 합친 record의 최대 크기입니다. v1은 65,536바이트이고 HELLO로 교환합니다. 보내려는 record가 상대 값을 넘으면 보내지 않고 로컬에서 `TOO_LARGE`로 실패시킵니다.
- MTU 협상을 못 해서 조각이 20바이트면 짧은 명령도 3조각이 됩니다(10절의 media 명령이 약 45바이트).

## 5. Record

모든 record는 `u8 version`, `u8 type`으로 시작합니다. v1의 version은 1입니다.

| type | 이름 | 형태 | body |
|---|---|---|---|
| 0x01 | HELLO | 평문 | TLV (6.2) |
| 0x02 | AUTH | 평문 | `mac[32]` |
| 0x03 | PAIR_REQUEST | 평문 | 없음 |
| 0x04 | PAIR_COMMIT | 평문 | `commit[32]` |
| 0x05 | PAIR_KEY | 평문 | `pk[65]` (P-256, X9.62 uncompressed) |
| 0x06 | PAIR_CONFIRM | 평문 | `mac[32]` |
| 0x07 | REJECT | 평문 | `u8 reason` (6.5) |
| 0x10 | SEALED | 암호 | 아래 표 |

**TLV**: `u8 tag`, `u16 len`, `value[len]`를 반복합니다. 모르는 tag는 건너뜁니다. HELLO와 CAPS가 씁니다.

**SEALED**

| off | size | field |
|---|---|---|
| 0 | 1 | version |
| 1 | 1 | type = 0x10 |
| 2 | 4 | counter u32 |
| 6 | n | 암호문 (Envelope, 7절) |
| 6+n | 16 | GCM tag |

- 암호는 AES-256-GCM이고, 키는 세션의 방향별 키입니다(6.4).
- nonce(12바이트)는 `counter(u32 LE) ‖ 0x00 × 8`이고, AAD는 0–5번 바이트입니다.
- counter는 세션·방향마다 0부터 1씩 늘립니다. 한계에 닿으면 C가 링크를 닫습니다.
- 받는 쪽은 최근 64개짜리 재전송 윈도우를 둡니다(가장 큰 counter와 비트맵). 이미 받은 counter나 윈도우보다 오래된 counter는 버립니다. 조각이 섞여 오므로 record가 완성되는 순서는 counter 순서와 다를 수 있습니다.

## 6. 핸드셰이크

### 왜 앱 수준 인증이 필요한가

블루투스 bond는 **기기**를 인증할 뿐 **앱**을 인증하지 않습니다. 한 폰의 여러 앱이 같은 상대에 연결하면 링크(ATT bearer) 하나를 공유합니다. 그래서 상대 GATT server는 어느 앱이 write했는지 구분하지 못하고, 같은 characteristic을 구독한 다른 앱도 notification을 받을 수 있습니다. 따라서 이렇게 합니다.

- 연결할 때 한 번만 확인해서는 부족하고, **메시지마다** 인증하고 암호화합니다(SEALED).
- 비밀 키 K는 처음 한 번 ECDH로 만들고, 그 뒤에는 절대 전송하지 않습니다.
- 공개 식별자(peerId)와 비밀(K)은 분리합니다.

### 6.1 순서

핸드셰이크의 순서는 링크에서의 역할로 정해집니다. C는 그 링크의 central, P는 peripheral입니다.

```
C → P  HELLO_c                    C가 CCCD 구독을 마치면 보냄
P → C  HELLO_p                    같은 peer와 이미 링크가 있으면 대신 REJECT(ALREADY_CONNECTED) (9절)
C → P  AUTH_c                     C에 P의 K가 있을 때
       또는 PAIR_REQUEST          사용자가 연결 버튼으로 시작한 링크이고, K가 없거나 다시 페어링이 필요할 때 (6.3)
       또는 REJECT(UNKNOWN_PEER)  둘 다 아닐 때
P → C  AUTH_p                     AUTH_c가 맞으면. 이것으로 세션이 맺어짐
       또는 PAIR_COMMIT …         PAIR_REQUEST를 받았을 때 (6.3)
       또는 REJECT                K가 없거나(UNKNOWN_PEER) mac이 틀렸을 때(BAD_MAC)
```

- 상대의 핸드셰이크 record를 기다리는 동안에는 다른 record를 보내지 않습니다.
- P는 AUTH_c를 검증하고 AUTH_p를 보내면 세션이 맺어지고, C는 AUTH_p를 검증하면 세션이 맺어집니다. Dart의 `connected` 이벤트는 이 시점에 보냅니다.
- REJECT를 보내거나 받으면 그 링크의 핸드셰이크는 끝납니다. **링크는 C가 닫습니다.** iOS peripheral은 central과의 연결을 끊을 수 없기 때문입니다.

### 6.2 HELLO

| tag | 이름 | 값 | |
|---|---|---|---|
| 0x01 | peerId | 16바이트 | 필수 |
| 0x02 | nonce | 16바이트 | 필수. 링크마다 새로 만든 난수 |
| 0x03 | name | UTF-8, 64바이트 이하 | 표시 이름 |
| 0x04 | platform | u8 | 1 Android, 2 iOS |
| 0x05 | appVersion | UTF-8 | |
| 0x06 | maxMessageSize | u32 | |

- HELLO의 version은 보내는 쪽이 지원하는 가장 높은 버전입니다. 양쪽은 둘 중 낮은 버전으로 동작하고, 공통 버전이 없으면 REJECT(UNSUPPORTED_VERSION)입니다.
- name: Android는 `Settings.Global.DEVICE_NAME`을 씁니다. iOS는 16부터 별도 entitlement 없이는 `UIDevice.name`이 "iPhone"만 돌려주므로, 앱 설정에서 이름을 받습니다(기본값 "iPhone").
- `T_hello = H(HELLO_c ‖ HELLO_p)`. 각 HELLO는 다시 합친 record 바이트 전체입니다.
- HELLO는 평문이지만 T_hello가 AUTH와 세션 키에 들어갑니다. 그래서 내용을 바꿔치기하면 AUTH가 실패합니다. nonce가 링크마다 새로 만들어지므로, 다른 링크에서 엿본 AUTH도 통하지 않습니다.

### 6.3 앱 페어링

**페어링은 P가 시작합니다.** C가 PAIR_REQUEST로 요청하면 P가 PAIR_COMMIT으로 키 교환을 시작합니다. P-256 ECDH로 K를 만들고, 양쪽 화면에 같은 확인 코드를 띄워 사용자 승인을 받습니다. 이 승인이 **peer별 사용자 승인**입니다.

```
[OS 페어링 (숫자 비교)]                       ← 지금과 같음
C ⇄ P  HELLO_c, HELLO_p
C → P  PAIR_REQUEST
P → C  PAIR_COMMIT  c = H("rbc-commit-v1" ‖ pk_P)
C → P  PAIR_KEY     pk_C
P → C  PAIR_KEY     pk_P                      ← C가 c와 맞는지 확인
       양쪽: K 계산, 확인 코드 표시, 사용자 승인 대기 (60초)
C ⇄ P  PAIR_CONFIRM (각자 승인한 뒤)
       양쪽: 내가 승인했고 상대 CONFIRM이 맞으면 K 저장
C → P  AUTH_c,  P → C  AUTH_p                 (6.4)
```

- 커밋을 먼저 보내는 이유는, 중간에 끼어든 쪽이 상대 공개키를 본 뒤에 확인 코드가 우연히 같아지는 키를 고를 수 없게 하기 위해서입니다(블루투스 숫자 비교와 같은 방식).
- 계산식
  - `T_pair = H(T_hello ‖ pk_P ‖ pk_C)`
  - `Z` = ECDH 결과(x 좌표 32바이트)
  - `K = HKDF-SHA256(IKM = Z, salt = T_pair, info = "rbc-pair-key-v1", L = 32)`
  - 확인 코드 = (`H("rbc-code-v1" ‖ T_pair)` 앞 4바이트의 u32) mod 1,000,000, 앞에 0을 채운 6자리
  - PAIR_CONFIRM의 mac = `HMAC(K, "rbc-confirm-v1" ‖ 보내는 쪽 peerId ‖ T_pair)`
- **승인 화면은 누군가 연결 버튼을 눌렀을 때만 뜹니다.** 그 이유는 두 가지입니다.
  - C는 사용자가 연결 버튼으로 시작한 링크(`connectDevice{pair: true}`)에서만 PAIR_REQUEST를 보냅니다.
  - 자동 재연결은 K가 있는 peer에만 합니다.

  그래서 거절했거나 삭제한 기기가 승인 화면을 반복해서 띄우지 않고, 차단 목록이 필요 없습니다.
- C 쪽 화면은 사용자가 직접 연결을 눌렀으니 예상한 화면이고, P 쪽 승인이 상대 기기 사용자의 동의입니다. 두 화면 모두 코드를 보여 주고, 양쪽이 모두 승인해야 합니다.
- P가 PAIR_REQUEST를 받으면
  - 승인 화면을 띄울 수 없으면 REJECT(CANNOT_PROMPT)를 보냅니다. iOS 앱이 백그라운드에 있을 때가 그렇습니다(iOS에는 아직 알림 흐름이 없음). Android는 백그라운드면 알림으로 승인 화면을 엽니다.
  - 이미 K가 있는 peer면 "다시 페어링" 문구로 묻습니다. 상대가 이 기기를 삭제했다가 다시 연결하는 경우입니다.
- 어느 쪽이든 거절하면 REJECT(USER_REJECTED), 60초가 지나면 REJECT(TIMEOUT)를 보냅니다.

### 6.4 AUTH와 세션 키

- `AUTH.mac = HMAC(K, "rbc-auth-v1" ‖ 보내는 쪽 peerId ‖ T_hello)`
- 세션 키: `k(X→Y) = HMAC(K, "rbc-session-v1" ‖ peerId_X ‖ peerId_Y ‖ T_hello)`. X가 Y에게 보내는 SEALED에 씁니다.
- 방향마다 키가 다르므로, 한 방향의 record를 반대 방향으로 되돌려 보낼 수 없습니다.
- K는 언제나 HMAC 키로만 씁니다. 그래서 Android Keystore에 꺼낼 수 없는 HMAC 키로 넣어 둘 수 있습니다(6.6). 세션 키는 메모리에만 둡니다.

### 6.5 REJECT와 실패 처리

| reason | 이름 | 보내는 때 |
|---|---|---|
| 1 | UNKNOWN_PEER | 상대 peerId의 K가 없음 |
| 2 | BAD_MAC | AUTH 검증 실패 |
| 3 | ALREADY_CONNECTED | 같은 peer와 다른 링크가 있음 (9절) |
| 4 | USER_REJECTED | 사용자가 페어링을 거절함 |
| 5 | TIMEOUT | 승인을 60초 동안 기다림 |
| 6 | CANNOT_PROMPT | 승인 화면을 띄울 수 없음 |
| 7 | COMMIT_MISMATCH | 받은 공개키가 커밋과 다름 |
| 8 | UNSUPPORTED_VERSION | 공통 버전이 없음 |

| 상황 | 처리 |
|---|---|
| 링크를 쓸 수 있게 된 뒤 10초 안에 HELLO나 AUTH가 끝나지 않음(승인 대기 중이 아닐 때) | C가 링크를 닫고 오류 이벤트를 보냅니다 |
| C가 UNKNOWN_PEER를 받음(P가 이 기기를 삭제함) | K는 유지합니다. 인증되지 않은 메시지라 이것만으로 지우지 않습니다. "다시 페어링 필요"로 표시하고 자동 재연결 대상에서 뺍니다. 사용자가 연결을 누르면 AUTH 대신 PAIR_REQUEST를 보냅니다 |
| C가 사용자 요청 없이 연결했는데 HELLO_p의 peerId를 모름(상대가 앱을 다시 설치함) | REJECT(UNKNOWN_PEER)를 보내고, 위와 같이 표시합니다 |
| BAD_MAC을 보내거나 받음 | 경고를 띄우고 자동 재연결 대상에서 뺍니다. 공격일 수 있으므로 자동으로 다시 페어링하지 않습니다 |
| USER_REJECTED, TIMEOUT, CANNOT_PROMPT | 양쪽 모두 "페어링 실패"를 표시합니다. C는 자동 재연결하지 않습니다 |
| ALREADY_CONNECTED | 9절 |
| 세션 중에 HELLO를 받음(상대 앱이 다시 시작됨) | 세션을 버리고 핸드셰이크를 처음부터 다시 합니다 |
| SEALED 복호화 실패 | 그 record만 버립니다. 연속 5번이면 C가 링크를 닫습니다 |
| 세션 전에 SEALED가 옴, 세션 뒤에 다른 핸드셰이크 record가 옴 | 버립니다 |

### 6.6 키 저장과 수명

저장
- **Android**: peerId와 peer 정보(이름, deviceId, 상태)는 별도의 prefs 파일(예: `ble_identity`)에 둡니다. K는 Android Keystore에 HMAC-SHA256 키로 넣습니다(`KeyProtection`, `PURPOSE_SIGN`, 꺼낼 수 없음). 백그라운드와 잠금 상태에서도 써야 하므로 사용자 인증 조건은 걸지 않습니다.
- **iOS**: peerId와 K는 Keychain에 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`로 둡니다. 잠긴 상태의 백그라운드 재연결에서도 읽을 수 있고, 다른 기기로 옮겨지지 않습니다.
- **백업 제외**: 백업을 복원하면 같은 peerId를 쓰는 폰이 두 대가 됩니다. Android는 지금 백업 설정이 없어서 Auto Backup이 prefs를 백업하므로, `android:dataExtractionRules`로 이 파일을 제외합니다. iOS는 위의 `ThisDeviceOnly`로 해결됩니다.
- **iOS 재설치**: Keychain은 앱을 지워도 남습니다. Android와 동작을 맞추기 위해, 첫 실행(UserDefaults 표시가 없을 때)에 이 앱의 Keychain 항목을 지웁니다.

수명

| 상황 | 처리 |
|---|---|
| 앱 재설치, 데이터 삭제 | 새 peerId가 생기므로 상대에게는 새 기기입니다. 같은 deviceId의 예전 항목은 재페어링에 성공하면 교체하고, 목록에는 "다시 설치된 것 같습니다"를 안내할 수 있습니다 |
| OS 페어링만 해제됨 (20번 `bondLost`) | 다시 bond하면 K로 AUTH가 통과하므로 앱 승인을 다시 받지 않습니다 |
| 앱에서 기기 삭제 | 연결 중이면 UNPAIR를 보내고, K를 지우고, 자동 재연결 대상에서 뺍니다 |
| 삭제한 기기가 C로 다시 연결해 옴 | K가 없으므로 AUTH_c에 REJECT(UNKNOWN_PEER)로 답합니다. 승인 화면은 뜨지 않고, 상대는 자동 재연결을 멈춥니다 |
| UNPAIR를 받음 | K를 지우고, "상대가 연결을 해제함"으로 표시하고, 자동 재연결 대상에서 뺍니다. 링크는 C가 닫습니다 |

## 7. Envelope

SEALED record의 평문입니다.

| off | size | field |
|---|---|---|
| 0 | 1 | type |
| 1 | 1 | flags: bit0 `ACK_REQ`, bit1 `REPLY`. 나머지는 0으로 보내고, 받을 때는 무시합니다 |
| 2 | 4 | msgId u32 |
| 6 | … | body |

| type | 이름 | body |
|---|---|---|
| 0x01 | DATA | `u8 pathLen`, `path`, `u32 replyTo`(`REPLY`일 때만), payload(나머지 전부) |
| 0x02 | ACK | `u32 refMsgId`, `u8 status`. msgId와 flags는 0 |
| 0x03 | CAPS | TLV 목록 (아래) |
| 0x04 | UNPAIR | 없음. `ACK_REQ`를 붙입니다 |

**ACK status**

| 값 | 이름 | 뜻 |
|---|---|---|
| 0 | OK | 받는 쪽이 대상(Dart, 내장 기능, AIDL 앱)에 넘겼음 |
| 1 | NO_RECEIVER | 그 path를 받을 앱이 없음 |
| 2 | UNSUPPORTED | 모르는 내장 path나 envelope type |
| 3 | TOO_LARGE | |
| 4 | BUSY | 받는 쪽 대기열이 가득 참 |
| 5 | DENIED | 허용되지 않음 (서명이 다른 앱 등, 8절) |
| 6 | MALFORMED | |
| 255 | ERROR | |

ACK는 "도착했다"는 뜻입니다. 실행 결과는 따로 `REPLY` DATA로 보냅니다. 그래야 몇 초 걸리는 명령도 도착 여부는 바로 알 수 있습니다.

**CAPS**: 이 기기가 받을 수 있는 대상의 전체 목록입니다.
- tag 0x01: 내장 path(UTF-8). 예: `/control/media`
- tag 0x02: 앱. `u8 pkgLen`, `packageName`, `certSha256[32]`
- 세션이 맺어지면 보내고, 목록이 바뀔 때마다(AIDL 앱 등록·해제, 앱 설치·삭제) 다시 보냅니다. 받는 쪽은 통째로 바꿉니다. msgId가 마지막으로 적용한 값보다 작은 CAPS는 무시합니다.
- 암호화된 뒤에 보내므로, 설치된 앱 목록은 승인한 peer에게만 보입니다.

**UNPAIR**: 보낸 쪽은 ACK를 받거나 3초가 지나면 K를 지웁니다. 링크는 C가 닫습니다.

## 8. Path와 라우팅

- path는 UTF-8로 255바이트 이하입니다.
- `/`로 시작하는 path는 이 앱의 내장 기능입니다. 지금 정의된 것은 `/debug/chat`, `/control/media`입니다.
- 그 밖의 path는 `<packageName>/<임의 문자열>`입니다. 첫 `/` 앞이 패키지명입니다.
- **앱 식별자**는 (패키지명, 서명 인증서 SHA-256)입니다. 패키지명만으로 판단하면, 서명이 다른 같은 이름의 앱을 사이드로드해서 데이터를 받을 수 있습니다.

보내는 쪽
- AIDL 호출자의 path는 호출자 자신의 패키지명으로 시작해야 합니다. 아니면 즉시 `DENIED`입니다. 그래서 외부 앱은 `/control/*`를 보낼 수 없습니다.
- 상대 CAPS에 같은 앱 식별자가 없으면 보내지 않고 `NO_RECEIVER`로 실패시킵니다.

받는 쪽
- `/`로 시작하는 path는 내장 handler로 넘깁니다. handler가 없으면 `UNSUPPORTED`입니다.
- 앱 path는 세 가지를 모두 확인합니다. (1) 보낸 쪽 CAPS에 그 패키지가 선언돼 있고, (2) 선언된 인증서 해시가 이 폰에 설치된 같은 패키지의 인증서 해시와 같고, (3) 그 앱이 받을 수 있어야 합니다(11절). (1)이나 (2)가 아니면 `DENIED`, (3)이 아니면 `NO_RECEIVER`입니다.
- 결과적으로 앱은 **상대 폰의 같은 앱하고만** 통신할 수 있습니다.

## 9. 전달 규칙

- **msgId**: u32입니다. 보내는 쪽이 모든 peer에 걸쳐 1씩 늘리고 저장해서, 프로세스가 재시작돼도 이어집니다. 1부터 시작하고, 0은 "없음"입니다.
- **ACK_REQ**: `/debug/chat`, `/control` 요청, 앱 DATA, UNPAIR에는 붙입니다. `REPLY`에는 붙이지 않습니다.
- **중복 제거**: 받는 쪽은 peer별로 최근 2분 동안 받은 `ACK_REQ` DATA의 (msgId → status)를 기억합니다. 같은 msgId가 다시 오면 대상에 다시 넘기지 않고, 기억해 둔 status로 ACK만 다시 보냅니다.
- **재전송**: 한 링크 안에서는 GATT가 순서와 전달을 보장하므로 재전송하지 않습니다. ACK를 받기 전에 세션이 끊기면, 다시 연결된 세션으로 같은 msgId를 원래 순서대로 다시 보냅니다.
- **TTL**: 보내는 쪽이 메시지마다 정합니다. 기본값은 `/control` 10초, 그 밖에는 30초이고, 최대 60초입니다. TTL은 상대에게 보내지 않습니다(두 폰의 시계가 다름). 기다리는 동안 peer가 연결되지 않아도 TTL까지는 기다립니다.
- **ACK 대기**: 마지막 조각을 보낸 뒤 10초 안에 ACK가 없으면 실패로 처리합니다.
- **보낸 쪽이 받는 결과**: ACK status(0–255) 또는 로컬 결과입니다. 로컬 결과는 두 가지입니다.
  - `EXPIRED_NOT_SENT`(1000): 보내지 못함. 다시 시도해도 안전합니다
  - `EXPIRED_UNCONFIRMED`(1001): 보냈지만 ACK를 받지 못함. 상대가 받았을 수도 있습니다
- **순서**: peer별로 보낸 순서대로 나갑니다. 우선순위는 핸드셰이크 > ACK > `/control` > 그 밖의 DATA 순이고, 우선순위가 높은 record는 낮은 record의 조각 사이에 끼어들 수 있습니다. 같은 우선순위 안에서는 순서를 지킵니다.
- **흐름 제어**: peer별로 ACK를 기다리는 DATA는 최대 4개입니다. AIDL 앱별 대기열은 32개이고, 넘으면 로컬에서 `BUSY`입니다.
- **전달 의미**: 보통은 한 번 전달됩니다. 다만 받는 쪽 프로세스가 재시작돼 중복 기록이 사라진 사이에 재전송이 오면 두 번 전달될 수 있습니다(at-least-once). 그래서 원격 조작은 TOGGLE보다 PLAY와 PAUSE처럼 여러 번 실행해도 결과가 같은 op를 쓰고, 앱은 (peerId, msgId)로 중복을 거릅니다.

**peer당 링크 하나 (24번)**

두 폰 사이에는 링크를 하나만 둡니다. 이미 C와 P로 연결된 기기가 반대 역할로 새로 연결하려고 하면, HELLO에서 같은 peerId가 확인되는 순간 새 연결을 실패시킵니다. 그래서 모든 record(ACK 포함)는 그 peer의 유일한 링크로 오갑니다.

- 어느 쪽이든 같은 peerId의 링크가 둘이 된 것을 알게 되면 아래 규칙으로 남길 링크를 정합니다. P는 HELLO_c를 받았을 때, C는 HELLO_p를 받았을 때 알게 됩니다. 양쪽이 같은 규칙을 쓰므로 같은 결론이 납니다.
  1. 세션이 맺어진 링크를 남깁니다. 먼저 연결된 쪽이 이깁니다.
  2. 둘 다 아직 핸드셰이크 중이면 low가 C인 링크를 남깁니다. 서로 동시에 자동 재연결한 경우입니다.
- 지는 링크의 P는 HELLO_p 대신 REJECT(ALREADY_CONNECTED)를 보내고, 지는 링크의 C는 링크를 닫습니다.
- ALREADY_CONNECTED로 끝난 C는 그 peer와 다른 링크가 있는 동안 재연결하지 않습니다. 남은 링크가 끊기면 다시 양쪽 모두 재연결 대상이 됩니다.
- Android는 두 역할에서 deviceId(MAC)가 같습니다. 그래서 이미 server 쪽으로 연결된 기기에는 처음부터 `connectGatt`를 하지 않게 할 수 있습니다. 하지만 플랫폼이 섞이면 deviceId를 비교할 수 없으므로, 최종 판단은 peerId로 합니다.
- 세션이 맺어진 시점이 양쪽에서 조금 엇갈리면, 드물게 두 링크가 모두 끊길 수 있습니다. 그때는 자동 재연결로 다시 하나가 맺어집니다.

## 10. 내장 기능

### `/debug/chat`

- payload는 UTF-8 텍스트이고, `ACK_REQ`를 붙입니다.
- Dart의 `sendMessage`는 네이티브에서 이 path로 감싸서 보냅니다. `messageSent`는 ACK `OK`를 받았을 때, `messageFailed`는 그 밖의 결과일 때 보냅니다. Dart의 문자열 messageId는 네이티브가 프로토콜 msgId와 짝지어 관리합니다.
- 개발용입니다. 프로토콜 검증이 끝나면 없앨 수 있습니다.

### `/control/media`

요청 payload는 `u8 op`입니다.

| op | 동작 | Android 키 코드 |
|---|---|---|
| 0 | GET_STATE | – |
| 1 | PLAY | `KEYCODE_MEDIA_PLAY` |
| 2 | PAUSE | `KEYCODE_MEDIA_PAUSE` |
| 3 | PLAY_PAUSE | `KEYCODE_MEDIA_PLAY_PAUSE` |
| 4 | STOP | `KEYCODE_MEDIA_STOP` |
| 5 | NEXT | `KEYCODE_MEDIA_NEXT` |
| 6 | PREVIOUS | `KEYCODE_MEDIA_PREVIOUS` |

응답은 같은 path의 `REPLY` DATA이고, payload는 `u8 result`(0 OK, 1 FAILED, 2 UNSUPPORTED_OP), `u8 state`(0 모름, 1 재생 중, 2 재생 중 아님)입니다.

```
A → B  DATA  #41  /control/media  ACK_REQ     [01]     PLAY
B → A  ACK   ref=#41 OK
B → A  DATA  #7   /control/media  REPLY(#41)  [00 01]  성공, 재생 중
```

- Android: `AudioManager.dispatchMediaKeyEvent`로 키를 보냅니다(DOWN, UP). 지금 활성인 미디어 세션이 받고, 별도 권한은 필요 없습니다. 상태는 `isMusicActive()`로 읽습니다. 키를 보낸 직후에는 상태가 아직 바뀌지 않았을 수 있습니다(15절).
- iOS: 다른 앱의 재생을 제어할 수 없어서 CAPS에 넣지 않습니다. 조작하는 쪽 역할만 합니다.
- 허용 범위: peer 승인(6.3)을 받은 상대만 조작할 수 있습니다.

## 11. AIDL

- 별도의 bound service를 export합니다(이름 미정, action `com.rouddy.bluetooth_communicator.action.BIND`). 지금의 `BluetoothBackgroundService`는 `exported=false`이고 `onBind`가 null을 돌려줍니다.
- 권한은 걸지 않습니다. 어떤 앱이든 쓸 수 있게 하기 위해서이고, 커스텀 권한은 클라이언트 앱이 이 앱보다 먼저 설치되면 부여되지 않는 문제도 있습니다.
- **호출자 확인**: `Binder.getCallingUid()`를 씁니다. 클라이언트가 넘긴 패키지명이 그 UID의 것인지 `getPackagesForUid`로 확인합니다. 인증서 해시는 `getPackageInfo(pkg, GET_SIGNING_CERTIFICATES).signingInfo.apkContentsSigners`의 SHA-256입니다. 서명자가 여럿이면 각 해시를 정렬해 이어 붙인 것의 SHA-256을 씁니다.

```aidl
interface IBleCommunicator {
    int getApiVersion();
    List<PeerInfo> getPeers();
    // replyTo가 0이면 일반 메시지. 반환값은 이 요청의 로컬 id
    long send(String peerId, String path, in byte[] data, long replyTo,
              long ttlMillis, IBleSendCallback callback);
    void registerListener(IBleListener listener);
    void unregisterListener(IBleListener listener);
}

oneway interface IBleListener {
    void onMessage(String peerId, String path, in byte[] data, long msgId, long replyTo);
    void onPeersChanged();
}

oneway interface IBleSendCallback {
    void onResult(long requestId, int status);   // 9절의 결과 코드
}

parcelable PeerInfo { String peerId; String name; boolean connected; }
```

- `getPeers()`는 CAPS에 호출자와 같은 앱 식별자가 있는 peer만 돌려줍니다.
- 앱은 자기 패키지의 path만 받으므로, listener에는 path 필터가 없습니다.
- **수신 경로**: 등록된 listener가 있으면 `onMessage`로 넘기고 ACK `OK`를 보냅니다. listener가 없으면, 클라이언트 앱이 action `com.rouddy.bluetooth_communicator.action.RECEIVE`로 선언한 service(`IBleListener`를 돌려줌)에 bind해서 넘깁니다(Wear OS의 `WearableListenerService` 방식). 둘 다 없으면 `NO_RECEIVER`입니다.
- Android 11+ 패키지 가시성 때문에 이 앱의 manifest에 그 action의 `<queries>`가 필요합니다.
- CAPS의 앱 목록은 listener가 등록된 앱과 RECEIVE service를 선언한 앱입니다. 등록·해제와 `PACKAGE_ADDED`/`PACKAGE_REMOVED` 때 갱신합니다.
- 데이터 크기는 상대 `maxMessageSize`에서 헤더 크기를 뺀 값까지입니다(64KiB 수준이라 Binder 한도와는 상관없음).
- 앱 개발자에게 알릴 것: 드물게 같은 메시지가 두 번 올 수 있으니 (peerId, msgId)로 거릅니다. `EXPIRED_UNCONFIRMED`는 상대가 받았을 수도 있다는 뜻입니다.

## 12. 플랫폼 채널 변경 (예정)

구현할 때 `CLAUDE.md`의 채널 계약과 세 플랫폼의 코드를 같이 바꿉니다. 이름은 구현하면서 확정합니다.

- `sendMessage`: 바깥 모양은 그대로이고, 네이티브가 `/debug/chat`으로 감쌉니다. `messageSent`는 "상대 앱이 받음"을 뜻하게 됩니다.
- `connected{deviceId, peerId, name}`: 세션이 맺어졌을 때 보냅니다.
- `connectDevice{pair: true}`: 지금처럼 OS 페어링을 허용하는 것에 더해, 그 링크에서 PAIR_REQUEST를 보내도 된다는 뜻이 됩니다(6.3).
- 새 이벤트: `pairingRequest{deviceId, peerId, name, code, repair}`(양쪽 모두), `pairingResult{deviceId, peerId, result}`, `peerRejected{deviceId, reason}`(REJECT reason, 6.5), `peerUnpaired{deviceId}`
- 새 메서드: `respondPairing{deviceId, accept}`, `setDeviceName{name}`(iOS), 미디어 조작 메서드
- `removeDevice`: 지금의 `disconnectDevice`에 더해 UNPAIR를 보내고 K를 지웁니다.

## 13. 보안 범위

막는 것
- 같은 BLE 링크를 공유하는 다른 앱(상대 폰이나 이 폰)이 메시지를 엿보거나, 끼워 넣거나, 다시 보내는 것
- 다른 앱이 이 앱인 척하는 것(K가 없음)
- 앱 페어링 중 중간자 공격(확인 코드와 커밋)
- 서명이 다른, 같은 패키지명의 앱이 데이터를 받는 것

막지 못하는 것
- 루팅 등으로 앱 저장소나 Keystore가 노출된 폰
- 사용자가 코드를 비교하지 않고 승인하는 것
- 크기와 시간을 이용한 트래픽 분석. 평문 HELLO의 이름과 peerId 노출(BLE 광고 이름은 원래 공개됨)
- 서비스 거부
  - 인증되지 않은 REJECT
  - 같은 링크를 쓰는 다른 앱이 끼워 넣은 쓰레기 데이터나 HELLO. 세션이 끊기거나 다시 시작됩니다
  - 위조한 PAIR_REQUEST. P 쪽에 승인 화면이 반복해서 뜰 수 있습니다. 문제가 되면 거절 직후 잠시 같은 peer의 요청을 무시하는 정도로 충분합니다
- 승인한 peer의 앱이 악의적인 경우. 같은 앱끼리만 통신하므로 피해 범위는 그 앱으로 한정됩니다

## 14. 구현 순서

단계마다 기기에서 확인할 수 있게 나눕니다.

1. **코덱과 암호 함수**: Frame 분할·재조립, record와 envelope 인코딩, TLV, HMAC/HKDF/AES-GCM/ECDH 래퍼를 BLE 코드와 분리된 순수 클래스로 만듭니다. Kotlin은 JVM 테스트(`GattOperationQueue`처럼), Swift는 `RunnerTests`로 검증합니다. 두 구현은 같은 테스트 벡터 파일(예: `test_vectors/protocol_v1.json`)을 씁니다.
2. **Frame + HELLO + peer당 링크 하나**: 채팅을 Frame 위로 옮깁니다. 이 단계에서만 임시로 평문 DATA를 허용하고, 4단계에서 없앱니다. 17번의 512바이트 제한, `(Unknown)` 이름 문제, 24번(이중 링크)이 풀립니다.
3. **앱 페어링 + AUTH**: PAIR_REQUEST, 승인 화면, 확인 코드, 키 저장, REJECT 처리
4. **SEALED**: 평문 DATA를 없앱니다
5. **ACK, 중복 제거, 재전송, TTL, 흐름 제어**: `messageSent`가 "상대가 받음"을 뜻하게 됩니다
6. **CAPS + `/control/media`** (Android): 첫 실제 명령
7. **AIDL 서비스**

호환성: 지금 빌드와는 호환되지 않으므로, 2단계에서 message characteristic UUID를 바꾸는 것을 권합니다. 그러면 예전 빌드와 새 빌드가 섞여 있을 때 엉뚱한 데이터를 해석하는 대신 그냥 연결되지 않습니다.

## 15. 미정 / 구현하면서 확인할 것

- 미디어 키를 보낸 뒤 `isMusicActive()`에 반영되기까지 걸리는 시간
- iOS에서 같은 기기가 central일 때와 peripheral일 때 identifier가 같은지. 같다면 iOS에서도 deviceId로 두 번째 연결을 미리 막을 수 있습니다(9절)
- iOS 승인 화면: 지금은 포그라운드일 때만 가능합니다. 알림 흐름이 생기면 백그라운드에서도 받을 수 있습니다
- 서명 키 교체(APK Signature Scheme v3 rotation): v1은 현재 서명자만 비교합니다. 한쪽만 업데이트되면 두 폰의 해시가 달라져 `DENIED`가 됩니다
- Keystore HMAC 키 가져오기(`KeyProtection`)가 대상 기기(Samsung 등)에서 문제 없는지
- 시간 제한, 윈도우, 대기열 크기 같은 숫자: 기기에서 측정한 뒤 조정합니다
- store-and-forward가 필요한지
- peer별로 "원격 조작"과 "앱 간 통신"을 따로 허용하는 토글이 필요한지
