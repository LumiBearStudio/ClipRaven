# ClipRavenMobile — iOS 프로토타입

ClipRaven Mac 앱의 iCloud 동기화를 2대 기기 시나리오로 검증하기 위한 최소 iOS 앱.
Mac의 CKSyncEngine가 실제로 양방향 동기화 파이프라인으로 동작하는지 물리적으로 증명하는 테스트 도구.

**장기 관점**: Phase v2.5 "iOS companion"의 초기 프로토타입. 현재는 CKSyncEngine 없이
최소 CKDatabase 직접 호출로만 구성돼 있지만, 공통 스키마 키(`SyncRecordKeys`)가 Mac 앱과
일치하므로 그대로 확장 가능.

## 프로젝트 구조

```
ClipRavenMobile/
├── project.yml                              # xcodegen config (프로젝트 파일 생성용)
├── README.md                                # 이 문서
└── ClipRavenMobile/
    ├── ClipRavenMobileApp.swift             # @main 엔트리
    ├── Info.plist
    ├── ClipRavenMobile.entitlements         # iCloud + APS 권한
    ├── Services/
    │   ├── CloudKitService.swift            # CKDatabase 래퍼 (fetch/save/delete)
    │   └── SyncRecordKeys.swift             # Mac의 SyncRecordMapper.Key 거울
    ├── Models/
    │   └── ClipItem.swift                   # 뷰용 경량 레코드 모델
    ├── ViewModels/
    │   └── ClipListViewModel.swift          # MVVM VM
    ├── Views/
    │   ├── ClipListView.swift               # 메인 리스트 + 툴바
    │   └── AddClipView.swift                # 새 클립 입력 시트
    ├── Assets.xcassets/                     # AppIcon, AccentColor 자리표시
    └── Preview Content/
        └── Preview Assets.xcassets/
```

## 처음 세팅 (한 번만)

### 1. xcodegen 설치 (이미 있으면 스킵)

```bash
brew install xcodegen
```

### 2. Xcode 프로젝트 생성

```bash
cd ClipRavenMobile
xcodegen generate
```

성공하면 `ClipRavenMobile.xcodeproj` 생성됨.

### 3. Xcode에서 프로젝트 열기

```bash
open ClipRavenMobile.xcodeproj
```

### 4. 서명 & 용량 설정 (Xcode GUI)

1. 최상단 좌측 `ClipRavenMobile` 프로젝트 선택 → `TARGETS` → `ClipRavenMobile`
2. **Signing & Capabilities** 탭
3. `Team` 드롭다운에서 **유료 Apple Developer 팀** 선택 (Mac 앱과 같은 팀)
4. `Automatically manage signing` 체크
5. `iCloud` 기능 이미 entitlements에 있음 — **Container 선택란에서 `iCloud.com.lumibear.ClipRaven` 체크 확인**
6. `Push Notifications` 기능 이미 entitlements에 있음

### 5. iPhone 실기기 연결

1. USB 케이블 또는 같은 Wi-Fi + Xcode 페어링으로 iPhone 연결
2. iPhone 로그인 Apple ID가 Mac의 iCloud 계정과 **동일**한지 확인 (필수!)
3. iPhone → 설정 → 개발자 → 신뢰할 개발자에 본인 팀 추가

### 6. 빌드 & 실행

Xcode 상단 스킴 선택기에서:
- **ClipRavenMobile** 스킴 선택
- 실행 대상을 **연결된 본인 iPhone**으로 선택
- ▶ 실행

첫 실행 시 iPhone 설정 → 개인정보 및 보안 → 개발자 앱 신뢰 한 번 거쳐야 할 수 있음.

## 동작 확인 시나리오

### 시나리오 A: Mac → iOS 다운로드 검증 (B.5b 역경로 검증)

1. Mac ClipRaven에서 텍스트 한 줄 복사 (자동으로 CloudKit 업로드됨)
2. iPhone에서 ClipRavenMobile 실행
3. 당겨서 새로고침 (Pull to refresh)
4. **리스트에 해당 클립이 나타나야 함**

### 시나리오 B: iOS → Mac 다운로드 검증 (B.5b 정경로 검증)

1. iPhone에서 우측 상단 `+` 버튼 → 내용 입력 → 저장
   - 또는 좌측 상단 ⚡️(bolt) 버튼으로 타임스탬프 원-탭 저장
2. 저장 후 iPhone 리스트에 새 클립 즉시 표시
3. Mac ClipRaven `Cmd+Q` → Xcode ▶ 재실행
4. Xcode 콘솔에서 다음 로그 확인:
   ```
   [SYNC] fetchedRecordZoneChanges received: mods=1, dels=0
   [SYNC] downloaded: +1 inserted, ~0 updated, -0 deleted
   ```
5. Mac ClipRaven 패널에서 iOS가 만든 클립이 보여야 함

### 시나리오 C: 양방향 삭제 전파

1. iPhone에서 클립 좌→우 스와이프 → Delete
2. Mac ClipRaven 재기동 → `~0 updated, -1 deleted` 로그 확인

## 검증 포인트

- ✅ 두 기기가 같은 `ClipRavenItems` 존 공유
- ✅ iPhone에서 만든 클립이 Mac `CKSyncEngine.fetchedRecordZoneChanges`로 전달
- ✅ Mac에서 만든 클립이 iPhone의 CKQueryOperation으로 조회
- ✅ 양측 `platformCreatedOn` 필드로 생성 기기 추적 가능
- ✅ `deviceId` 필드로 기기별 UI 배지 구현 가능

## 알려진 제한

- **로컬 영속화 없음** — 앱 재시작하면 매번 CloudKit에서 새로 fetch
- **CKSyncEngine 미사용** — silent push 자동 수신 아직 안 함 (수동 새로고침 필요)
- **이미지/asset 미지원** — Phase C 영역, 지금은 텍스트 only
- **태그·기타 관계 필드 무시** — `tagsText`는 기록만

## 확장 방향 (v2.5 로드맵)

1. `CKSyncEngine` 적용 → 실시간 silent push 수신
2. GRDB 로컬 DB 추가 → 오프라인 모드
3. 이미지 `CKAsset` 표시
4. 태그 필터 UI
5. 공유 프레임워크로 `SyncRecordKeys`, `Clip` 모델을 Mac/iOS에서 리얼 공유

## 디버그 팁

- 시뮬레이터에서는 iCloud 계정 붙이기 번거로움 → **실기기 권장**.
- iPhone 로그는 Mac의 Xcode → Window → Devices and Simulators → iPhone 선택 → View Device Logs 에서 확인.
- 같은 Apple ID 양쪽 모두 로그인돼 있는지가 첫 번째 체크포인트.
- `account not available` 에러 뜨면 iPhone 설정 → Apple ID → iCloud 활성 여부 확인.
