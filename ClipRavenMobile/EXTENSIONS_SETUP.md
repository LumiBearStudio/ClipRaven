# ClipRaven iOS Extensions — Xcode Target 추가 가이드

Share Extension과 Keyboard Extension을 추가할 때 따라하는 가이드.
필요한 코드 + Info.plist + entitlements는 이미 준비되어 있고,
Xcode UI에서 target만 연결하면 됩니다.

각 단계 ~5분, 한 번만 하면 끝.

---

## 0. App Group 등록 (사전)

### Apple Developer Portal
1. https://developer.apple.com/account → Identifiers
2. App Groups → `+` → Continue
3. Description: `ClipRavenMobile`, Identifier: `group.com.lumibear.ClipRavenMobile`

### Xcode (메인 앱)
1. ClipRavenMobile target → **Signing & Capabilities**
2. **+ Capability** → **App Groups**
3. `+` → `group.com.lumibear.ClipRavenMobile` 추가 (체크)

(이미 entitlements에 있으므로 Xcode가 자동 인식)

---

## 1. Share Extension target 추가

### Xcode 메뉴
1. **File → New → Target...**
2. iOS → **Share Extension** → Next
3. Settings:
   - **Product Name**: `ShareExtension` (대소문자 정확히)
   - **Bundle Identifier**: 자동으로 `com.lumibear.ClipRavenMobile.ShareExtension`
   - **Language**: Swift
   - **Project**: ClipRavenMobile
   - **Embed in Application**: ClipRavenMobile
4. Finish → "Activate ShareExtension scheme?" 다이얼로그가 뜨면 **Cancel**

### 자동 생성된 파일을 우리 파일로 교체

Xcode가 새 폴더에 다음 파일들을 자동 생성합니다:
- `ShareExtension/ShareViewController.swift`
- `ShareExtension/MainInterface.storyboard`
- `ShareExtension/Info.plist`
- `ShareExtension/ShareExtension.entitlements`

⚠️ **이 자동 생성 파일들을 모두 삭제** (Project navigator에서 우클릭 → Delete → Move to Trash)

그리고 Xcode가 만든 Sharext folder도 통째로 비워주세요. 프로젝트 트리에서 ShareExtension 그룹 자체는 살려두고 안의 파일만 다 지워주세요.

### 우리가 준비한 파일을 추가

Project navigator에서 ShareExtension 그룹 우클릭 → **Add Files to "ClipRavenMobile"...**:

`ClipRavenMobile/ShareExtension/` 폴더에서 다음 4개 파일 선택:
- `ShareExtension.entitlements`
- `Info.plist`
- `ShareViewController.swift` (stub — 패키지 의존성 없음)
- `ShareViewController.full.swift` (실 구현 — 패키지 링크 후 활성화)

⚠️ Add 다이얼로그에서:
- **Copy items if needed**: 체크 해제 (이미 디스크에 있음)
- **Add to targets**: **ShareExtension** 만 체크 (메인 앱 체크 해제)

### Build Settings 조정

ShareExtension target 선택 → **Build Settings**:
- **Code Signing Entitlements** → `ClipRavenMobile/ShareExtension/ShareExtension.entitlements`
- **Info.plist File** → `ClipRavenMobile/ShareExtension/Info.plist`
- **iOS Deployment Target** → 17.0

### App Group + 패키지 링크

ShareExtension target → **Signing & Capabilities**:
- **+ Capability** → **App Groups** → `group.com.lumibear.ClipRavenMobile` 체크

ShareExtension target → **General → Frameworks, Libraries, and Embedded Content**:
- **+** → **ClipRavenSync** 선택 (workspace의 패키지 자동 표시)

### 풀 구현 활성화 (선택)

위 Build Settings + 패키지 링크가 끝났으면 stub을 풀 구현으로 교체:
1. `ShareViewController.swift` 내용을 `ShareViewController.full.swift`로 복사
2. `ShareViewController.full.swift`는 삭제 (옵션)
3. `Info.plist`에서:
   - `NSExtensionMainStoryboard` 키 삭제
   - `NSExtensionPrincipalClass` 키 추가, 값 `$(PRODUCT_MODULE_NAME).ShareViewController`

