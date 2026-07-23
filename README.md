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
| **Folders** | **Accordion** sidebar: expand a folder to list files inside; only **unfiled** items sit outside (Today / Yesterday / …) |
| **Auto-organize** | One button: name untitled items + file unfiled ones; shows a summary popup |
| **Library** | All / Unfiled / Meetings / Notes / Tasks / Ask everything |
| **Search** | Sidebar search across the whole library; jumps to the item + best tab; shows match snippets |
| **Export** | Markdown for one note/meeting (toolbar **Export**); choose sections; folder export as many `.md` files + `_index.md` |
| **Folder summary** | Right-click a folder → **Summarize folder…** — action items / brief / custom; saves a Note in that folder |
| **Chat history** | **Multiple threads** per place (like ChatGPT): New chat, searchable history dropdown, Delete thread. Ask everything and each note keep separate histories |
| **Chat** | Per-item chat uses that item’s AI summary, notes, and transcript. **Ask everything** for the whole library (RAG) |
| **RAG / search index** | Embeds title, AI summary, notes, and transcript. Rebuild in Settings. Needs `ollama pull nomic-embed-text` |
| **Chat with selection** | Highlight text in Write → **Chat with selection** — answers use only that span |
| **AI roles config** | Settings → **AI Models**: per-job backend + model; JSON editor; toolbar model dropdown **stays in sync** with config |
| **Enhance** | Re-runs from **original** transcript/notes (never feeds the old summary); long sources are de-duped + truncated; file logs for debugging |
| **Tasks** | Action items extracted after Enhance (or **Tasks** button); Library → **Tasks**; manual create |
| **AI** | Ollama (local/remote) or OpenAI-compatible; templates; title in enhance |
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

### Folders (accordion)

- Folders are **collapsed by default**  
- Click the **chevron** or folder row to **expand** and see files inside  
- Items **with a folder** only appear under that folder — not in the main timeline  
- Items **without a folder** appear under **Today / Yesterday / Last 7 Days / Older**  
- **+** in the Folders header to create  
- Drag a note onto a folder to file it  
- Right-click a folder → **Delete Folder…**, Summarize, Export, “Show only this folder”  
  - **Move to Unfiled** — keep items, remove folder  
  - **Delete all contents** — soft-delete items, then remove folder  

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

### Chat & history

- On a **meeting/note**: Chat uses **this item only** — AI summary, written notes, and transcript  
- Sidebar **Ask everything**: chat over **all** notes and meetings (RAG when the library is large)  
- **Multiple threads** (per item and for Ask everything), similar to ChatGPT:  
  - **History** control — searchable list of past chats (title + message text)  
  - **New chat** — starts a fresh thread **without deleting** older ones  
  - **Delete** — removes only the open thread  
  - First message becomes the thread title automatically  
- History is stored in SQLite (`chat_conversations` + `chat_messages`)

### Enhance

- **Enhance** always summarizes from **original** transcript / notes — not from a previous AI summary  
- Re-Enhance after changing the model (toolbar dropdown syncs with Settings → AI Models)  
- Long YouTube / meeting sources: captions are **de-duplicated** (notes vs transcript) and **truncated** (head + middle + end) so local models stay in context  
- Debug log: `~/Library/Application Support/Grist/grist.log`

### Folder summary

Collect blogs, videos, meetings, and notes in a folder, then:

1. Right-click the folder → **Summarize folder…**  
2. Choose what you need: **Action items**, **Executive brief**, **Themes**, **Research**, or **Custom**  
3. Edit the instructions if you want  
4. Grist creates a new **Note** in that folder with the combined summary

### Search

Sidebar search (top of the list) matches **title, notes, summary, transcript, folder** across the whole library (not only the current filter). Results show a short snippet; selecting a hit opens that item and switches to the tab where the match was found (Summary / Notes / Transcript). Press Return to open the top hit.

### Export

