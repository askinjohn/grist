#!/bin/bash
# Grist interactive setup — clone, run this once, then ./build_app.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "$SCRIPT_DIR"

BUNDLE_ID="com.grist.meetingassistant"
GRIST_DATA_DIR="$HOME/Library/Application Support/Grist"

echo "╔══════════════════════════════════════════════╗"
echo "║         Grist Setup Wizard (macOS)           ║"
echo "║   Local AI meeting assistant — privacy first ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── helpers ──────────────────────────────────────────────────────────
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local reply
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " reply || true
        reply=${reply:-y}
    else
        read -r -p "$prompt [y/N]: " reply || true
        reply=${reply:-n}
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "❌ Missing required command: $1"
        echo "   $2"
        exit 1
    fi
}

# Write ~/Library/Application Support/Grist/ai-config.json (roles + backends).
# Args: local_url, openai_url, openai_key, chat_model, enhance_model, embed_model, default_backend (local|openai)
write_ai_config() {
    local local_url="${1:-http://127.0.0.1:11434}"
    local openai_url="${2:-https://api.openai.com/v1}"
    local openai_key="${3:-}"
    local chat_model="${4:-qwen2.5:7b}"
    local enhance_model="${5:-gemma2:2b}"
    local embed_model="${6:-nomic-embed-text}"
    local default_backend="${7:-local}"

    mkdir -p "$GRIST_DATA_DIR"
    local config_path="$GRIST_DATA_DIR/ai-config.json"

    GRIST_DATA_DIR="$GRIST_DATA_DIR" \
    LOCAL_URL="$local_url" OPENAI_URL="$openai_url" OPENAI_KEY="$openai_key" \
    CHAT_MODEL="$chat_model" ENHANCE_MODEL="$enhance_model" EMBED_MODEL="$embed_model" \
    DEFAULT_BACKEND="$default_backend" \
    python3 <<'PY'
import json, os
from pathlib import Path

local_url = os.environ["LOCAL_URL"]
openai_url = os.environ["OPENAI_URL"]
openai_key = os.environ.get("OPENAI_KEY") or ""
chat_model = os.environ["CHAT_MODEL"]
enhance_model = os.environ["ENHANCE_MODEL"]
embed_model = os.environ["EMBED_MODEL"]
default_backend = os.environ["DEFAULT_BACKEND"]
path = Path(os.environ["GRIST_DATA_DIR"]) / "ai-config.json"

chat_backend = light_backend = default_backend
embed_backend = "local"
if default_backend == "openai":
    embed_backend = "openai"
    light_backend = chat_backend = "openai"
    if embed_model == "nomic-embed-text":
        embed_model = "text-embedding-3-small"

cfg = {
    "version": 1,
    "backends": {
        "local": {"type": "ollama", "baseURL": local_url},
        "openai": {
            "type": "openai_compatible",
            "baseURL": openai_url,
            "apiKey": openai_key if openai_key.strip() else None,
            "apiKeyEnv": None if openai_key.strip() else "OPENAI_API_KEY",
        },
    },
    "roles": {
        "chat": {"backend": chat_backend, "model": chat_model},
        "askEverything": {"backend": chat_backend, "model": chat_model},
        "enhance": {"backend": light_backend, "model": enhance_model},
        "title": {"backend": light_backend, "model": enhance_model},
        "organize": {"backend": light_backend, "model": enhance_model},
        "folderSummarize": {"backend": light_backend, "model": enhance_model},
        "taskExtract": {"backend": light_backend, "model": enhance_model},
        "embed": {"backend": embed_backend, "model": embed_model},
    },
}
path.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"✅ Wrote AI role config: {path}")
print(f"   Chat / Ask everything → {chat_model} ({chat_backend})")
print(f"   Enhance / title / tasks → {enhance_model} ({light_backend})")
print(f"   Embeddings → {embed_model} ({embed_backend})")
print("   Edit later: Settings → AI Models (or edit the JSON file)")
PY
}

# ── 0. Preconditions ─────────────────────────────────────────────────
echo "📦 Checking system prerequisites..."

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "❌ Grist is a native macOS app (requires Apple Silicon / Intel Mac)."
    exit 1
fi

if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew is required. Install from https://brew.sh/ then re-run."
    exit 1
fi

if ! xcode-select -p &>/dev/null; then
    echo "❌ Xcode Command Line Tools missing."
    echo "   Run: xcode-select --install"
    exit 1
fi

require_cmd swift "Install Xcode Command Line Tools: xcode-select --install"
require_cmd git "Install git via Homebrew: brew install git"

if ! command -v cmake &>/dev/null; then
    echo "Installing cmake (needed for whisper.cpp)..."
    brew install cmake
fi

echo "Installing ffmpeg..."
brew install ffmpeg

echo "Installing yt-dlp (YouTube captions import)..."
brew install yt-dlp || true
if command -v yt-dlp &>/dev/null; then
    defaults write "$BUNDLE_ID" ytDlpPath "$(command -v yt-dlp)"
    echo "✅ yt-dlp at $(command -v yt-dlp)"
