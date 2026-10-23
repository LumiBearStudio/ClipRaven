#!/bin/zsh
# QA 빌드를 만들고 실행한다 (테스트 계획 0단계).
#
#   Scripts/qa/run.sh [--reset] [--skip-onboarding] [--start-trial] [--trial-offset <일>]
#                     [--lang <코드>] [--default-hotkey] [--screenshots] [--preview-price <가격>] [--no-build] [-- <앱 인자…>]
#
#   --reset           QA 컨테이너의 기록·설정·체험 상태를 지우고 첫 실행으로 시작
#   --skip-onboarding 온보딩을 건너뜀
#   --start-trial     체험을 지금 시작한 것으로 기록 (이미 시작했으면 그대로)
#   --trial-offset N  체험 경과일을 N 일 앞당김. --start-trial 과 함께 16 이면 바로 만료
#   --lang ko|en|de…  앱 언어 (시스템 언어는 바꾸지 않는다)
#   --screenshots     화면 캡처에 패널이 찍히게 한다 (App Store 스크린샷용)
#   --preview-price <가격>  구매 창에 이 가격을 보여 준다 (앱 내 구입 심사용 스크린샷)
#   -- <인자…>        나머지를 앱 실행 인자로 넘긴다 (예: -- -theme light -colorPreset ocean)
#   --default-hotkey  앱 기본 단축키(⇧⌘V) 사용. 없으면 ⌃⌥⌘V — 평소 쓰는 ClipRaven 과
#                     겹치지 않게 하기 위해서다.
#   --no-build        빌드 없이 마지막 QA 빌드를 실행
#
# QA 앱: com.lumibear.ClipRaven.qa / "ClipRaven QA". 평소 쓰는 ClipRaven 과 컨테이너,
# App Group, 체험 상태가 모두 분리돼 있다.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DERIVED="$PWD/build/qa"
APP="$DERIVED/Build/Products/Debug-QA/ClipRaven.app"
extra=()
reset=0; skip_onb=0; start_trial=0; lang=""; offset=""; default_hotkey=0; screenshots=0; preview_price=""; build=1
while (( $# )); do
  case "$1" in
    --reset) reset=1 ;;
    --skip-onboarding) skip_onb=1 ;;
    --start-trial) start_trial=1 ;;
    --lang) lang="$2"; shift ;;
    --trial-offset) offset="$2"; shift ;;
    --default-hotkey) default_hotkey=1 ;;
    --screenshots) screenshots=1 ;;
    --preview-price) preview_price="$2"; shift ;;
    --no-build) build=0 ;;
    --) shift; extra=("$@"); break ;;
    *) print -u2 "unknown option: $1"; exit 64 ;;
  esac
  shift
done

if (( build )); then
  xcodebuild -project ClipRaven.xcodeproj -scheme ClipRaven -configuration Debug-QA \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build
fi
[[ -d "$APP" ]] || { print -u2 "QA app not found: $APP"; exit 1; }

# 이전 QA 인스턴스만 종료한다 (경로로 구분 — 평소 쓰는 ClipRaven 은 건드리지 않는다).
pkill -f "$APP/Contents/MacOS/ClipRaven" 2>/dev/null && sleep 1 || true

args=()
(( reset )) && args+=(-qaReset YES)
(( skip_onb )) && args+=(-hasCompletedOnboarding YES)
(( start_trial )) && args+=(-qaStartTrial YES)
[[ -n "$lang" ]] && args+=(-AppleLanguages "($lang)")
[[ -n "$offset" ]] && args+=(-qaTrialOffsetDays "$offset")
# 패널은 기본으로 화면 캡처에서 숨는다(설정 › 개인정보). 스크린샷을 찍을 때만 끈다.
# 앱이 `object(forKey:) as? Bool` 로 읽어서 "NO" 문자열이 아니라 plist 불리언으로 넘긴다.
(( screenshots )) && args+=(-hideOnScreenSharing "<false/>" -clipraven.panelHeight "<real>380</real>")
# 구매 창에 가격을 미리 보여 준다 (QA 빌드에는 App Store 상품이 없다 — 심사용 스크린샷 전용).
[[ -n "$preview_price" ]] && args+=(-qaPreviewPrice "$preview_price")
if (( ! default_hotkey )); then
  # ⌃⌥⌘V (kVK_ANSI_V = 9, controlKey|optionKey|cmdKey = 6400). 정수로 넘겨야 해서 plist 형식.
  args+=(-hotkey.keyCode "<integer>9</integer>" -hotkey.modifiers "<integer>6400</integer>")
fi

args+=("${extra[@]}")
open -n "$APP" --args "${args[@]}"
print "launched ClipRaven QA ${args[*]}"
