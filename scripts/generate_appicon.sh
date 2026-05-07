#!/usr/bin/env bash
# ClipRaven AppIcon 자동 생성기
#
# 사용법:
#   ./scripts/generate_appicon.sh <master_1024.png>
#
# 동작:
#   1024×1024 PNG 한 장을 입력받아 10개 사이즈(AppIcon.appiconset)로 전개
#   알파 채널 제거 (MAS 요구사항)
#   Contents.json 동기화
set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
    echo "Usage: $0 <master_1024.png>"
    exit 1
fi

if [[ ! -f "$SRC" ]]; then
    echo "Error: $SRC not found"
    exit 1
fi

# 입력 크기 확인
SIZE=$(sips -g pixelWidth "$SRC" 2>/dev/null | awk '/pixelWidth/ {print $2}')
if [[ "$SIZE" != "1024" ]]; then
    echo "Warning: master image is ${SIZE}x — 1024x1024 expected"
fi

OUT="ClipRaven/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"

echo "→ Generating 10 icon sizes (16–512 @1x/@2x; 512@2x = 1024px covers marketing)…"
# Note: we intentionally do NOT emit a standalone 1024x1024 slot. Modern
# Xcode appiconset schemas only declare 16–512 at 1x/2x, and actool
# treats any additional entry as an "unassigned child" — the warning is
# harmless but on macOS 26 it can prevent the .icns from picking up the
# 1024 bitmap for Dock rendering, which manifests as the generic icon
# placeholder.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    SIZE="${entry%%:*}"
    NAME="${entry##*:}"
    sips -Z "$SIZE" "$SRC" --out "$OUT/$NAME" >/dev/null
    echo "   ✓ $NAME (${SIZE}×${SIZE})"
done

echo "→ Stripping alpha channel (MAS requirement)…"
for f in "$OUT"/*.png; do
    # sips 자체가 불투명 배경으로 평탄화해줌
    sips -s format png -s formatOptions normal "$f" --out "$f" >/dev/null
done

# Contents.json 갱신
echo "→ Updating Contents.json…"
cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",       "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",       "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",     "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",     "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",     "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo ""
echo "✅ Done. $(ls "$OUT"/*.png | wc -l | tr -d ' ') PNG files + Contents.json written to:"
echo "   $OUT/"
echo ""
echo "Next: open Xcode, verify AppIcon shows all sizes, then rebuild."
