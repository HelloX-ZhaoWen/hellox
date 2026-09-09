#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
APP_ROOT="$PROJECT_ROOT/build/HelloX.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Packaging/Info.plist")
PKG_PATH="$PROJECT_ROOT/build/HelloX-$VERSION.pkg"
PAYLOAD_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/HelloX-pkg.XXXXXX")
INSTALLER_IDENTITY=${HELLOX_INSTALLER_IDENTITY:-}

cleanup() {
  [[ -d "$PAYLOAD_ROOT" ]] && /bin/rm -rf "$PAYLOAD_ROOT"
}
trap cleanup EXIT

[[ -d "$APP_ROOT" ]] || "$PROJECT_ROOT/Scripts/build-app.sh"
/bin/mkdir -p "$PAYLOAD_ROOT/Applications"
/usr/bin/ditto "$APP_ROOT" "$PAYLOAD_ROOT/Applications/HelloX.app"
/bin/rm -f "$PKG_PATH"

SIGN_ARGS=()
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  SIGN_ARGS=(--sign "$INSTALLER_IDENTITY")
fi

/usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$PROJECT_ROOT/Packaging/InstallerScripts" \
  --component-plist "$PROJECT_ROOT/Packaging/Component.plist" \
  --install-location / \
  --identifier com.hellox.app.installer \
  --version "$VERSION" \
  --ownership recommended \
  "${SIGN_ARGS[@]}" \
  "$PKG_PATH"

(
  cd "$PROJECT_ROOT/build"
  /usr/bin/shasum -a 256 "HelloX-$VERSION.pkg" > "HelloX-$VERSION.pkg.sha256"
)

echo "Created $PKG_PATH"
echo "Created $PKG_PATH.sha256"
