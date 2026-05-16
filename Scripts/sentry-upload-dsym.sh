#!/bin/bash
#
# Sentry dSYM 자동 업로드 스크립트.
#
# Xcode Build Phase 의 Run Script 안에서 호출. Archive (Release) 빌드 시점에
# 생성된 dSYM 파일을 Sentry 의 해당 project 에 자동 업로드해서 출시 후 crash
# report 가 symbolicated stack trace 로 표시되도록 한다.
#
# 인증: $SRCROOT/.sentryclirc 의 auth token (sentry-cli 자동 인식).
# .sentryclirc 는 .gitignore 되어 있어 token 이 vcs 에 노출되지 않는다.
#
# Xcode Build Phase 등록 방법:
# 1. Xcode 프로젝트 선택 → 각 main app target (ClipRaven / ClipRavenMobile)
# 2. Build Phases 탭 → + → New Run Script Phase
# 3. Shell: /bin/bash
# 4. Script: "$SRCROOT/Scripts/sentry-upload-dsym.sh"
# 5. (선택) Run script: only when installing 체크 — Archive 빌드만 실행

set -e

# 1) Debug 빌드는 skip — 개발 중 매 빌드마다 Sentry 호출 회피.
if [ "$CONFIGURATION" != "Release" ]; then
    echo "[sentry-dsym] skip ($CONFIGURATION build)"
    exit 0
fi

# 2) sentry-cli 설치 여부 확인.
if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "[sentry-dsym] warn: sentry-cli not found. install:"
    echo "  brew install getsentry/tools/sentry-cli"
    exit 0  # 빌드 자체는 실패시키지 않음.
fi

# 3) macOS / iOS Sentry project 분기. Universal Purchase 라 양쪽 bundle ID
#    동일 (com.lumibear.ClipRaven) 이므로 PLATFORM_NAME 으로 식별.
case "$PLATFORM_NAME" in
    macosx)
        SENTRY_PROJECT=4511348541489232
        ;;
    iphoneos)
        SENTRY_PROJECT=4511348636778576
        ;;
    iphonesimulator)
        # Simulator dSYM 은 무의미 (crash report 없음).
        echo "[sentry-dsym] skip ($PLATFORM_NAME)"
        exit 0
        ;;
    *)
        echo "[sentry-dsym] warn: unknown PLATFORM_NAME=$PLATFORM_NAME — skipping"
        exit 0
        ;;
esac

# 4) dSYM 폴더 검증.
if [ -z "$DWARF_DSYM_FOLDER_PATH" ]; then
    echo "[sentry-dsym] warn: DWARF_DSYM_FOLDER_PATH not set (run inside Xcode Build Phase)"
    exit 0
fi

echo "[sentry-dsym] uploading from $DWARF_DSYM_FOLDER_PATH (org=lumibear-studio project=$SENTRY_PROJECT)"

# 5) Upload. --include-sources 는 Swift source code 도 함께 업로드해서
#    Sentry 의 stack trace 에서 해당 라인 미리보기까지 표시. (source maps)
sentry-cli debug-files upload \
    --org lumibear-studio \
    --project "$SENTRY_PROJECT" \
    --include-sources \
    "$DWARF_DSYM_FOLDER_PATH"

echo "[sentry-dsym] done"
