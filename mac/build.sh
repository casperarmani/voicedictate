#!/bin/zsh
# Builds Voice Dictate.app, signs it, installs it to /Applications and opens it.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Voice Dictate"
BUNDLE_ID="com.casper.voicedictate"
DEST="/Applications/$APP_NAME.app"
APP="build/$APP_NAME.app"

echo "==> Compiling (release)"
if ! swift build -c release --arch arm64 2>&1 | { grep -vE '^\[' || true; }; then
    echo "Build failed"; exit 1
fi
BIN=".build/arm64-apple-macosx/release/VoiceDictate"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceDictate"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/silero_vad.mlmodelc "$APP/Contents/Resources/"

# A stable signing identity keeps macOS permissions (Microphone, Accessibility)
# attached to the app across rebuilds. Ad-hoc signing would reset them every build.
IDENTITY="${VD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
    echo "!! No 'Apple Development' signing identity found; signing ad-hoc."
    echo "!! Permissions will need re-granting after each rebuild. Set VD_SIGN_IDENTITY to fix."
    IDENTITY="-"
fi
echo "==> Signing with $IDENTITY"
codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "==> Installing to $DEST"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -xq VoiceDictate || break; sleep 0.25; done
pkill -x VoiceDictate 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "==> Done: $DEST"
[[ "${1:-}" == "--no-open" ]] && exit 0

# Hand the key from .env to the app; it saves it to the Keychain itself
# (items the app creates can be read later without password prompts).
KEY="$(grep -E '^OPENAI_API_KEY=' ../.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" || true)"
if [[ -n "$KEY" ]]; then
    open --env "OPENAI_API_KEY=$KEY" "$DEST"
else
    open "$DEST"
fi
