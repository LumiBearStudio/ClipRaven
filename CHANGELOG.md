# Changelog

All notable changes to ClipRaven are documented here.
Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026 (첫 출시 / First release)

### ✨ Highlights

- **한국어 초성 검색** — 경쟁 클립보드 앱에 없는 고유 기능. `ㄱㅅ` → `감사합니다` 즉시 발견.
- **Apple Intelligence (macOS 26+)** — 완전 온디바이스 자동 분류(영수증/회의/코드/이메일 등 7종) + 500자 이상 클립 요약. 외부 API 호출 0.
- **OCR 검색** — 이미지·스크린샷 속 한/영 텍스트가 자동으로 검색 인덱스에 포함.
- **클립별 커스텀 전역 단축키** — 자주 쓰는 클립에 개인 핫키 지정, 패널 없이 바로 붙여넣기.
- **10개 언어 현지화** — UI 9개 + Onboarding 10개 (ko/en/ja/zh-Hans/zh-Hant/es/fr/de/it/pt-BR).

### Added

- 클립보드 히스토리 (기본 5000개, 조절 가능, 최대 50000)
- 6종 콘텐츠 타입별 전용 카드 (text/code/url/image/file/color)
- 초성 검색 + FTS5 전문 검색 (한·영 동시)
- Apple Intelligence 자동 분류 · 요약 (macOS 26+)
- Vision 프레임워크 기반 OCR (ko/en 혼용 지원)
- Paste As… 포맷 변환 (Plain Text / Markdown / Rich Text)
- URL 트래킹 파라미터 자동 제거 (30+ 매개변수: utm_*, fbclid, gclid 등)
- 클립별 커스텀 전역 단축키 (Carbon 이벤트 테이블 기반)
- ⌥1–9 퀵 페이스트
- 고정(Pin) · 태그 · Smart Rules 자동 태깅
- 선택 캡처 모드 (⌘C ×2 감지, 조절 가능한 시간 창)
- 2FA 자동 필터 · 민감 정보(10패턴) 자동 감지 · 앱별 제외 목록
- 화면 공유 시 패널 자동 숨김
- ZIP 내보내기 / 가져오기 (원본 이미지 포함, 병합 · 덮어쓰기 모드)
- Shortcuts App Intents (5 actions + 2 entities)
- Quick Look 미리보기 (Space 키)
- 라이트/다크 모드 + 10종 액센트 컬러 팔레트
- Liquid Glass UI (macOS 26)
- 사운드 · 햅틱 피드백 (복사 · 붙여넣기 각각 설정)
- 6페이지 온보딩 플로우 (접근성 권한 게이트 포함, 중간 종료 차단)
- 크래시 리포트 옵트인 토글 (온보딩 마지막 페이지)
- Dock 아이콘 표시 옵션 (메뉴바 전용 모드가 기본)

### Settings

- 8개 탭 구조: 일반 / 캡처 / 단축키 / 외관 / 개인정보 / AI & 자동화 / 백업 / 정보
- 메타 탭(백업 · 정보)을 시각적으로 분리해 주요 기능에 집중
- 모든 토글 · 슬라이더는 UserDefaults에 자동 저장 · 복원

### Privacy

- **데이터 전송 0** — 클립보드 내용은 Mac 로컬 GRDB SQLite에만 저장
- **분석/텔레메트리 SDK 없음**
- **외부 네트워크 호출 제한적**:
  - OG 메타데이터 프리뷰: 사용자가 복사한 URL만
  - 파비콘 이미지: Google 파비콘 API (공개 URL만)
- Privacy Manifest (`PrivacyInfo.xcprivacy`) 포함 — UserDefaults 사용만 선언, 수집 데이터 타입 없음
- App Sandbox 활성화 (MAS 요구 사항 충족)
- Concealed/Transient 페이스트보드 타입 존중 (비밀번호 관리자 호환)

### Internationalization

- UI 현지화 9개 언어 (xcstrings): ko / en / ja / zh-Hans / zh-Hant / es / fr / de / pt-BR / it (총 124키 × 10 locales)
- Onboarding 현지화 10개 언어 (인라인 JS I18N)
- BCP-47 locale 태그 매퍼 — zh 스크립트 자동 판정 (zh-Hans vs zh-Hant), pt-BR only, case-insensitive

### Quality

- **243개 단위 테스트** (Utilities · Database · Services · Models · UI)
- print() 17개 → OSLog 이관 완료 (DEBUG 가드 포함)
- Sandbox + Info.plist 7종 MAS 필수 키
- 10개 언어 전체 프라이버시 매니페스트 검증

### Known limitations (v1.0)

- 드래그 재정렬 임시 비활성화 (`TODO: DRAG_REORDER`) — 기존 버그 수정 후 v2.0에서 복구 예정
- iCloud 동기화 없음 — v2.0 별도 트랙으로 개발 중

### Planned for v2.0

- iCloud Mac ↔ Mac 동기화 (CKSyncEngine, v2.0)
- 드래그 재정렬 복구
- Sentry 크래시 리포터 연결 (옵트인 토글은 1.0에 이미 존재)
- iOS/iPadOS 동반 앱 (v2.5 예정, sync 스키마는 v1.0에서 미리 호환 설계)