else
    echo "⚠️ yt-dlp not found — YouTube caption import will be unavailable until you: brew install yt-dlp"
fi

mkdir -p "$GRIST_DATA_DIR"

# ── 1. AI provider ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "🤖 Step 1: AI configuration"
echo "═══════════════════════════════════════════════"
echo "How should Grist generate summaries and chat?"
echo "  1) Ollama on this Mac (recommended, fully private)"
echo "  2) Ollama on another machine (remote URL)"
echo "  3) OpenAI-compatible API (OpenAI, SpaceXAI, LM Studio, etc.)"
echo ""
read -r -p "Choice [1/2/3] (default 1): " ai_choice || true
ai_choice=${ai_choice:-1}

case "$ai_choice" in
    2)
        read -r -p "Remote Ollama URL (e.g. http://192.168.1.100:11434): " custom_ollama_url
        if [[ -z "${custom_ollama_url// }" ]]; then
            echo "❌ URL required."
            exit 1
        fi
        read -r -p "Chat model on that host [qwen2.5:7b]: " remote_chat || true
        remote_chat=${remote_chat:-qwen2.5:7b}
        read -r -p "Enhance/title model [gemma2:2b]: " remote_enhance || true
        remote_enhance=${remote_enhance:-gemma2:2b}
        defaults write "$BUNDLE_ID" aiProviderType "Ollama"
        defaults write "$BUNDLE_ID" OllamaURL "$custom_ollama_url"
        write_ai_config "$custom_ollama_url" "https://api.openai.com/v1" "" "$remote_chat" "$remote_enhance" "nomic-embed-text" "local"
        echo "✅ Using remote Ollama at $custom_ollama_url"
        echo "   Ensure that host has: $remote_chat, $remote_enhance, nomic-embed-text"
        ;;
    3)
        read -r -p "API base URL [https://api.openai.com/v1]: " api_url || true
        api_url=${api_url:-https://api.openai.com/v1}
        read -r -p "API key: " api_key
        read -r -p "Chat model name [gpt-4o-mini]: " api_model || true
        api_model=${api_model:-gpt-4o-mini}
        read -r -p "Enhance model (can be same) [gpt-4o-mini]: " api_enhance || true
        api_enhance=${api_enhance:-$api_model}
        if [[ -z "${api_key// }" ]]; then
            echo "❌ API key required for OpenAI-compatible mode."
            exit 1
        fi
        defaults write "$BUNDLE_ID" aiProviderType "OpenAI Compatible"
        defaults write "$BUNDLE_ID" openAIBaseURL "$api_url"
        defaults write "$BUNDLE_ID" openAIAPIKey "$api_key"
        defaults write "$BUNDLE_ID" openAIModel "$api_model"
        defaults write "$BUNDLE_ID" OllamaURL "http://127.0.0.1:11434"
        write_ai_config "http://127.0.0.1:11434" "$api_url" "$api_key" "$api_model" "$api_enhance" "text-embedding-3-small" "openai"
        echo "✅ OpenAI-compatible provider saved (chat: $api_model)"
        echo "   Tip: you can still point embed/enhance at local Ollama later in Settings → AI Models."
        ;;
    *)
        echo "Installing Ollama locally..."
        brew install ollama
        # Start service if available
        if brew services list 2>/dev/null | grep -qi ollama; then
            brew services start ollama 2>/dev/null || brew services start Ollama 2>/dev/null || true
        fi
        # Also try launching ollama serve in case services aren't used
        if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            echo "Starting ollama serve in background..."
            nohup ollama serve >/dev/null 2>&1 &
            sleep 2
        fi

        echo ""
        echo "Pulling models (this may take a while)..."
        echo "  • qwen2.5:7b     — Chat + Ask everything (stronger grounding)"
        echo "  • gemma2:2b      — Enhance / titles / organize (fast)"
        echo "  • nomic-embed-text — RAG embeddings"
        echo ""
        ollama pull qwen2.5:7b
        ollama pull gemma2:2b
        ollama pull nomic-embed-text

        defaults write "$BUNDLE_ID" aiProviderType "Ollama"
        defaults write "$BUNDLE_ID" OllamaURL "http://127.0.0.1:11434"
        # Also seed toolbar default used by some screens
        defaults write "$BUNDLE_ID" selectedModel "qwen2.5:7b"
        write_ai_config "http://127.0.0.1:11434" "https://api.openai.com/v1" "" "qwen2.5:7b" "gemma2:2b" "nomic-embed-text" "local"
        echo "✅ Local Ollama ready at http://127.0.0.1:11434"
        ;;
esac

# ── 2. Whisper ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "🧠 Step 2: Speech-to-text (Whisper)"
echo "═══════════════════════════════════════════════"

