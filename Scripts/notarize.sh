#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Packaging/Info.plist")
DMG_PATH="$PROJECT_ROOT/build/HelloX-$VERSION.dmg"
PROFILE=${HELLOX_NOTARY_PROFILE:?Set HELLOX_NOTARY_PROFILE to a notarytool keychain profile}

[[ -f "$DMG_PATH" ]] || "$PROJECT_ROOT/Scripts/create-dmg.sh"
/usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
