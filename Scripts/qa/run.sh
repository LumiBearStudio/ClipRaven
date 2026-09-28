#!/bin/zsh
# QA 빌드를 만들고 실행한다 (테스트 계획 0단계).
#
#   Scripts/qa/run.sh [--reset] [--skip-onboarding] [--start-trial] [--trial-offset <일>]
#                     [--lang <코드>] [--default-hotkey] [--no-build]
#
#   --reset           QA 컨테이너의 기록·설정·체험 상태를 지우고 첫 실행으로 시작
#   --skip-onboarding 온보딩을 건너뜀
#   --start-trial     체험을 지금 시작한 것으로 기록 (이미 시작했으면 그대로)
#   --trial-offset N  체험 경과일을 N 일 앞당김. --start-trial 과 함께 16 이면 바로 만료
#   --lang ko|en|de…  앱 언어 (시스템 언어는 바꾸지 않는다)
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
reset=0; skip_onb=0; start_trial=0; lang=""; offset=""; default_hotkey=0; build=1
while (( $# )); do
  case "$1" in
    --reset) reset=1 ;;
    --skip-onboarding) skip_onb=1 ;;
    --start-trial) start_trial=1 ;;
    --lang) lang="$2"; shift ;;
    --trial-offset) offset="$2"; shift ;;
    --default-hotkey) default_hotkey=1 ;;
    --no-build) build=0 ;;
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
if (( ! default_hotkey )); then
  # ⌃⌥⌘V (kVK_ANSI_V = 9, controlKey|optionKey|cmdKey = 6400). 정수로 넘겨야 해서 plist 형식.
  args+=(-hotkey.keyCode "<integer>9</integer>" -hotkey.modifiers "<integer>6400</integer>")
fi

open -n "$APP" --args "${args[@]}"
print "launched ClipRaven QA ${args[*]}"