if ask_yn "Do you already have whisper.cpp built on this machine?" "n"; then
    read -r -p "Path to whisper-cli binary: " custom_whisper_bin
    read -r -p "Path to ggml model file (e.g. ggml-base.bin): " custom_whisper_model
    if [[ ! -x "$custom_whisper_bin" && ! -f "$custom_whisper_bin" ]]; then
        echo "❌ Binary not found: $custom_whisper_bin"
        exit 1
    fi
    if [[ ! -f "$custom_whisper_model" ]]; then
        echo "❌ Model not found: $custom_whisper_model"
        exit 1
    fi
    defaults write "$BUNDLE_ID" whisperBinaryPath "$custom_whisper_bin"
    defaults write "$BUNDLE_ID" whisperModelPath "$custom_whisper_model"
    echo "✅ Custom Whisper paths saved"
else
    echo "Building whisper.cpp with Metal (CoreML OFF — avoids missing .mlmodelc failures)..."
    cd "$GRIST_DATA_DIR"
    if [[ ! -d whisper.cpp/.git ]]; then
        rm -rf whisper.cpp
        git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
    fi
    cd whisper.cpp

    # Critical: CoreML without encoder models makes whisper-cli exit on every run.
    cmake -B build -DGGML_METAL=ON -DWHISPER_COREML=OFF
    cmake --build build --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

    if [[ ! -f models/ggml-base.bin ]]; then
        echo "Downloading ggml-base model..."
        bash models/download-ggml-model.sh base
    fi

    defaults delete "$BUNDLE_ID" whisperBinaryPath 2>/dev/null || true
    defaults delete "$BUNDLE_ID" whisperModelPath 2>/dev/null || true
    echo "✅ Whisper ready at $GRIST_DATA_DIR/whisper.cpp"
    cd "$SCRIPT_DIR"
fi

# ── 3. MCP server ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "🔌 Step 3: MCP server (Claude Desktop / agents)"
echo "═══════════════════════════════════════════════"

MCP_DIR="$SCRIPT_DIR/grist-mcp-server"
MCP_BIN="$MCP_DIR/grist-mcp-server"

ensure_bun() {
    if command -v bun &>/dev/null; then
        return 0
    fi
    echo "Installing Bun (used to compile a standalone MCP binary — no Node/NVM needed at runtime)..."
    curl -fsSL https://bun.sh/install | bash
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
    require_cmd bun "Bun install failed. See https://bun.sh"
}

build_mcp() {
    ensure_bun
    cd "$MCP_DIR"
    echo "Installing MCP dependencies..."
    bun install
    echo "Compiling standalone MCP binary..."
    bun build ./index.js --compile --outfile grist-mcp-server
    chmod +x grist-mcp-server
    cd "$SCRIPT_DIR"
    echo "✅ MCP binary: $MCP_BIN"
}

configure_claude_desktop() {
    local mcp_path="$1"
    python3 - "$mcp_path" <<'PY'
import json, os, sys
mcp_path = sys.argv[1]
config_path = os.path.expanduser("~/Library/Application Support/Claude/claude_desktop_config.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except json.JSONDecodeError:
    print("Warning: existing claude_desktop_config.json was invalid; recreating.")
    config = {}

config.setdefault("mcpServers", {})
config["mcpServers"]["grist"] = {"command": mcp_path, "args": []}
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"Wrote grist MCP entry → {config_path}")
PY
}

if ask_yn "Build the Grist MCP server (lets Claude Desktop read/write notes)?" "y"; then
    build_mcp

    if ask_yn "Configure Claude Desktop automatically?" "y"; then
        if [[ -f "$MCP_BIN" ]]; then
            configure_claude_desktop "$MCP_BIN"
            echo "✅ Claude Desktop configured. Fully quit & reopen Claude to load the server."
        else
            echo "⚠️ MCP binary missing; skipped Claude config."
        fi
    else
        echo "Manual Claude Desktop config snippet:"
        echo "  \"grist\": { \"command\": \"$MCP_BIN\", \"args\": [] }"
    fi
else
    echo "Skipped MCP build. You can re-run setup later or: cd grist-mcp-server && bun install && bun build ./index.js --compile --outfile grist-mcp-server"
fi

# ── 4. Optional first build ──────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "🚀 Step 4: Build the app"
echo "═══════════════════════════════════════════════"

if ask_yn "Build and launch Grist now?" "y"; then
    chmod +x "$SCRIPT_DIR/build_app.sh"
    "$SCRIPT_DIR/build_app.sh"
else
    echo "When you're ready:"
    echo "  ./build_app.sh"
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║                 Setup complete               ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "First-run permissions (required once):"
echo "  • Microphone          — allow when prompted"
echo "  • Screen & System Audio Recording — enable Grist, then quit & relaunch"
echo "    (needed to capture Zoom/Meet/YouTube audio, not just the mic)"
echo ""
echo "App installs to:  ~/Applications/Grist.app"
echo "Data directory:   $GRIST_DATA_DIR"
echo "AI config:        $GRIST_DATA_DIR/ai-config.json"
echo "  (Settings → AI Models — change chat vs enhance models anytime)"
echo "Re-run setup anytime:  ./setup.sh"
echo ""
