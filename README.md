# Grist

**Privacy-first AI notes & meeting assistant for macOS.**

Capture meetings (mic + system audio), write notes, import **articles** or **YouTube captions**, and let local AI summarize, title, and organize. Optional OpenAI-compatible APIs. Optional **MCP** for Claude Desktop.

---

## Features

| Feature | Details |
|--------|---------|
| **Meetings** | Mic + system audio via ScreenCaptureKit; Whisper transcription; AI summary |
| **Notes** | First-class writing UI, markdown toolbar (bold/lists/etc.), Edit/Preview |
| **Article / URL** | Import web pages or **YouTube** (captions via `yt-dlp`) → Note + optional Enhance |
| **Folders** | File items; **delete folder** with *Move to Unfiled* or *soft-delete contents* |
| **Auto-organize** | One button: name untitled items + file unfiled ones; shows a summary popup |
| **Library** | All / Unfiled / Meetings / Notes filters |
| **Search** | Sidebar search across the whole library; jumps to the item + best tab; shows match snippets |
| **Export** | Markdown for one note/meeting (toolbar **Export**); folder export as many `.md` files + `_index.md` |
| **Folder summary** | Right-click a folder → **Summarize folder…** — choose action items / brief / custom specs; saves a new Note in that folder |
| **Chat** | Per-item chat uses that item’s **AI summary + notes + transcript** (always re-fetched). Ask everything for whole library |
| **AI** | Ollama (local/remote) or OpenAI-compatible; templates; title in enhance |
| **Chat** | Per-item / folder RAG **and Ask everything** across all notes |
| **MCP** | `list_folders`, `create_note` for Claude Desktop |
| **Setup** | `./setup.sh` + `./build_app.sh` → `~/Applications/Grist.app` |
| **Icon** | Bundled macOS app icon |

---

## Requirements