---

## 2. Keyboard Extension target 추가

### Xcode 메뉴
1. **File → New → Target...**
2. iOS → **Custom Keyboard Extension** → Next
3. Settings:
   - **Product Name**: `KeyboardExtension` (대소문자 정확히! `keyExtension` 아님)
   - **Bundle Identifier**: `com.lumibear.ClipRavenMobile.KeyboardExtension`
   - **Language**: Swift
   - **Embed in Application**: ClipRavenMobile
4. Finish → scheme 추가 Cancel

### 자동 생성된 파일 교체

Xcode가 만든:
- `KeyboardExtension/KeyboardViewController.swift`
- `KeyboardExtension/Info.plist`

→ **모두 삭제** (Move to Trash)

### 우리가 준비한 파일 추가

`ClipRavenMobile/KeyboardExtension/` 에서:
- `KeyboardExtension.entitlements`
- `Info.plist`
- `KeyboardViewController.swift`

→ Add to targets: **KeyboardExtension** 만

### Build Settings + App Group + 패키지

ShareExtension과 동일 패턴:
- **Code Signing Entitlements** → `ClipRavenMobile/KeyboardExtension/KeyboardExtension.entitlements`
- **Info.plist File** → `ClipRavenMobile/KeyboardExtension/Info.plist`
- **App Groups** capability 추가
- **ClipRavenSync** 패키지 링크

---

## 3. 검증

### 빌드
```bash
xcodebuild -workspace ClipRaven.xcworkspace \
  -scheme ClipRavenMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  build
```

3개 target (ClipRavenMobile + ShareExtension + KeyboardExtension) 모두 빌드되어야 함.

### Share Extension 테스트
1. iOS Simulator에서 ClipRavenMobile 실행 → Settings에서 "iCloud 동기화" ON
2. Safari 열기 → 페이지 → 공유 시트 → ClipRaven 선택
3. "✅ 저장됨" 확인 → 메인 앱 리스트에 새 클립 표시

### Keyboard Extension 테스트
1. iOS Simulator → 설정 → 일반 → 키보드 → 키보드 추가
2. ClipRaven 키보드 추가 → 선택 → "전체 접근 허용 (Allow Full Access)" 켜기 (필수)
3. Notes 등 텍스트 필드에서 globe 아이콘 길게 누름 → ClipRaven 선택
4. 클립 목록 표시 → 탭하면 텍스트 입력 필드에 삽입됨

---

## 트러블슈팅

### "Activate scheme?" 다이얼로그
Cancel — extension은 메인 앱이 호스팅하므로 별도 scheme 불필요.

### Target 이름 오타 (예: keyExtension)
Xcode UI로 target 삭제 → 다시 만들기. project.pbxproj 직접 편집은 위험.
Target 삭제 방법: Project Editor → 좌측 target 리스트에서 우클릭 → Delete.

### 잘못 만든 폴더 (`/ShareExtension`이 프로젝트 루트에 생김 등)
xcodeproj가 그 경로를 참조하지 않으면 그냥 디스크에서 폴더 삭제 OK.
참조하면 Xcode에서 group 삭제 → "Move to Trash".

### "App Group container is nil" 런타임 메시지 (NSLog)
- entitlements 파일에 group ID 들어있는지 확인
- Apple Developer Portal에 App Group 등록되어 있는지 확인
- Xcode → Signing & Capabilities → App Groups에 그룹 체크되어 있는지

### Share Extension에서 텍스트 안 받아짐
Info.plist의 `NSExtensionActivationRule` 검토. 우리 Info.plist는
`NSExtensionActivationSupportsText` + `SupportsWebURL` + `SupportsWebPage`
3가지를 받게 설정되어 있음.

### Keyboard Extension에서 클립이 안 보임
- "전체 접근 허용 (Allow Full Access)" 켜졌는지 확인
- App Group container에 메인 앱이 SQLite 파일을 만들었는지 확인
  (메인 앱을 실행 + 클립 1개 추가하면 생성됨)
