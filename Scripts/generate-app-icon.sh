#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
OUTPUT_ROOT=${1:-"$PROJECT_ROOT/build/icon"}
ICONSET_ROOT="$OUTPUT_ROOT/AppIcon.iconset"
ICNS_PATH="$OUTPUT_ROOT/AppIcon.icns"
SOURCE_ICON="$PROJECT_ROOT/Packaging/AppIconSource.png"

/bin/rm -rf "$ICONSET_ROOT"
/bin/mkdir -p "$OUTPUT_ROOT" "$ICONSET_ROOT"

[[ -f "$SOURCE_ICON" ]] || {
  echo "Missing application icon source: $SOURCE_ICON" >&2
  exit 1
}

typeset -a ICON_OUTPUTS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for output in "${ICON_OUTPUTS[@]}"; do
  filename=${output%%:*}
  pixels=${output##*:}
  /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE_ICON" \
    --out "$ICONSET_ROOT/$filename" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET_ROOT" -o "$ICNS_PATH"
echo "$ICNS_PATH"
