#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
OUTPUT_ROOT="$PROJECT_ROOT/build"
APP_ROOT="$OUTPUT_ROOT/HelloX.app"
IDENTITY=${HELLOX_CODESIGN_IDENTITY:--}

cd "$PROJECT_ROOT"
swift build -c release --arch arm64 --scratch-path "$OUTPUT_ROOT/arm64"
swift build -c release --arch x86_64 --scratch-path "$OUTPUT_ROOT/x86_64"

/bin/rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
/usr/bin/env zsh "$PROJECT_ROOT/Scripts/generate-app-icon.sh" "$OUTPUT_ROOT/icon" >/dev/null
/usr/bin/lipo -create \
  "$OUTPUT_ROOT/arm64/arm64-apple-macosx/release/HelloX" \
  "$OUTPUT_ROOT/x86_64/x86_64-apple-macosx/release/HelloX" \
  -output "$APP_ROOT/Contents/MacOS/HelloX"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$OUTPUT_ROOT/icon/AppIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"

APP_RESOURCE_BUNDLE="$OUTPUT_ROOT/arm64/arm64-apple-macosx/release/HelloX_HelloXApp.bundle"
[[ -d "$APP_RESOURCE_BUNDLE" ]] || {
  echo "Missing HelloX application resource bundle." >&2
  exit 1
}
cp -R "$APP_RESOURCE_BUNDLE" "$APP_ROOT/Contents/Resources/"

if [[ "$IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --deep --options runtime \
    --requirements '=designated => identifier "com.hellox.app"' \
    --entitlements "$PROJECT_ROOT/Packaging/HelloX.entitlements" \
    --sign - "$APP_ROOT"
else
  /usr/bin/codesign --force --deep --options runtime --timestamp \
    --entitlements "$PROJECT_ROOT/Packaging/HelloX.entitlements" \
    --sign "$IDENTITY" "$APP_ROOT"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_ROOT"
echo "Built $APP_ROOT"
