# Grist

**Privacy-first AI meeting assistant for macOS.**

Grist records your microphone **and** system audio (Zoom, Meet, Teams, YouTube, …), transcribes locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and generates summaries / action items with a local or remote LLM. Nothing is sent to a cloud unless **you** choose an OpenAI-compatible API.

It also ships an **MCP server** so Claude Desktop (or any MCP client) can list folders and create notes in your Grist database.

---

## Features

| Feature | Details |
|--------|---------|
| **Mic + system audio** | AVFoundation + ScreenCaptureKit (no BlackHole) |
| **Local transcription** | whisper.cpp + Apple Metal |
| **AI summaries & chat** | Ollama (local/remote) **or** OpenAI-compatible APIs |
| **Folders & templates** | Organize meetings; custom summary prompts |
| **RAG chat** | Ask questions across meetings in a folder |
| **Import from URL** | Pull article text into a note |
| **MCP** | `list_folders`, `create_note` for Claude Desktop |
| **One-shot setup** | `./setup.sh` wizard — AI, Whisper, MCP |

---

## Requirements

- **macOS 15+**
- [Homebrew](https://brew.sh/)
- Xcode Command Line Tools (`xcode-select --install`)
- Apple Silicon or Intel Mac

Optional:

- [Claude Desktop](https://claude.ai/download) — for MCP
- Free **Apple ID** signed into Xcode (recommended so Screen Recording / Mic permissions stick across rebuilds)

---

## Quick start

```bash
git clone https://github.com/<your-account>/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh
```

The wizard asks you:

1. **AI configuration**
   - Ollama on this Mac (default — pulls `gemma2:2b` + `nomic-embed-text`)
   - Remote Ollama URL
   - OpenAI-compatible API (base URL, key, model)
2. **Whisper** — auto-build Metal whisper.cpp, or point at your own binary/model  
3. **MCP** — compile a standalone server binary and optionally wire Claude Desktop  
4. **Build** — run `./build_app.sh` and launch Grist

After setup you can always rebuild with:

```bash
./build_app.sh
```

That compiles Swift, signs the app (Apple Development cert if available), installs to:

```text
~/Applications/Grist.app
```

and launches it.

---

## First-run permissions

macOS will ask for access **once** per app identity:

| Permission | Why |
|------------|-----|
| **Microphone** | Your voice |
| **Screen & System Audio Recording** | Capture meeting / browser audio |

After enabling **Screen & System Audio Recording** for Grist, **fully quit and reopen** the app. Until then, recordings are mic-only (YouTube/Zoom won’t appear in the transcript).

If the system keeps prompting even though the toggle looks on:

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

Then open `~/Applications/Grist.app`, start a short recording, enable Grist again, quit, and relaunch.

---

## AI configuration

### During setup

`./setup.sh` writes preferences under `com.grist.meetingassistant`.

### Later (in the app)

**Settings → General → AI Engine Configuration**

- **Ollama (Local)** — URL, default `http://127.0.0.1:11434`
- **OpenAI Compatible** — base URL, API key, model

### Later (terminal)

```bash
# Ollama
defaults write com.grist.meetingassistant aiProviderType "Ollama"
defaults write com.grist.meetingassistant OllamaURL "http://127.0.0.1:11434"

# OpenAI-compatible
defaults write com.grist.meetingassistant aiProviderType "OpenAI Compatible"
defaults write com.grist.meetingassistant openAIBaseURL "https://api.openai.com/v1"
defaults write com.grist.meetingassistant openAIAPIKey "sk-..."
defaults write com.grist.meetingassistant openAIModel "gpt-4o"
```

---

## MCP (Claude Desktop)

Setup builds a **standalone** binary (via [Bun](https://bun.sh)) so Claude does not depend on your Node/NVM path:

```text
grist-mcp-server/grist-mcp-server
```

Claude Desktop config (written automatically if you opt in):

```json
{
  "mcpServers": {
    "grist": {
      "command": "/absolute/path/to/grist/grist-mcp-server/grist-mcp-server",
      "args": []
    }
  }
}
```

Tools:

- **`list_folders`** — folder names in Grist  
- **`create_note`** — create a note (`title`, `content`, optional `folder`)

Data lives in:

```text
~/Library/Application Support/Grist/meetings.db
```

Rebuild MCP only:

```bash
cd grist-mcp-server
bun install
bun build ./index.js --compile --outfile grist-mcp-server
```

---

## Project layout

```text
grist/
├── Sources/grist/          # SwiftUI app
├── grist-mcp-server/       # MCP server source (binary built by setup)
├── setup.sh                # Interactive install wizard
├── build_app.sh            # Build, sign, install to ~/Applications, launch
├── Package.swift
└── README.md
```

| Component | Role |
|-----------|------|
| `AudioRecorder` | Mic + system audio |
| `WhisperTranscriber` | ffmpeg + whisper.cpp |
| `OllamaClient` | Ollama or OpenAI-compatible HTTP |
| `RAGEngine` | Chunk + embed + search |
| `Database` | SQLite meetings / folders / chat / chunks |
| MCP server | External agent access to notes |

---

## Development

```bash
./build_app.sh          # debug build + relaunch
swift build -c debug    # compile only
```

Signing: `build_app.sh` prefers an **Apple Development** identity (free with an Apple ID in Xcode) so Mic/Screen permissions survive rebuilds. Override with:

```bash
export CODESIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXX)"
./build_app.sh
```

Without a cert, it falls back to ad-hoc signing (permissions may re-prompt after rebuilds).

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Transcript is `you you` / empty | Mic-only silence — enable **Screen & System Audio Recording**, quit & relaunch, play system audio while recording |
| `Whisper.cpp process failed` | Rebuild whisper **without CoreML**: re-run `./setup.sh` Whisper step (uses `-DWHISPER_COREML=OFF`) |
| No summaries | Check Ollama is running / API key; open Settings → AI Engine |
| RAG chat weak | Ensure `nomic-embed-text` is pulled (`ollama pull nomic-embed-text`) |
| Claude can’t see Grist MCP | Restart Claude; confirm binary path in `claude_desktop_config.json` |
| Permission sheet every launch | Open only `~/Applications/Grist.app`; use Development signing; avoid ad-hoc |

---

## Privacy

- Default path: **all local** (mic, system audio, Whisper, Ollama).
- OpenAI-compatible mode sends transcript/notes to the endpoint you configure — only if you choose it.
- No telemetry in Grist itself.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributing

Issues and PRs welcome. Please keep the “clone → `./setup.sh` → record” path working for new contributors.
