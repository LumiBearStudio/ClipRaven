# ClipRaven Privacy Policy

Last updated: 2026-04-17

**[English](#english)** · **[한국어](#한국어)**

---

<a id="english"></a>

## English

### Summary

ClipRaven is a local-first macOS app. **No data ever leaves your Mac.** We do not collect, transmit, store, or share any personal information, telemetry, or analytics.

### What ClipRaven stores (on your Mac only)

- Your clipboard history (text, code, URLs, images, files, colors)
- Your tags, smart rules, pin status, custom shortcuts
- OCR text extracted from images
- AI-generated classification and summaries (macOS 26+, all on-device)

All of the above is stored locally under:

```
~/Library/Application Support/ClipRaven/
```

This data never leaves your Mac.

### What ClipRaven does NOT do

- No analytics, no telemetry, no crash reporting to any third party
- No accounts, no sign-up, no cloud sync
- No advertisements or third-party SDKs
- No network calls except what you explicitly initiate (e.g., opening a URL in your browser)

### Apple Intelligence (macOS 26+)

When you opt in to Apple Intelligence features (automatic classification and summarization), ClipRaven uses Apple's on-device Foundation Models framework. Per Apple's design, these models run entirely on your Mac. ClipRaven does not send your clipboard content to any server.

### Accessibility permissions

ClipRaven requests **Accessibility** permission so it can paste clips into the currently active app (via synthesized `⌘V`). This permission is used only to post paste events; ClipRaven does not monitor your typing or read content from other apps.

### Clipboard monitoring

macOS notifies apps when the clipboard changes. ClipRaven reads the clipboard to capture your copy history. macOS may show a "ClipRaven accessed the clipboard" banner — this is expected.

### Contact

For privacy questions or concerns, open an issue at:
https://github.com/LumiBearStudio/ClipRaven/issues

---

<a id="한국어"></a>

## 한국어

### 요약

ClipRaven은 로컬 전용 macOS 앱입니다. **모든 데이터는 Mac 안에만 있습니다.** 개인정보, 통계, 분석 데이터를 외부로 수집·전송·저장·공유하지 않습니다.

### ClipRaven이 저장하는 것 (Mac 내부)

- 클립보드 히스토리 (텍스트 / 코드 / URL / 이미지 / 파일 / 색상)
- 태그, 스마트 규칙, 고정 상태, 커스텀 단축키
- 이미지에서 추출한 OCR 텍스트
- AI 자동 분류·요약 결과 (macOS 26+, 온디바이스)

저장 경로:

```
~/Library/Application Support/ClipRaven/
```

이 데이터는 Mac 밖으로 절대 나가지 않습니다.

### ClipRaven이 하지 않는 것

- 외부 분석·통계·크래시 리포팅 없음
- 계정, 가입, 클라우드 동기화 없음
- 광고·서드파티 SDK 없음
- 외부 네트워크 호출 없음 (사용자가 직접 URL을 브라우저로 여는 경우 제외)

### Apple Intelligence (macOS 26+)

자동 분류·요약 기능을 활성화하면 Apple의 온디바이스 Foundation Models를 사용합니다. Apple의 설계에 따라 이 모델은 Mac 내부에서만 동작합니다. ClipRaven은 클립보드 내용을 외부 서버로 전송하지 않습니다.

### 접근성 권한

활성 앱에 클립을 붙여넣기(⌘V 이벤트 합성) 위해 **손쉬운 사용(Accessibility)** 권한을 요청합니다. 이 권한은 붙여넣기 이벤트 전송에만 사용되며, 사용자 입력을 모니터링하거나 다른 앱의 내용을 읽지 않습니다.

### 클립보드 감시

macOS는 클립보드가 변경될 때 앱에 알립니다. ClipRaven은 복사 히스토리를 저장하기 위해 클립보드를 읽습니다. macOS가 "ClipRaven이 클립보드에 접근함" 배너를 표시하는 것은 정상입니다.

### 문의

개인정보 관련 문의는 아래 이슈 트래커로 남겨주세요:
https://github.com/LumiBearStudio/ClipRaven/issues

---

© 2026 LumiBear Studio 🐻
