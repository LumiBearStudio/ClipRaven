# ClipRaven Privacy Policy

**LumiBear Studio** · Effective September 26, 2026

[English](#english) · [한국어](#korean)

---

<a id="english"></a>

## English

### Summary

- Your clipboard history stays on your devices. We run no server that receives it, and we cannot see it.
- Nothing leaves your device unless you turn it on. iCloud Sync, crash reports, and link previews are all off until you enable them.
- No accounts, no ads, no analytics, no tracking.

### What ClipRaven keeps on your device

ClipRaven saves what you copy so you can find it and paste it again:

- Copied text, links, code, images, and files. On Mac, a copied file is saved as a reference to where it is on your disk.
- Text recognized inside images (OCR). Recognition runs on your device using Apple's Vision framework.
- What you add yourself: tags, nicknames, pins, shortcuts, and rules.
- The name of the app you copied from, used for filters and for excluded apps.
- On Mac with Apple Intelligence (macOS 26 or later): a category for each clip, created on your device by Apple's Foundation Models. You can turn this off in Settings › AI & Automation.

This data is stored in ClipRaven's private app container on your device. On iPhone and iPad it is shared only with ClipRaven's own keyboard and share extension, through a private app group.

ClipRaven also avoids saving sensitive copies:

- By default, it skips items that password managers mark as confidential, copies that look like passwords or card numbers, and two-factor codes. You can change this in Settings › Privacy.
- You can list apps whose copies should never be saved.

### Optional features that use the network

**iCloud Sync (off by default).** When you turn it on, ClipRaven syncs your clips between your own devices using Apple's CloudKit, in the private database of your iCloud account. Apple stores this data; we have no access to it.

What syncs: clip text and links, text recognized in images, tags, nicknames, pins and order, the source app name, link titles, AI categories, and a random identifier for each installation so your devices can tell their own changes apart. Images sync as small thumbnails by default; in Settings you can choose not to sync images or to include the originals.

Clips that look like passwords, card numbers, or API keys, and anything copied from a password manager, stay on the device where they were copied and are never synced.

To stop syncing, turn off iCloud Sync in ClipRaven. To delete what is already in iCloud, open Settings on iPhone or iPad (System Settings on Mac) › your name › iCloud › Manage Storage › ClipRaven.

**Crash reports (off by default).** If you turn them on, ClipRaven sends a report to Sentry, a crash-reporting service run by Functional Software, Inc., only when the app crashes. A report contains technical details such as where in the code the crash happened, the device model, the OS and app versions, and a short list of recent app events (for example, "app launched"). It never contains your clipboard contents, clip text, file names, your name, or your Apple ID. Sentry is set not to store IP addresses, and reports are processed in Sentry's EU (Germany) data region. We use reports only to fix bugs, and Sentry deletes them after its retention period. You can turn crash reports off at any time in Settings › Privacy; the change takes effect immediately.

**Link previews (Mac only, off by default).** When you turn them on, ClipRaven fetches the title and preview image of links you copy, using Apple's LinkPresentation framework. Your Mac contacts each linked website directly, the same way opening the link in a browser would, so that website can see your IP address. Nothing is sent to us.

### Permissions

- **Clipboard.** On Mac, ClipRaven reads the clipboard when it changes, to save your copies. On iPhone and iPad, iOS asks you before ClipRaven reads the clipboard.
- **Pasting on Mac (Accessibility).** To paste the clip you choose into the app you are using, ClipRaven sends a ⌘V keystroke. macOS asks you to allow this in System Settings › Privacy & Security › Accessibility. ClipRaven uses this permission only to send that keystroke. It does not read your screen, other apps' content, or what you type.
- **ClipRaven keyboard and "Allow Full Access" (iPhone and iPad).** The keyboard needs Full Access only to read your ClipRaven history from the app's private shared container. It does not record what you type, and it makes no network connections.

### Purchases and the free trial

Apple handles all purchases. We never receive your payment details or your Apple ID. The date your free trial started is saved only on your device: in ClipRaven's app data on Mac, and in the Keychain on iPhone and iPad.

### Keeping and deleting your data

- Clips stay on your device until you delete them or they pass the limits you set in Settings (number of clips to keep and days to keep them).
- Deleting the app on iPhone or iPad deletes its data. On Mac, macOS keeps an app's data after the app is deleted. To remove it, delete your clips in ClipRaven first, or delete the folders `~/Library/Containers/com.lumibear.ClipRaven` and `~/Library/Group Containers/63ZN5B3LHU.com.lumibear.ClipRaven`.
- iCloud data and crash reports: see above.

### Your choices and rights

Crash reports and link previews rely on your consent, which you can withdraw at any time in Settings. We do not hold your clipboard data, so you control it directly on your device. Crash reports are anonymous; if you want reports from your device deleted, email us with the approximate date and device, and we will delete matching reports.

### Children

ClipRaven is not directed at children and does not knowingly collect information from anyone, including children under 13.

### Changes to this policy

When this policy changes, we update the effective date at the top and describe significant changes in the app's release notes.

### Contact

Email: nwlsrb@gmail.com
GitHub: [github.com/LumiBearStudio/ClipRaven/issues](https://github.com/LumiBearStudio/ClipRaven/issues)

---

<a id="korean"></a>

## 한국어

### 요약

- 클립보드 기록은 사용자의 기기 안에 있습니다. 개발자는 이 데이터를 받는 서버를 두지 않으며, 볼 수도 없습니다.
- 사용자가 직접 켜지 않는 한 기기 밖으로 나가는 데이터는 없습니다. iCloud 동기화, 크래시 리포트, 링크 미리보기는 모두 켜기 전까지 꺼져 있습니다.
- 계정, 광고, 분석, 추적이 없습니다.

### 기기에 저장하는 데이터

ClipRaven은 복사한 내용을 다시 찾아 붙여넣을 수 있도록 저장합니다.

- 복사한 텍스트, 링크, 코드, 이미지, 파일. Mac에서 복사한 파일은 디스크 위치를 가리키는 참조로 저장합니다.
- 이미지 속 글자 인식(OCR) 결과. Apple Vision 프레임워크로 기기 안에서 처리합니다.
- 사용자가 추가한 태그, 별명, 고정, 단축키, 규칙.
- 복사한 앱의 이름. 필터와 제외 앱 기능에 씁니다.
- Apple Intelligence를 쓰는 Mac(macOS 26 이상)에서는 클립마다 분류를 붙입니다. Apple Foundation Models가 기기 안에서 만들며, 설정 › AI & 자동화에서 끌 수 있습니다.

이 데이터는 기기 안의 ClipRaven 전용 앱 컨테이너에 저장됩니다. iPhone과 iPad에서는 비공개 앱 그룹을 통해 ClipRaven의 키보드와 공유 확장하고만 공유합니다.

민감한 복사는 저장하지 않도록 합니다.

- 기본적으로 비밀번호 관리자가 기밀로 표시한 항목, 비밀번호나 카드 번호로 보이는 내용, 2단계 인증 코드는 저장하지 않습니다. 설정 › 개인정보에서 바꿀 수 있습니다.
- 복사해도 저장하지 않을 앱을 지정할 수 있습니다.

### 네트워크를 쓰는 선택 기능

**iCloud 동기화 (기본값: 꺼짐).** 켜면 Apple CloudKit으로 사용자 iCloud 계정의 비공개 데이터베이스를 통해 본인 기기끼리 클립을 동기화합니다. 이 데이터는 Apple이 보관하며 개발자는 접근할 수 없습니다.

동기화 항목: 클립 텍스트와 링크, 이미지에서 인식한 글자, 태그, 별명, 고정과 순서, 복사한 앱 이름, 링크 제목, AI 분류, 그리고 기기끼리 서로의 변경을 구분하기 위한 설치별 무작위 식별자. 이미지는 기본적으로 작은 썸네일만 동기화하며, 설정에서 이미지를 동기화하지 않거나 원본까지 포함하도록 고를 수 있습니다.

비밀번호, 카드 번호, API 키로 보이는 클립과 비밀번호 관리자에서 복사한 항목은 복사한 기기에만 남고 동기화되지 않습니다.

동기화를 멈추려면 ClipRaven에서 iCloud 동기화를 끄세요. 이미 iCloud에 올라간 데이터를 지우려면 iPhone·iPad의 설정(Mac은 시스템 설정) › 사용자 이름 › iCloud › 저장 공간 관리 › ClipRaven에서 삭제하세요.

**크래시 리포트 (기본값: 꺼짐).** 켜면 앱이 비정상 종료될 때에만 크래시 리포트 서비스인 Sentry(Functional Software, Inc. 운영)로 보고서를 보냅니다. 보고서에는 코드의 어느 부분에서 종료됐는지, 기기 모델, OS와 앱 버전, 최근 앱 이벤트 몇 줄(예: "앱 실행") 같은 기술 정보만 들어갑니다. 클립보드 내용, 클립 텍스트, 파일 이름, 이름, Apple ID는 절대 포함하지 않습니다. Sentry는 IP 주소를 저장하지 않도록 설정되어 있고, 보고서는 Sentry의 EU(독일) 데이터 리전에서 처리됩니다. 보고서는 버그 수정에만 쓰며, Sentry의 보존 기간이 지나면 삭제됩니다. 설정 › 개인정보에서 언제든 끌 수 있고, 끄면 바로 적용됩니다.

**링크 미리보기 (Mac 전용, 기본값: 꺼짐).** 켜면 복사한 링크의 제목과 미리보기 이미지를 Apple LinkPresentation 프레임워크로 가져옵니다. 브라우저로 링크를 열 때처럼 Mac이 해당 웹사이트에 직접 접속하므로, 그 웹사이트는 사용자의 IP 주소를 볼 수 있습니다. 개발자에게 전송되는 것은 없습니다.

### 권한

- **클립보드.** Mac에서는 클립보드가 바뀔 때 읽어 복사 기록을 저장합니다. iPhone과 iPad에서는 ClipRaven이 클립보드를 읽기 전에 iOS가 허용 여부를 묻습니다.
- **Mac에서 붙여넣기 (손쉬운 사용).** 고른 클립을 사용 중인 앱에 붙여넣기 위해 ⌘V 키 입력을 보냅니다. macOS가 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 허용하도록 안내합니다. 이 권한은 그 키 입력을 보내는 데에만 씁니다. 화면, 다른 앱의 내용, 사용자가 입력하는 내용은 읽지 않습니다.
- **ClipRaven 키보드와 "전체 접근 허용" (iPhone·iPad).** 키보드는 앱의 비공개 공유 컨테이너에서 ClipRaven 기록을 읽기 위해서만 전체 접근이 필요합니다. 입력하는 내용을 기록하지 않으며, 네트워크에 연결하지 않습니다.

### 구매와 무료 체험

모든 구매는 Apple이 처리합니다. 개발자는 결제 정보나 Apple ID를 받지 않습니다. 무료 체험 시작일은 해당 기기에만 저장합니다. Mac에서는 ClipRaven 앱 데이터에, iPhone과 iPad에서는 키체인에 저장합니다.

### 보관과 삭제

- 클립은 사용자가 지우거나 설정에서 정한 한도(보관 개수, 보관 기간)를 넘을 때까지 기기에 남습니다.
- iPhone과 iPad에서는 앱을 삭제하면 데이터도 함께 삭제됩니다. Mac에서는 앱을 삭제해도 macOS가 앱 데이터를 남겨 둡니다. 지우려면 ClipRaven에서 클립을 먼저 삭제하거나 `~/Library/Containers/com.lumibear.ClipRaven` 폴더와 `~/Library/Group Containers/63ZN5B3LHU.com.lumibear.ClipRaven` 폴더를 삭제하세요.
- iCloud 데이터와 크래시 리포트는 위 설명을 참고하세요.

### 선택권과 권리

크래시 리포트와 링크 미리보기는 사용자의 동의로 동작하며, 설정에서 언제든 철회할 수 있습니다. 개발자는 클립보드 데이터를 보관하지 않으므로 사용자가 기기에서 직접 관리합니다. 크래시 리포트는 익명입니다. 본인 기기에서 보낸 리포트의 삭제를 원하면 대략적인 날짜와 기기를 이메일로 알려 주세요. 해당하는 리포트를 삭제하겠습니다.

### 아동

ClipRaven은 아동을 대상으로 하지 않으며, 만 13세 미만 아동을 포함한 누구의 정보도 알면서 수집하지 않습니다.

### 방침 변경

이 방침이 바뀌면 맨 위의 시행일을 고치고, 중요한 변경은 앱 업데이트 설명에 적습니다.

### 문의

이메일: nwlsrb@gmail.com
GitHub: [github.com/LumiBearStudio/ClipRaven/issues](https://github.com/LumiBearStudio/ClipRaven/issues)
