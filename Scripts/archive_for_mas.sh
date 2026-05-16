#!/usr/bin/env bash
# ClipRaven MAS Archive 자동화
#
# 사용법:
#   ./scripts/archive_for_mas.sh
#
# 전제조건:
#   - Apple Developer Program 가입 완료
#   - Xcode에서 팀 선택 (Signing & Capabilities → Team)
#   - App Store Connect에 앱 레코드 생성됨
#   - Bundle ID com.lumibear.ClipRaven 등록됨
#
# 동작:
#   1. CURRENT_PROJECT_VERSION(빌드 번호) +1 자동 증가
#   2. Release 구성으로 Archive 생성
#   3. 결과 경로 안내 (Xcode Organizer에서 Distribute App으로 업로드)
set -euo pipefail

PROJECT="ClipRaven.xcodeproj"
SCHEME="ClipRaven"
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
ARCHIVE_PATH="$ARCHIVE_DIR/ClipRaven_$TIMESTAMP.xcarchive"

# Developer 디렉토리 확인
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "Error: DEVELOPER_DIR not found: $DEVELOPER_DIR"
    exit 1
fi

echo "→ Bumping CURRENT_PROJECT_VERSION…"
# xcrun agvtool next-version -all
CURRENT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$PROJECT/project.pbxproj" | awk -F'= ' '{print $2}' | tr -d ';')
NEXT_BUILD=$((CURRENT_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PROJECT/project.pbxproj"
echo "   Build: $CURRENT_BUILD → $NEXT_BUILD"

echo ""
echo "→ Running tests first (gate)…"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    test 2>&1 | tail -5

echo ""
echo "→ Creating Archive…"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive 2>&1 | tail -10

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "❌ Archive failed"
    exit 1
fi

echo ""
echo "✅ Archive created:"
echo "   $ARCHIVE_PATH"
echo ""
echo "Next steps:"
echo "  1. open -a Xcode  (Organizer 자동 표시)"
echo "  2. Window → Organizer → Archives 탭"
echo "  3. 방금 만든 archive 선택 → Distribute App"
echo "  4. App Store Connect → Upload"
echo ""
echo "Or via CLI with exportOptionsPlist:"
echo "  xcodebuild -exportArchive -archivePath '$ARCHIVE_PATH' \\"
echo "    -exportPath ./build/export -exportOptionsPlist ExportOptions.plist"
