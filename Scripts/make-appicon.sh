#!/bin/bash
# Design/AppIcon.svg から App/Assets.xcassets/AppIcon.appiconset を作る
# 使い方: ./Scripts/make-appicon.sh
# SVG のレンダリングは Quick Look（WebKit）を使う。ImageMagick の内蔵レンダラはフィルタや線を描けない

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Design/AppIcon.svg"
ASSETS="$ROOT/App/Assets.xcassets"
ICONSET="$ASSETS/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" "$SOURCE" > /dev/null 2>&1
MASTER="$WORK/AppIcon.svg.png"
[ -f "$MASTER" ] || { echo "エラー: $SOURCE のレンダリングに失敗しました"; exit 1; }

mkdir -p "$ICONSET"
rm -f "$ICONSET"/*.png

cat > "$ASSETS/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    if [ "$scale" = 1 ]; then name="icon_${size}x${size}.png"; else name="icon_${size}x${size}@2x.png"; fi
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" > /dev/null
    images="$images    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" },\n"
  done
done

printf '{\n  "images" : [\n%b  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "${images%,\\n}\n" > "$ICONSET/Contents.json"
echo "書き出し: $ICONSET"
