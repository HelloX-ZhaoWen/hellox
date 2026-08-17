#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
OUTPUT_ROOT=${1:-"$PROJECT_ROOT/build/icon"}
ICONSET_ROOT="$OUTPUT_ROOT/AppIcon.iconset"
ICNS_PATH="$OUTPUT_ROOT/AppIcon.icns"

/bin/rm -rf "$ICONSET_ROOT"
/bin/mkdir -p "$OUTPUT_ROOT" "$ICONSET_ROOT"
/usr/bin/swift "$PROJECT_ROOT/Packaging/AppIcon.swift" "$ICONSET_ROOT"
/usr/bin/iconutil -c icns "$ICONSET_ROOT" -o "$ICNS_PATH"
echo "$ICNS_PATH"
