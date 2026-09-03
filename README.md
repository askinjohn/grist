# Grist

**Privacy-first AI notes and meeting assistant for macOS.**

Record meetings, write notes, import articles or YouTube captions, and turn them into summaries, tasks, and answers — with **local AI** by default. Your audio and library stay on your machine unless you opt into a cloud model endpoint.

---

## What you get

### Capture
- **Meetings** — Microphone + system audio (calls, browsers, video apps), transcribed with Whisper  
- **Notes** — Markdown editor with write / preview  
- **Articles & YouTube** — Paste one or many URLs; fetch page text or captions and attach them to a note  

### Understand
- **Enhance** — Structured AI summary from the original transcript and notes (handles long sources)  
- **Live transcription** — While recording, a rolling transcript appears in the Transcript tab (local Whisper); a final pass still runs when you stop  
- **Chat** — Ask about the open item, or **Ask everything** across your library with sources  
- **Tasks** — Extract action items after Enhance, or create them manually  
- **Read aloud** — Listen to summaries with macOS system voices (on-device)  

### Organize
- **Folders** — Group notes and meetings; drag to move; rename; summarize or export a whole folder  
- **Library** — Filter by All, Unfiled, Meetings, Notes, Tasks, or Ask everything  
- **Search** — Find across titles and content and jump to the right tab  

### Connect
- **Export Markdown** — Pick sections (summary, notes, transcript, sources)  
- **Obsidian** — Write notes into a local vault folder you choose  
- **Your models** — Ollama locally, or an OpenAI-compatible API per job (chat, enhance, embed, …)  
- **MCP** — Optional tools for Claude Desktop (`list_folders`, `create_note`)  

Grist also sits in the **macOS menu bar** so you can return to the app quickly while recording or after a meeting.

---

## Who it’s for

Anyone who wants meeting notes and research in one place **without** sending everything to a hosted AI notes product by default — developers, founders, researchers, and anyone running local models with Ollama.

---

## Requirements

| | |
|--|--|
| **OS** | macOS 15+ |
| **Build** | Homebrew, Xcode Command Line Tools |
| **AI (local)** | [Ollama](https://ollama.com) + models (setup script can install) |
| **Optional** | `yt-dlp` (YouTube), Whisper (transcription), Claude Desktop (MCP) |

---

## Get started

```bash
git clone https://github.com/askinjohn/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh          # local AI, Whisper, yt-dlp, optional MCP
./build_app.sh      # builds Grist.app + Grist.dmg, installs to ~/Applications
```

Then open **Grist** from `~/Applications/Grist.app`, Spotlight, or the Dock.

| Output | Where |
|--------|--------|
| App | `./Grist.app` and `~/Applications/Grist.app` |
| Disk image | `./Grist.dmg` |

Rebuild after pulling updates: `./build_app.sh`  
Useful flags: `SKIP_DMG=1` · `SKIP_INSTALL=1` · `SKIP_LAUNCH=1`

The packaged app does **not** include Ollama models. Run `./setup.sh` (or use the in-app setup checklist) for a full AI setup.

### First launch permissions

| Permission | Purpose |
|------------|---------|
| Microphone | Your voice when recording |
| Screen & System Audio Recording | Capture call / browser audio |

After enabling Screen Recording, fully quit and reopen Grist.

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

---

## Using Grist

1. Create a **Meeting**, **Note**, or **Article** from the sidebar.  
2. For meetings, record (optionally start recording as soon as the meeting is created).  
3. Run **Enhance** for a structured summary (and optional auto-title / tasks).  
4. Use **Chat** on that item, or **Ask everything** across the library.  
5. Export Markdown or send to Obsidian when you want notes in another tool.

**Settings** covers workflow toggles, per-role AI models, enhance templates, Obsidian, and read-aloud voice preferences.

---

## Obsidian

Grist can write Markdown files into an Obsidian vault on disk (no Grist cloud account).

1. **Settings → Integrations → Obsidian** — enable.  
2. Choose your **vault folder** (the directory Obsidian uses for that vault).  
3. Optionally set a subfolder (default `Grist`) and which sections to include.  
4. Open a note → **Export → Send to Obsidian**, or use the sidebar context menu.  

Batch-send a folder from the folder’s context menu when you want many notes at once.

Config is stored at:

```text
~/Library/Application Support/Grist/integrations.json
```

---

## AI configuration

Edit models in **Settings → AI Models**, or in:

```text
~/Library/Application Support/Grist/ai-config.json
```

Example (local Ollama):

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

`setup.sh` typically installs a small chat model plus an embedding model for library search. Use a larger model (e.g. `qwen2.5:7b`) when you want stronger summaries and answers.

---

## Privacy

- Default path is **local**: recordings, transcripts, SQLite library, and Ollama inference on your Mac.  
- Obsidian export is a **local file write** into a folder you pick.  
- Cloud AI is used only if you configure an OpenAI-compatible backend.  
- Grist does not send telemetry.

---

## Data locations

| Path | Contents |
|------|----------|
| `~/Library/Application Support/Grist/meetings.db` | Notes, meetings, chats, tasks, search index |
| `~/Library/Application Support/Grist/ai-config.json` | AI backends and role → model mapping |
| `~/Library/Application Support/Grist/integrations.json` | Obsidian and related options |
| `~/Library/Application Support/Grist/grist.log` | Diagnostics |

---

## Optional: MCP for Claude Desktop

```bash
cd grist-mcp-server && bun install
bun build ./index.js --compile --outfile grist-mcp-server
```

Point Claude Desktop’s MCP config at the compiled binary under `grist/grist-mcp-server/grist-mcp-server`.

---

## Troubleshooting

| Issue | What to try |
|-------|-------------|
| Transcript is mic-only | Grant Screen & System Audio Recording, then quit and relaunch |
| YouTube import fails | Install `yt-dlp`; ensure the video has captions |
| Ask everything is weak | Pull an embedding model and rebuild the search index in Settings |
| No AI responses | Confirm Ollama is running and models are pulled; use the setup checklist |
| Obsidian send disabled | Enable the integration and choose a vault folder, then Save |
| MCP won’t start | Confirm the binary path in Claude’s config matches the built file |

---

## Contributing

MIT licensed — see [LICENSE](LICENSE).

`main` accepts changes via pull request. Please keep the happy path working:

```text
clone → ./setup.sh → ./build_app.sh
```

Ideas under consideration (not shipped): Notion export, notarized GitHub Releases — see `docs/plans/`.