- **macOS 15+**
- [Homebrew](https://brew.sh/)
- Xcode Command Line Tools (`xcode-select --install`)

Optional:

- [Claude Desktop](https://claude.ai/download) — MCP  
- Free **Apple ID** in Xcode — stable Mic/Screen permissions across rebuilds  
- **`yt-dlp`** — YouTube captions (`brew install yt-dlp`; also via `./setup.sh`)

---

## Quick start

```bash
git clone https://github.com/<your-account>/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh
```

Wizard steps:

1. **AI** — local Ollama, remote Ollama, or OpenAI-compatible API  
2. **Whisper** — build Metal whisper.cpp (CoreML off) or custom paths  
3. **yt-dlp** — installed for YouTube import  
4. **MCP** — optional Bun-compiled server + Claude Desktop config  
5. **Build** — `./build_app.sh` → `~/Applications/Grist.app`

Rebuild anytime:

```bash
./build_app.sh
```

---

## Using the app

### Create

Sidebar:

- **Meeting** — record + transcribe + summarize  
- **Note** — blank writing surface  
- **Article** — paste one or many URLs (article HTML or YouTube captions; each link → its own note)

All support **folder chips** (Unfiled / existing / new). Import defaults to **Unfiled** so nothing is silently filed under the focused sidebar folder.

### Auto-organize

Purple **Auto-organize** under the create buttons:

- Targets items that are **untitled** (placeholder names) and/or **unfiled**, with content  
- AI suggests **title** and/or **folder** (prefers existing folders)  
- Shows a **popup report** of what changed  

### Folders

- Click a folder to focus it  
- **+** in the Folders header to create  
- Right-click → **Delete Folder…**  
  - **Move to Unfiled** — keep items, remove folder  
  - **Delete all contents** — soft-delete items (`is_deleted = 1`), then remove folder  

### YouTube & articles

**Article** create or footer **Import URL**:

| URL type | Behavior |
|----------|----------|
| **YouTube** | `yt-dlp` pulls English captions → Note body + transcript → optional Enhance |
| **Other** | HTML scrape → page text → Note |
| **Linked YouTube** | After an article import, if the page links to YouTube (e.g. podcast posts), Grist asks: **Import captions & summarize?** |
| **Add to item** | On an open meeting/note: **Add URL** appends article/YouTube into the same item (notes + transcript), then Enhance. Meetings also have a **Notes** tab for free writing. |
| **Login walls** | X/Twitter, LinkedIn, etc. are detected — import **fails with a clear alert** (no junk note). Open in browser + paste into a Note. |

Requires captions on the video (manual or auto). If none: install/check `yt-dlp`, or record system audio while playing the video.

### Chat

- On a **meeting/note**: Chat uses **this item only** — AI summary, written notes, and transcript (re-loaded from the database on each message)  
- Sidebar **Ask everything**: chat over **all** notes and meetings (RAG when the library is large)

### Folder summary

Collect blogs, videos, meetings, and notes in a folder, then:

1. Right-click the folder → **Summarize folder…** (or Export menu when viewing an item in that folder)  
2. Choose what you need: **Action items**, **Executive brief**, **Themes**, **Research**, or **Custom**  
3. Edit the instructions if you want  
4. Grist creates a new **Note** in that folder with the combined summary

### Search

Sidebar search (top of the list) matches **title, notes, summary, transcript, folder** across the whole library (not only the current filter). Results show a short snippet; selecting a hit opens that item and switches to the tab where the match was found (Summary / Notes / Transcript). Press Return to open the top hit.

### Export

- Open an item → toolbar **Export** → **Export Markdown…** (or **Copy as Markdown**)  
- Keyboard: **⌘⇧E** for export dialog  
- Right-click a sidebar row → Export Markdown…  
- Right-click a **folder** → Export folder as Markdown… (one `.md` per item + `_index.md`)

---

## First-run permissions

| Permission | Why |
|------------|-----|
| **Microphone** | Your voice |
| **Screen & System Audio Recording** | Call / browser audio |

After enabling Screen Recording for Grist, **quit and reopen** the app.

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

Then reopen `~/Applications/Grist.app` and re-enable Grist in System Settings if needed.

---

## AI configuration

Setup writes `com.grist.meetingassistant` defaults. In-app: **Settings → General**.

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

Recommended local models: `gemma2:2b` (chat/summary), `nomic-embed-text` (RAG).

---

## MCP (Claude Desktop)

```bash
cd grist-mcp-server
bun install
bun build ./index.js --compile --outfile grist-mcp-server
```

Config (setup can write this):

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

Tools: `list_folders`, `create_note`  
Data: `~/Library/Application Support/Grist/meetings.db`

---

## Project layout

```text
grist/
├── Sources/grist/          # SwiftUI app
├── Resources/AppIcon.icns  # App icon
├── grist-mcp-server/       # MCP source (binary from setup)
├── setup.sh
├── build_app.sh
├── Package.swift
└── README.md
```

| Component | Role |
|-----------|------|
| `AudioRecorder` | Mic + system audio |
| `WhisperTranscriber` | ffmpeg + whisper.cpp |
| `YouTubeImporter` | yt-dlp captions → text |
| `URLFetcher` | Web HTML or YouTube |
| `OllamaClient` | Ollama / OpenAI-compatible |
| `RAGEngine` | Chunk + embed + search |
| `Database` | SQLite |

---

## Development

```bash
./build_app.sh          # build, sign, install, launch
swift build -c debug
```

Signing prefers **Apple Development** (stable TCC). Override with `CODESIGN_IDENTITY=...`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Mic-only / `you you` transcript | Enable **Screen & System Audio Recording**, quit & relaunch |
| YouTube import fails | `brew install yt-dlp`; video needs captions |
| X / LinkedIn import fails | Expected — those pages need login; paste text into a Note |
| Wrong folder on import | Import defaults to Unfiled — pick a chip explicitly |
| Whisper process failed | Re-run setup Whisper step (`-DWHISPER_COREML=OFF`) |
| Weak RAG / chat | Embeddings missing — `ollama pull nomic-embed-text` (used to find relevant note chunks) |
| Search finds nothing | Query is case-insensitive over title/body/summary; clear filters are ignored while searching |
| Generic Dock icon | `killall Dock` after rebuild; open `~/Applications/Grist.app` only |
| MCP not loading | Restart Claude; check binary path in config |

---

## Privacy

- Default: **local** (audio, Whisper, Ollama)  
- OpenAI-compatible mode sends text to the endpoint you configure  
- No Grist telemetry  

---

## License

MIT — see [LICENSE](LICENSE).

## Contributing

PRs welcome. Keep **clone → `./setup.sh` → `./build_app.sh`** working for new users.
