# ClipRaven

> A deep, Korean-friendly clipboard manager for macOS.

**[English](#english)** · **[한국어](#한국어)**

---

<a id="english"></a>

## English

ClipRaven is a macOS clipboard manager built around three ideas:

- **Deep search** for Korean users (chosung/초성 + full-text FTS5).
- **Private, on-device AI** (Apple Intelligence / Foundation Models on macOS 26+) for automatic classification and summarization — no server calls, no API keys.
- **Six content types** (text / code / URL / image / file / color) with purpose-built handling for each.

### Features

- Clipboard history with per-type cards (text, code, URL, image, file, color)
- Pinned clips + tags + smart auto-tagging rules
- **Chosung search** (type `ㄱㅅ` to find `감사합니다`) — unique in the clipboard-manager space
- **FTS5 full-text search** for Korean and English
- **Apple Intelligence** (macOS 26+): automatic categorization (receipt / meeting / code / email / address / URL / phone) and one-tap summarization
- **OCR** for images — text inside screenshots becomes searchable
- **Quick Paste** with `⌥1-9` shortcuts
- **Custom per-clip hotkeys** (DB-backed, multi-hotkey)
- **Paste As…** format conversion (Plain / Markdown / Rich Text)
- **URL tracking parameter cleanup** (utm_*, fbclid, gclid, etc. — 30+ params)
- **Selective capture mode** (⌘C × 2 to save), **2FA auto-filter**, sensitive-data masking
- **Shortcuts App Intents** (5 actions + 2 entities for automation)
- **ZIP backup / restore** including original image data
- Quick Look preview (Space key)
- Light / dark themes with accent color
- Liquid Glass UI (macOS 26)
- Sound + haptic feedback
- Localized in **10 languages**: Korean, English, Japanese, Simplified Chinese, Traditional Chinese, Spanish, French, German, Italian, Brazilian Portuguese

### Requirements

- **macOS 14.0+** (Apple Intelligence features require macOS 26+)

### Support

- **Bug reports / feature requests**: [Issues](https://github.com/LumiBearStudio/ClipRaven/issues)
- **Mac App Store**: coming soon

### Privacy

- All data stays on your Mac. No telemetry, no analytics, no network calls.
- AI features use on-device Apple Foundation Models (macOS 26+). Nothing leaves the device.
- See [PRIVACY.md](PRIVACY.md) for details.

### License

[MIT](LICENSE)

---

<a id="한국어"></a>

## 한국어

ClipRaven은 세 가지 축을 중심으로 만든 macOS 클립보드 매니저입니다:

- **한국어 사용자를 위한 깊은 검색** (초성 + FTS5 전문 검색)
- **온디바이스 AI** (macOS 26+ Apple Intelligence / Foundation Models) — 외부 API 호출 없이 자동 분류·요약
- **6종 콘텐츠 타입** (텍스트 / 코드 / URL / 이미지 / 파일 / 색상) 전용 처리

### 주요 기능

- 콘텐츠 타입별 맞춤 카드 UI
- 고정(Pin) + 태그 + 스마트 규칙 자동 태깅
- **초성 검색** — `ㄱㅅ` 입력으로 `감사합니다` 찾기 (경쟁사 0개)
- **FTS5 전문 검색** (한/영 동시 지원)
- **Apple Intelligence** (macOS 26+): 자동 분류(영수증/회의/코드/이메일/주소/URL/전화) + 요약
- **OCR** — 이미지 속 텍스트 자동 검색 대상
- **⌥1-9 퀵 페이스트**
- **클립별 커스텀 전역 단축키**
- **Paste As…** 포맷 변환 (일반 텍스트 / 마크다운 / 서식 있는 텍스트)
- **URL 트래킹 파라미터 자동 제거** (30+ 파라미터)
- **선택 캡처 모드** (⌘C × 2), **2FA 자동 필터**, 민감 정보 마스킹
- **Shortcuts 앱 연동** (5 actions + 2 entities)
- **ZIP 백업/복원** (이미지 원본 포함)
- Quick Look 미리보기 (Space)
- 라이트/다크 테마 + 액센트 색상
- Liquid Glass UI (macOS 26)
- 사운드 + 햅틱 피드백
- **10개 언어 지원**: 한국어, English, 日本語, 简体中文, 繁體中文, Español, Français, Deutsch, Italiano, Português (BR)

### 요구 사항

- **macOS 14.0 이상** (Apple Intelligence 기능은 macOS 26 이상)

### 지원

- **버그 제보 / 기능 요청**: [Issues](https://github.com/LumiBearStudio/ClipRaven/issues)
- **Mac App Store**: 출시 준비 중

### 개인정보

- 모든 데이터는 Mac 내부에만 저장됩니다. 외부 전송·분석·통계 없음.
- AI 기능은 온디바이스 Apple Foundation Models(macOS 26+) 사용. 데이터가 기기 밖으로 나가지 않습니다.
- 상세: [PRIVACY.md](PRIVACY.md)

### 라이선스

[MIT](LICENSE)

---

© 2026 LumiBear Studio
