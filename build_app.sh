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

# ---------------------------------------------------------------------------
# DMG (shareable disk image: drag Grist.app → Applications)
# SKIP_DMG=1 ./build_app.sh  — skip image
# ---------------------------------------------------------------------------
DMG_PATH="$PROJECT_DIR/Grist.dmg"
if [[ "${SKIP_DMG:-}" == "1" ]]; then
    echo "⏭  Skipping DMG (SKIP_DMG=1)"
else
    echo "💿 Creating disk image → $DMG_PATH"
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/grist-dmg.XXXXXX")"
    cleanup_stage() { rm -rf "$STAGE"; }
    trap cleanup_stage EXIT

    cp -R "$APP_DIR" "$STAGE/Grist.app"
    # Drag-and-drop install target
    ln -s /Applications "$STAGE/Applications"

    # Optional readme on the volume
    cat > "$STAGE/README.txt" <<'README'
Grist — privacy-first AI notes & meeting assistant

1. Drag Grist.app into Applications
2. Open Grist from Applications (or Spotlight)
3. Grant Microphone + Screen & System Audio Recording when prompted
4. Fully quit and reopen after enabling Screen Recording

Dependencies (see project README / setup.sh):
  - Ollama + models (or OpenAI-compatible endpoint)
  - Whisper / ffmpeg paths from setup
  - yt-dlp for YouTube captions (optional)

https://github.com/askinjohn/grist
README

    rm -f "$DMG_PATH"
    # UDZO = compressed read-only image (standard for distribution)
    hdiutil create \
        -volname "Grist" \
        -srcfolder "$STAGE" \
        -ov \
        -format UDZO \
        -fs HFS+ \
        "$DMG_PATH" >/dev/null

    cleanup_stage
    trap - EXIT

    DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
    echo "✅ DMG ready: $DMG_PATH ($DMG_SIZE)"
    echo "   Open with: open \"$DMG_PATH\""
fi

# Install a stable copy under ~/Applications so TCC binds to one consistent path
# (dev rebuilds from the repo alone often leave a stale "Grist" entry in Settings).
STABLE_APP="$HOME/Applications/Grist.app"
if [[ "${SKIP_INSTALL:-}" == "1" ]]; then
    echo "⏭  Skipping install to ~/Applications (SKIP_INSTALL=1)"
else
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
fi

if [[ "${SKIP_LAUNCH:-}" == "1" ]]; then
    echo "⏭  Skipping launch (SKIP_LAUNCH=1)"
else
    echo "🛑 Terminating existing instance if running..."
    killall "Grist" 2>/dev/null || true
    sleep 1

    if [[ -d "$STABLE_APP" ]]; then
        echo "🚀 Launching stable app: $STABLE_APP"
        open "$STABLE_APP"
    else
        echo "🚀 Launching packaged app: $APP_DIR"
        open "$APP_DIR"
    fi
fi

echo ""
echo "ℹ️  Artifacts:"
echo "   App bundle:  $APP_DIR"
[[ -f "$DMG_PATH" ]] && echo "   Disk image:  $DMG_PATH"
[[ -d "$STABLE_APP" ]] && echo "   Installed:   $STABLE_APP"
echo ""
echo "   Prefer opening from: ${STABLE_APP:-$APP_DIR}"
echo "   Screen Recording: enable Grist once, then fully Quit and reopen."
echo "   If the system keeps nagging despite the toggle, run:"
echo "     tccutil reset ScreenCapture com.grist.meetingassistant"
echo "   then enable Grist again and relaunch."
echo ""
echo "   Env flags: SKIP_DMG=1  SKIP_INSTALL=1  SKIP_LAUNCH=1"