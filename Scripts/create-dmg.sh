#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
APP_ROOT="$PROJECT_ROOT/build/HelloX.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Packaging/Info.plist")
DMG_PATH="$PROJECT_ROOT/build/HelloX-$VERSION.dmg"
PKG_PATH="$PROJECT_ROOT/build/HelloX-$VERSION.pkg"
STAGING_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/HelloX-dmg.XXXXXX")

cleanup() {
  [[ -d "$STAGING_ROOT" ]] && /bin/rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

[[ -d "$APP_ROOT" ]] || "$PROJECT_ROOT/Scripts/build-app.sh"
"$PROJECT_ROOT/Scripts/create-pkg.sh"
rm -f "$DMG_PATH"
/usr/bin/ditto "$PKG_PATH" "$STAGING_ROOT/安装 HelloX.pkg"
/bin/mkdir -p "$STAGING_ROOT/.update"
/usr/bin/ditto "$APP_ROOT" "$STAGING_ROOT/.update/HelloX.app"
/usr/bin/hdiutil create -volname HelloX -srcfolder "$STAGING_ROOT" -ov -format UDZO "$DMG_PATH"
(
  cd "$PROJECT_ROOT/build"
  /usr/bin/shasum -a 256 "HelloX-$VERSION.dmg" > "HelloX-$VERSION.dmg.sha256"
)

echo "Created $DMG_PATH"
echo "Created $DMG_PATH.sha256"
