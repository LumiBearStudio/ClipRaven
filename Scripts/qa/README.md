# QA 빌드

테스트 계획 0단계. 평소 쓰는 ClipRaven 의 기록·설정·체험 상태를 건드리지 않고
앱 전체를 테스트하기 위한 도구다.

## 무엇이 분리되는가

| 항목 | 평소 앱 (Debug/Release) | QA 빌드 |
|---|---|---|
| 번들 ID | `com.lumibear.ClipRaven` | `com.lumibear.ClipRaven.qa` ("ClipRaven QA") |
| 기록 DB·이미지 | 앱 컨테이너 | QA 컨테이너 |
| 설정(UserDefaults) | 앱 컨테이너 | QA 컨테이너 |
| App Group·체험 시작일 | `63ZN5B3LHU.com.lumibear.ClipRaven` | `…ClipRaven.qa` |
| iCloud·푸시 | 있음 | 없음 (동기화 꺼짐, iCloud 설정 탭 숨김) |

QA 전용 코드는 `QA` 컴파일 플래그(빌드 구성 `Debug-QA`)와 번들 ID `.qa` 확인을 함께 거친다.
구성 이름에 `Debug` 가 들어가야 Xcode 가 Swift 패키지도 Debug 로 빌드한다(테스트의
`@testable import ClipRavenSync` 가 필요로 한다).
App Store 빌드에서는 어느 쪽도 참이 될 수 없다.

단위 테스트(`xcodebuild test`, ⌘U)도 `Debug-QA` 구성으로 돈다. 테스트 호스트는 앱을
시작하지 않고(`AppRuntime.isRunningUnitTests`), 기록 DB 는 프로세스별 임시 폴더를 쓴다.

## 실행

```bash
Scripts/qa/run.sh --reset            # 첫 실행 상태로 시작 (온보딩부터)
Scripts/qa/run.sh --lang de          # 독일어로 실행
Scripts/qa/run.sh --reset --skip-onboarding --start-trial --trial-offset 16  # 바로 체험 만료 상태
Scripts/qa/run.sh --default-hotkey   # 기본 단축키 ⇧⌘V 로 (평소 앱을 끈 뒤)
```

기본 단축키는 ⌃⌥⌘V 로 바꿔 실행한다. 평소 앱이 ⇧⌘V 를 쓰고 있기 때문이다.

### 출시 설정 빌드 시험 (Release-QA)

빌드 구성 `Release-QA` 는 Release 와 같은 코드·최적화(QA 플래그 없음)에 번들 ID·App Group 만 QA 것으로
바꾼 것이다. 제출할 빌드가 실제 기록을 건드리지 않고도 제대로 뜨는지 볼 때 쓴다(QA 장면 명령은 없다).

```bash
xcodebuild -scheme ClipRaven -configuration Release-QA -derivedDataPath build/release-qa build
```

## 클립보드 주입

```bash
swift Scripts/qa/pbwrite.swift text "감사합니다"
swift Scripts/qa/pbwrite.swift concealed "hunter2"      # 비밀번호 관리자 표시
swift Scripts/qa/pbwrite.swift image ~/Desktop/shot.png
```

일반 클립보드에 쓰면 평소 앱도 기록한다. E2E 중에는 평소 앱의 캡처를 일시정지하거나
종료해 둔다. `--pasteboard <이름>` 을 주면 이름 붙은 보드에 써서 도구만 점검할 수 있다.

## App Store 스크린샷

```bash
Scripts/qa/run.sh --reset --skip-onboarding --start-trial --lang en --screenshots
swift Scripts/qa/pbwrite.swift text "…" --source com.apple.Notes   # 카드에 메모 앱 아이콘
swift Scripts/qa/scene.swift 'stage:Everything you copy|One keystroke away'
swift Scripts/qa/scene.swift panel      # 배경 위에 패널
swift Scripts/qa/scene.swift search:launch   # 패널을 열고 검색 (한국어 초성도 된다: search:ㄱㅅ)
swift Scripts/qa/scene.swift 'stage:…|…|light'  # 밝은 배경 (run.sh … -- -theme light 와 함께)
swift Scripts/qa/scene.swift settings:privacy
swift Scripts/qa/scene.swift paywall
swift Scripts/qa/scene.swift snap       # 앱이 ⇧⌘3 을 눌러 데스크탑에 저장
swift Scripts/qa/scene.swift clear
```

배경은 내장 화면에 깔리고 패널도 그 화면에 뜬다(외장 모니터를 쓰는 중이어도). 촬영 중에는 다른 곳을 클릭해도 패널이 닫히지 않는다.

`--screenshots` 는 "화면 공유 시 패널 숨기기"를 이번 실행에서만 끈다. 켜져 있으면 화면
캡처에 패널이 빠진다. 캡처는 시스템 단축키(⇧⌘3)로 한다(`snap` 이 앱 안에서 누른다 — 다른 앱이 앞으로 오면 패널이 닫히기 때문) — 15인치 MacBook Air 기준
2880×1864 이므로 위 64px 를 잘라 App Store 규격 2880×1800 을 만든다.

## 사람이 해야 하는 것

QA 빌드의 붙여넣기 권한(시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용 › ClipRaven QA)
은 처음 한 번 직접 허용한다.
