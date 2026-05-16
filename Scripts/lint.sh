#!/usr/bin/env bash
#
# ClipRaven 코드 lint 스크립트.
# SwiftLint 가 설치되어 있으면 실행하고, 아니면 친절히 안내한다.
#
# 사용법:
#   scripts/lint.sh              # 전체 검사
#   scripts/lint.sh --fix        # 자동 수정 가능한 항목 수정
#   scripts/lint.sh --baseline   # baseline (violation 수) 만 출력
#
# Xcode 빌드 페이즈로 자동 실행하려면 아래 한 줄을 새 Run Script 에 추가:
#   if which swiftlint >/dev/null; then swiftlint --quiet; fi

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
    cat <<EOF >&2
swiftlint 명령이 PATH 에 없습니다.

설치:
  brew install swiftlint

설치 후 다시 실행하세요.
EOF
    exit 0   # SwiftLint 미설치는 빌드를 실패시키지 않는다 (선택적 도구).
fi

case "${1:-}" in
    --fix)
        echo "[lint] swiftlint --fix (자동 수정)"
        swiftlint --fix
        ;;
    --baseline)
        echo "[lint] swiftlint baseline (violation 카운트)"
        swiftlint --quiet --reporter csv | tail -n +2 | wc -l | xargs echo "violations:"
        ;;
    *)
        swiftlint
        ;;
esac
