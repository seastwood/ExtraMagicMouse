#!/bin/zsh
# Build "Extra Magic Mouse.app" with SwiftPM and sign it.
# Usage: ./scripts/build_app.sh [--install]   (--install copies it to /Applications)
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

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
echo "Built and signed: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ExtraMagicMouse 2>/dev/null || true
    rm -rf "/Applications/Extra Magic Mouse.app"
    cp -R "$APP" /Applications/
    open "/Applications/Extra Magic Mouse.app"
    echo "Installed to /Applications and launched."
fi
