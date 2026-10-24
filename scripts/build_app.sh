#!/bin/zsh
# Build "Extra Magic Mouse.app" with SwiftPM and sign it.
# Usage: ./scripts/build_app.sh [--dmg] [--install]
#   --dmg      also package build/ExtraMagicMouse.dmg (drag-to-Applications disk image)
#   --install  copy the app to /Applications and launch it
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

MAKE_DMG=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ExtraMagicMouse"

APP="build/Extra Magic Mouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ExtraMagicMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# --- Code signing (stable identity → Accessibility permission survives rebuilds)
SELF_SIGNED="ExtraMagicMouse Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/emm-signing.keychain-db"
KEYCHAIN_ARG=()
if [[ -n "${EMM_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$EMM_SIGN_IDENTITY"
else
    IDENTITY="$SELF_SIGNED"
    "$PROJECT_DIR/scripts/setup_signing.sh" >/dev/null  # create once, then unlock + authorize
    KEYCHAIN_ARG=(--keychain "$SIGN_KEYCHAIN")
fi
codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARG[@]}" \
    --identifier com.seth.extramagicmouse "$APP"
codesign --verify --strict "$APP"
echo "Built and signed: $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"

if [[ $MAKE_DMG == 1 ]]; then
    DMG=build/ExtraMagicMouse.dmg
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Extra Magic Mouse" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Built $DMG"
fi

if [[ $INSTALL == 1 ]]; then
    pkill -x ExtraMagicMouse 2>/dev/null || true
    rm -rf "/Applications/Extra Magic Mouse.app"
    cp -R "$APP" /Applications/
    open "/Applications/Extra Magic Mouse.app"
    echo "Installed to /Applications and launched."
fi