- Open an item → toolbar **Export** → **Export Markdown…**  
- **Choose sections**: metadata, AI summary, notes, transcript, source links (or presets **Summary only** / **Full item**)  
- Then **Save…** or **Copy**  
- Keyboard: **⌘⇧E**  
- Folder export uses the same section choices for every file (+ `_index.md`)

### Tasks

- After Enhance (if enabled), action items can be extracted into **Tasks**  
- Library → **Tasks** for the list; create manually or extract from the open note  

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

**Preferred:** **Settings → AI Models**

- Assign a **backend** + **model name** per job (Chat, Ask everything, Enhance, Embeddings, …)  
- Edit the same config as **JSON** in that pane (Save / Reload / Reset / Reveal in Finder)  
- The **model dropdown** in the main UI follows the active role (Chat / Ask everything / Enhance) and **writes back** to config when you change it  
- File path:

```text
~/Library/Application Support/Grist/ai-config.json
```

**Minimal local setup** (one chat model for everything):

```json
{
  "version": 1,
  "backends": {
    "local": { "type": "ollama", "baseURL": "http://127.0.0.1:11434" }
  },
  "roles": {
    "chat": { "backend": "local", "model": "gemma2:2b" },
    "askEverything": { "backend": "local", "model": "gemma2:2b" },
    "enhance": { "backend": "local", "model": "gemma2:2b" },
    "embed": { "backend": "local", "model": "nomic-embed-text" }
  }
}
```

`./setup.sh` always pulls `gemma2:2b` + `nomic-embed-text`. **qwen2.5:7b is optional** (better Chat / Ask everything / Enhance if you want it).

Optional stronger models (example):

```json
"chat": { "backend": "local", "model": "qwen2.5:7b" },
"askEverything": { "backend": "local", "model": "qwen2.5:7b" },
"enhance": { "backend": "local", "model": "qwen2.5:7b" }
```

Legacy UserDefaults are migrated once when the JSON file is first created.

---

## Data & logs

| Path | What |
|------|------|
| `~/Library/Application Support/Grist/meetings.db` | Notes, meetings, tasks, chat threads, RAG chunks |
| `~/Library/Application Support/Grist/ai-config.json` | Per-role AI backends and models |
| `~/Library/Application Support/Grist/grist.log` | App diagnostics (Enhance, Ollama, chat) |

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
├── docs/plans/             # Future work (e.g. Obsidian / Notion)
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
| `Database` | SQLite (items, tasks, chat threads) |
| `GristLog` | File logger under Application Support |

---

## Development

```bash
./build_app.sh          # build, sign, install, launch
swift build -c debug
```

Signing prefers **Apple Development** (stable TCC). Override with `CODESIGN_IDENTITY=...`.

**Planned (not built yet):** optional Obsidian vault export and Notion push — see `docs/plans/integrations-obsidian-notion.md`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Mic-only / `you you` transcript | Enable **Screen & System Audio Recording**, quit & relaunch |
| YouTube import fails | `brew install yt-dlp`; video needs captions |
| X / LinkedIn import fails | Expected — those pages need login; paste text into a Note |
| Wrong folder on import | Import defaults to Unfiled — pick a chip explicitly |
| Whisper process failed | Re-run setup Whisper step (`-DWHISPER_COREML=OFF`) |
| Weak RAG / chat | `ollama pull nomic-embed-text`, then **Settings → Rebuild search index** |
| Ask everything empty | Index shows 0 chunks — rebuild; check Ollama is running |
| Enhance invents wrong topic | Long source? Check `grist.log` — should de-dupe + truncate. Re-Enhance with a stronger model (e.g. qwen) |
| Model dropdown ≠ Settings | Close Settings (reloads config); dropdown writes to the active role (Chat / Ask everything / Enhance) |
| Lost old chat | Use **History** (not Delete). **New chat** keeps past threads |
| Search finds nothing | Query is case-insensitive over title/body/summary; filters are ignored while searching |
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
