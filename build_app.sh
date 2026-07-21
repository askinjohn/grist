#!/bin/bash
set -e

# Define directories
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
APP_DIR="$PROJECT_DIR/Grist.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SRC="$PROJECT_DIR/Resources/AppIcon.icns"

# Pick a stable codesign identity so macOS TCC (Mic / Screen Recording) survives rebuilds.
# Prefer: CODESIGN_IDENTITY env → Apple Development cert → ad-hoc fallback.
resolve_codesign_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        echo "$CODESIGN_IDENTITY"
        return
    fi

    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' \
        | head -1)"

    if [[ -n "$identity" ]]; then
        echo "$identity"
        return
    fi

    # Last resort — ad-hoc. Rebuilds will often re-trigger permission prompts.
    echo "-"
}

echo "🔨 Building Grist binary..."
cd "$PROJECT_DIR"
swift build -c debug

echo "📦 Creating macOS App Bundle structure..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Copying binary to App Bundle..."
cp "$PROJECT_DIR/.build/debug/grist" "$MACOS_DIR/Grist"

if [[ -f "$ICON_SRC" ]]; then
    echo "🎨 Installing app icon..."
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
    ICON_PLIST_KEYS=$'\n    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n    <key>CFBundleIconName</key>\n    <string>AppIcon</string>'
else
    echo "⚠️  No Resources/AppIcon.icns found — using default icon."
    ICON_PLIST_KEYS=""
fi

echo "Writing Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Grist</string>
    <key>CFBundleIdentifier</key>
    <string>com.grist.meetingassistant</string>
    <key>CFBundleName</key>
    <string>Grist</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>${ICON_PLIST_KEYS}
    <key>NSMicrophoneUsageDescription</key>
    <string>Grist needs microphone access to transcribe your voice during meetings.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Grist needs screen recording permission to capture system audio from meeting calls.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Grist needs speech recognition permission to natively transcribe your meetings.</string>
</dict>
</plist>
EOF

# Ensure executable permissions
chmod +x "$MACOS_DIR/Grist"

IDENTITY="$(resolve_codesign_identity)"
if [[ "$IDENTITY" == "-" ]]; then
    echo "🔑 No Apple Development cert found — applying ad-hoc signature."
    echo "   ⚠️  Rebuilds may re-prompt for Microphone / Screen Recording."
    echo "   Fix: install Xcode, sign in with your Apple ID (free), then re-run."
    echo "   Or set CODESIGN_IDENTITY=\"Apple Development: you@example.com (TEAMID)\""
    codesign --force --deep --sign - "$APP_DIR"
else
    echo "🔑 Signing with stable identity (keeps Mic/Screen permissions across rebuilds):"
    echo "   $IDENTITY"
    # No hardened runtime: local app spawns ffmpeg/whisper and must stay simple.
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
fi

echo "✅ App successfully packaged at: $APP_DIR"
echo "   Signature:"
codesign -dv "$APP_DIR" 2>&1 | egrep 'Identifier|Authority|Signature|TeamIdentifier' || true

# Install a stable copy under ~/Applications so TCC binds to one consistent path
# (dev rebuilds from the repo alone often leave a stale "Grist" entry in Settings).
STABLE_APP="$HOME/Applications/Grist.app"
mkdir -p "$HOME/Applications"
echo "📥 Installing stable copy → $STABLE_APP"
rm -rf "$STABLE_APP"
cp -R "$APP_DIR" "$STABLE_APP"
# Re-sign the installed copy (copy can break signature seals)
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$STABLE_APP"
else
    codesign --force --deep --sign "$IDENTITY" "$STABLE_APP"
fi

echo "🛑 Terminating existing instance if running..."
killall "Grist" 2>/dev/null || true
sleep 1

echo "🚀 Launching stable app: $STABLE_APP"
open "$STABLE_APP"
echo ""
echo "ℹ️  Always open Grist from: $STABLE_APP"
echo "   Screen Recording: enable Grist once, then fully Quit and reopen."
echo "   If the system keeps nagging despite the toggle, run:"
echo "     tccutil reset ScreenCapture com.grist.meetingassistant"
echo "   then enable Grist again and relaunch."