# ClipRaven 문서

## DocC 빌드

각 타겟의 DocC 아카이브를 빌드해 Xcode Quick Help / 정적 HTML 로 변환할 수 있다.

### 1. ClipRavenSync 패키지

iOS + macOS 양쪽이 의존하는 핵심 모델/sync/구매 코드.

```sh
cd Packages/ClipRavenSync
xcodebuild docbuild \
  -scheme ClipRavenSync \
  -destination 'platform=macOS' \
  -derivedDataPath ../../build/docs/
```

생성: `build/docs/Build/Products/Debug/ClipRavenSync.doccarchive`

### 2. macOS 앱

```sh
xcodebuild docbuild \
  -project ClipRaven.xcodeproj \
  -scheme ClipRaven \
  -destination 'platform=macOS' \
  -derivedDataPath build/docs/
```

### 3. iOS 앱

```sh
xcodebuild docbuild \
  -project ClipRavenMobile/ClipRavenMobile.xcodeproj \
  -scheme ClipRavenMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/docs/
```

## DocC 아카이브 열기

```sh
open build/docs/Build/Products/Debug/ClipRavenSync.doccarchive
```

Xcode 가 자동으로 열어 native documentation viewer 로 표시.

## 정적 HTML 변환 (옵션)

GitHub Pages 등에 호스팅하려면 `docc convert` 사용.

```sh
xcrun docc process-archive transform-for-static-hosting \
  build/docs/Build/Products/Debug/ClipRavenSync.doccarchive \
  --output-path docs/clipraven-sync/ \
  --hosting-base-path /
```

## 주석 컨벤션

이 프로젝트의 DocC 컨벤션:

- **언어**: 한국어 (사용자 메모리 정책)
- **요약**: 첫 줄 한국어 단문 — 의도/책임 한 문장
- **상세**: 빈 줄 후 단락 — 왜, 언제, 어떤 경계조건
- **섹션**: `### 헤더` 로 그룹화 (Xcode Quick Help 가 헤더 인식)
- **참조**: 다른 type 은 백틱 (`Clip`), 외부 라이브러리는 일반 텍스트

예시:

```swift
/// 클립보드에 캡처된 단일 항목 — 텍스트/URL/코드/이미지/컬러/파일.
///
/// macOS 앱과 iOS 앱이 동일한 `clips` SQLite 테이블에 GRDB Codable 로 매핑되며,
/// CKSyncEngine 을 통한 iCloud 동기화의 단위이기도 하다.
///
/// ### 필드 그룹
/// - **콘텐츠**: `contentType`, `contentText`, ...
public struct Clip: Identifiable, ... { }
```
