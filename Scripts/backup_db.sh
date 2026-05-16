#!/usr/bin/env bash
# ClipRaven 로컬 DB 긴급 백업 스크립트
#
# 사용법:
#   ./scripts/backup_db.sh              # 기본: ~/Desktop/ClipRavenBackups/<timestamp>
#   ./scripts/backup_db.sh /tmp/foo     # 지정 경로에 저장
#
# 무엇을 복사하나:
#   1. 샌드박스 컨테이너의 SQLite 본체 + WAL + SHM
#   2. images/ 디렉터리 (로컬 원본 이미지)
#   3. UserDefaults plist (sync 플래그·deviceId 등 설정 스냅샷)
#
# 언제 쓰나:
#   - Phase B 이상 iCloud sync 기동 **직전** (원상복구 지점 확보).
#   - Migration 실험 전.
#   - 기존 기능 회귀 의심 시.
#
# 복원:
#   1. ClipRaven 종료 후
#   2. 이 스크립트가 출력한 디렉터리의 파일을 원래 경로로 덮어쓰기
#   3. 재실행
set -euo pipefail

CONTAINER="$HOME/Library/Containers/com.lumibear.ClipRaven"
DB_SRC="$CONTAINER/Data/Library/Application Support/ClipRaven"
PREFS_SRC="$CONTAINER/Data/Library/Preferences/com.lumibear.ClipRaven.plist"

if [[ ! -d "$DB_SRC" ]]; then
    echo "❌ ClipRaven sandbox container not found."
    echo "   Expected: $DB_SRC"
    echo "   Did you run the app at least once?"
    exit 1
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DEST="${1:-$HOME/Desktop/ClipRavenBackups/$TIMESTAMP}"

# 안전장치: 지정 경로가 이미 존재하면 덮어쓰지 않는다.
# 기본 타임스탬프 경로는 항상 유일하므로 이 체크는 사용자가 $1을 넘겼을 때만 실제로 걸림.
if [[ -e "$DEST" ]]; then
    echo "❌ Destination already exists, refusing to overwrite: $DEST"
    echo "   Remove it or choose a different path."
    exit 1
fi

mkdir -p "$DEST"

# 진행 중 manifest를 먼저 남긴다. 중간에 실패해도 $DEST의 BACKUP_INFO.txt만
# 열어보면 완료되지 않았음을 알 수 있도록. trap으로 실패 경로도 커버.
cat > "$DEST/BACKUP_INFO.txt" <<EOF
ClipRaven DB backup
STATUS:    IN_PROGRESS
Started:   $(date)
Host:      $(hostname)
EOF
trap 'echo "STATUS:    FAILED at $(date)" >> "$DEST/BACKUP_INFO.txt"' ERR

echo "→ Source: $DB_SRC"
echo "→ Dest:   $DEST"
echo ""

# 1. SQLite 본체 + 사이드 파일 (WAL/SHM이 없으면 조용히 스킵)
echo "→ Copying database files…"
for f in clipraven.sqlite clipraven.sqlite-wal clipraven.sqlite-shm; do
    if [[ -f "$DB_SRC/$f" ]]; then
        cp -c "$DB_SRC/$f" "$DEST/$f"
        echo "   ✓ $f ($(wc -c < "$DB_SRC/$f" | tr -d ' ') bytes)"
    fi
done

# 2. 이미지 디렉터리 (있을 때만)
if [[ -d "$DB_SRC/images" ]]; then
    IMG_COUNT=$(find "$DB_SRC/images" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$IMG_COUNT" -gt 0 ]]; then
        echo "→ Copying images ($IMG_COUNT files)…"
        cp -cR "$DB_SRC/images" "$DEST/images"
    fi
fi

# 3. UserDefaults plist
if [[ -f "$PREFS_SRC" ]]; then
    echo "→ Copying preferences plist…"
    cp -c "$PREFS_SRC" "$DEST/com.lumibear.ClipRaven.plist"
fi

# 4. 메타 정보 — 모든 복사가 끝난 뒤에만 STATUS를 COMPLETE로 덮어쓴다.
{
    echo "ClipRaven DB backup"
    echo "STATUS:    COMPLETE"
    echo "Taken at:  $(date)"
    echo "Host:      $(hostname)"
    echo "macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "Git HEAD:  $(cd "$(dirname "$0")/.." && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Branch:    $(cd "$(dirname "$0")/.." && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
} > "$DEST/BACKUP_INFO.txt"
trap - ERR

echo ""
echo "✅ Backup complete."
echo "   $DEST"
echo ""
echo "To restore: quit ClipRaven, copy the files back to:"
echo "   $DB_SRC/"
