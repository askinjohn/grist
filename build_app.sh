#!/bin/bash
set -e

# Define directories
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
APP_DIR="$PROJECT_DIR/Quern.app"
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

echo "🔨 Building Quern and Today widget..."
cd "$PROJECT_DIR"
command -v xcodegen >/dev/null || { echo "xcodegen is required to build the widget" >&2; exit 1; }
xcodegen generate
xcodebuild -quiet -project Quern.xcodeproj -scheme Quern -configuration Debug \
    -derivedDataPath "$PROJECT_DIR/.build/widget" CODE_SIGNING_ALLOWED=NO build

echo "📦 Packaging Quern and embedded widget..."
BUILT_APP="$PROJECT_DIR/.build/widget/Build/Products/Debug/Quern.app"
[[ -d "$BUILT_APP/Contents/PlugIns/QuernTodayWidget.appex" ]] || { echo "Widget extension missing" >&2; exit 1; }
rm -rf "$APP_DIR"
cp -R "$BUILT_APP" "$APP_DIR"

IDENTITY="$(resolve_codesign_identity)"
if [[ "$IDENTITY" == "-" ]]; then
    echo "🔑 No Apple Development cert found — applying ad-hoc signature."
    echo "   ⚠️  Rebuilds may re-prompt for Microphone / Screen Recording."
    echo "   Fix: install Xcode, sign in with your Apple ID (free), then re-run."
    echo "   Or set CODESIGN_IDENTITY=\"Apple Development: you@example.com (TEAMID)\""
else
    echo "🔑 Signing with a stable development identity."
fi

# Derive the team locally rather than committing a developer's team identifier.
# Xcode normally expands TeamIdentifierPrefix; manual signing needs the same
# expansion in generated (git-ignored) entitlement files.
codesign --force --sign "$IDENTITY" "$APP_DIR"
SIGNING_TEAM="$(codesign -dv "$APP_DIR" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$IDENTITY" == "-" ]]; then
    APP_GROUP_PREFIX="group."
else
    [[ -n "$SIGNING_TEAM" && "$SIGNING_TEAM" != "not set" ]] || { echo "Could not resolve signing team" >&2; exit 1; }
    APP_GROUP_PREFIX="$SIGNING_TEAM."
fi
SIGNING_DIR="$PROJECT_DIR/.build/signing"
mkdir -p "$SIGNING_DIR"
python3 - "$PROJECT_DIR/Widget" "$SIGNING_DIR" "$APP_GROUP_PREFIX" <<'PYTHON'
import pathlib
import plistlib
import sys
source, destination = map(pathlib.Path, sys.argv[1:3])
for name in ("Quern.entitlements", "QuernWidget.entitlements"):
    with (source / name).open("rb") as stream:
        content = plistlib.load(stream)
    content["com.apple.security.application-groups"] = [
        group.replace("$(TeamIdentifierPrefix)", sys.argv[3])
        for group in content["com.apple.security.application-groups"]
    ]
    with (destination / name).open("wb") as stream:
        plistlib.dump(content, stream)
PYTHON
codesign --force --sign "$IDENTITY" --entitlements "$SIGNING_DIR/QuernWidget.entitlements" "$APP_DIR/Contents/PlugIns/QuernTodayWidget.appex"
codesign --force --sign "$IDENTITY" --entitlements "$SIGNING_DIR/Quern.entitlements" "$APP_DIR"

echo "✅ App successfully packaged at: $APP_DIR"
echo "   Signature:"
codesign -dv "$APP_DIR" 2>&1 | egrep 'Identifier|Authority|Signature|TeamIdentifier' || true

# ---------------------------------------------------------------------------
# DMG (shareable disk image: drag Quern.app → Applications)
# SKIP_DMG=1 ./build_app.sh  — skip image
# ---------------------------------------------------------------------------
DMG_PATH="$PROJECT_DIR/Quern.dmg"
if [[ "${SKIP_DMG:-}" == "1" ]]; then
    echo "⏭  Skipping DMG (SKIP_DMG=1)"
else
    echo "💿 Creating disk image → $DMG_PATH"
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/quern-dmg.XXXXXX")"
    cleanup_stage() { rm -rf "$STAGE"; }
    trap cleanup_stage EXIT

    cp -R "$APP_DIR" "$STAGE/Quern.app"
    # Drag-and-drop install target
    ln -s /Applications "$STAGE/Applications"

    # Optional readme on the volume
    cat > "$STAGE/README.txt" <<'README'
Quern — privacy-first AI notes & meeting assistant

1. Drag Quern.app into Applications
2. Open Quern from Applications (or Spotlight)
3. Grant Microphone + Screen & System Audio Recording when prompted
4. Fully quit and reopen after enabling Screen Recording

Dependencies (see project README / setup.sh):
  - Ollama + models (or OpenAI-compatible endpoint)
  - Whisper / ffmpeg paths from setup
  - yt-dlp for YouTube captions (optional)

https://github.com/askinjohn/quern
README

    rm -f "$DMG_PATH"
    # UDZO = compressed read-only image (standard for distribution)
    hdiutil create \
        -volname "Quern" \
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
# (dev rebuilds from the repo alone often leave a stale "Quern" entry in Settings).
STABLE_APP="$HOME/Applications/Quern.app"
if [[ "${SKIP_INSTALL:-}" == "1" ]]; then
    echo "⏭  Skipping install to ~/Applications (SKIP_INSTALL=1)"
else
    mkdir -p "$HOME/Applications"
    echo "📥 Installing stable copy → $STABLE_APP"
    rm -rf "$STABLE_APP"
    cp -R "$APP_DIR" "$STABLE_APP"
    codesign --verify --deep --strict "$STABLE_APP"
fi

if [[ "${SKIP_LAUNCH:-}" == "1" ]]; then
    echo "⏭  Skipping launch (SKIP_LAUNCH=1)"
else
    echo "🛑 Terminating existing instance if running..."
    killall "Quern" 2>/dev/null || true
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
echo "   Screen Recording: enable Quern once, then fully Quit and reopen."
echo "   If the system keeps nagging despite the toggle, run:"
echo "     tccutil reset ScreenCapture com.quern.meetingassistant"
echo "   then enable Quern again and relaunch."
echo ""
echo "   Env flags: SKIP_DMG=1  SKIP_INSTALL=1  SKIP_LAUNCH=1"
