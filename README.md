# Grist

**Privacy-first AI notes & meeting assistant for macOS.**

Record meetings (mic + system audio), write notes, import articles or YouTube captions, and summarize with local AI. Chat across your library (RAG), extract tasks, export Markdown, and optionally push notes into Obsidian. Optional OpenAI-compatible APIs and MCP for Claude Desktop.

---

## Features

| Area | Details |
|------|---------|
| **Meetings** | Mic + system audio (ScreenCaptureKit), Whisper transcription, AI summary |
| **Notes** | Markdown write / preview, selection chat |
| **Articles & YouTube** | Multi-URL import; `yt-dlp` captions; append to open item; auth-wall detection |
| **Folders** | Accordion sidebar; expand to list files; **drag or right-click → Move to folder**; **right-click folder → Rename…**; unfiled under Today / Yesterday / Last 7 Days / Older |
| **Library** | All / Unfiled / Meetings / Notes / Tasks / Ask everything |
| **Search** | Whole-library search; jump to best tab + snippets |
| **Export** | Markdown with section picker (summary / notes / transcript / sources); folder multi-file export |
| **Enhance** | Summarize from **original** transcript/notes (not the old AI summary); long sources de-duped + truncated; **map-reduce** for very long transcripts; compact summary layout |
| **Chat** | Per-item chat + **Ask everything** (RAG + keywords); answers grounded in library content with **Sources** chips |
| **Chat history** | Multi-thread (New chat / search / pin / rename / delete); stored in SQLite |
| **Tasks** | Auto-extract after Enhance (optional); **Tasks** button; manual create; Open / Done / All filter; optional link to open note |
| **AI roles** | Settings → per-job backend + model (`chat`, `askEverything`, `enhance`, `embed`, …); toolbar dropdown **syncs** with config |
| **Setup checklist** | Detects Ollama, chat model, embeddings, yt-dlp, Whisper; banner + fix sheet |
| **Obsidian** | Settings → Integrations; **Send to Obsidian** / folder batch; optional after Enhance |
| **Read aloud** | **AI Summary → Read summary** uses **macOS system voice** only (on-device; voice / rate / pitch in Settings → Integrations) |
| **Settings** | Fixed **720×560** sheet: **General**, **AI Models**, **AI Templates**, **Integrations** — header fixed, content scrolls |
| **DMG** | `./build_app.sh` packages `Grist.dmg` (app only — still need Ollama/models via setup) |
| **MCP** | `list_folders`, `create_note` for Claude Desktop |
| **Local-first** | Ollama by default; optional OpenAI-compatible endpoint |

---

## Quick start

```bash
git clone https://github.com/askinjohn/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh          # AI, Whisper, yt-dlp, optional MCP
./build_app.sh      # → Grist.app, Grist.dmg, ~/Applications/Grist.app
```

**Needs:** macOS 15+, Homebrew, Xcode CLT.  
**Optional:** Claude Desktop (MCP), Apple ID for stable mic/screen permissions, `yt-dlp` for YouTube.

| Output | Path |
|--------|------|
| App bundle | `./Grist.app` |
| **Disk image** | `./Grist.dmg` — open, drag **Grist** → **Applications** |
| Dev install | `~/Applications/Grist.app` (launched after build) |

**Day to day:** open **`~/Applications/Grist.app`** (or Spotlight / Dock). You do **not** leave `build_app.sh` running — the script only builds/installs.

Rebuild after pulling code: `./build_app.sh`  

Flags: `SKIP_DMG=1`, `SKIP_INSTALL=1`, `SKIP_LAUNCH=1`.

**Note:** The DMG installs the **app only**. Full AI needs Ollama + models (and Whisper / yt-dlp for capture & YouTube). Use `./setup.sh` or the in-app **Setup checklist**.

---

## Using the app

### Create
Sidebar: **Meeting** (record), **Note** (write), **Article** (one or many URLs). Folder chips: Unfiled / existing / new.

### Folders
- Collapse/expand folders; items **with** a folder live only inside that folder.  
- **Unfiled** items appear under date groups.  
- **Move:** drag onto a folder, or **right-click → Move to folder**.  
- Right-click folder: **Rename…**, summarize, export, delete (unfile or soft-delete contents).

### Enhance
Toolbar **Enhance** rewrites the AI summary from source content. Long YouTube/podcasts use chunked map-reduce when needed. Logs: `grist.log`.

### Chat & Ask everything
- Open item → **Chat** for that note/meeting only.  
- Sidebar **Ask everything** for the whole library (RAG).  
- History control: switch threads, **New chat**, pin/rename/delete.  
- Replies show **Sources** chips (real note titles). Prefer **New chat** after bad threads.

### Tasks
Library → **Tasks**. Extract from Enhance or the **Tasks** button; filter Open / Done / All; create manually (optional link to open item).

### Export & Obsidian
- **Export → Export Markdown…** — pick sections, Save or Copy.  
- **Export → Send to Obsidian** — write Markdown into your vault (setup below).  
- Sidebar: right‑click a note → **Send to Obsidian**, or right‑click a folder → **Send Folder to Obsidian…**.

### Read summary aloud
On **AI Summary** / **Summary**, use the purple **Listen** bar → **Read summary** / **Stop**. Speech is the **macOS system voice** (no cloud, no extra TTS app).

### Settings
Open **Settings** from the toolbar. The sheet is a fixed size so every tab fits the same chrome:

| Tab | What |
|-----|------|
| **General** | Auto-enhance, auto-extract tasks, rebuild RAG index, legacy provider URL |
| **AI Models** | Per-role backends/models + raw `ai-config.json` |
| **AI Templates** | Custom enhance prompts |
| **Integrations** | Obsidian vault + **Read aloud** (voice, rate, pitch, test) |

---

## First-run permissions

| Permission | Why |
|------------|-----|
| **Microphone** | Your voice |
| **Screen & System Audio Recording** | Call / browser audio |

Enable Screen Recording, then **fully quit and reopen** Grist.

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

---

## AI setup

**Settings → AI Models** (or edit JSON):

```text
~/Library/Application Support/Grist/ai-config.json
```

`setup.sh` pulls **gemma2:2b** + **nomic-embed-text**. Optional stronger models: **qwen2.5:7b** (chat / ask / enhance).

Minimal example:

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

The main UI model dropdown follows the active role (Chat / Ask everything / Enhance) and writes back to this file.

**Settings → General:** Rebuild search index (RAG). Requires `nomic-embed-text` (or similar).

---

## Obsidian

Send existing notes/meetings into your local Obsidian vault as Markdown. **No cloud** — Grist only writes files under the folder you choose.

### Setup (important)

1. **Settings → Integrations → Obsidian** — enable.  
2. **Choose…** the vault folder that **contains `.obsidian`**  
   (the folder named like your vault in Obsidian’s switcher — e.g. **`My notes`**, **not** a parent folder also called `Obsidian`).  
3. Optional **Vault name in Obsidian** — only if open-after-send fails; must match the name in Obsidian’s vault switcher (e.g. `My notes`).  
4. Optional: **Subfolder** (default `Grist`), filename pattern `{date}-{title}`, which sections to include, auto after Enhance, open after send.  
5. **Save**.

Config file:

```text
~/Library/Application Support/Grist/integrations.json
```

### Send an existing note

1. Open the note/meeting in Grist.  
2. Toolbar **Export** → **Send to Obsidian**  
   **or** sidebar right‑click → **Send to Obsidian**.  
3. File lands at: `{vault}/{subfolder}/{date}-{title}.md`  
   (never overwrites; adds `-2`, `-3`, … if needed).  
4. In Obsidian: open that vault → expand the subfolder (e.g. **Grist**) or use Quick switcher (⌘O).

### Send a whole folder

Sidebar right‑click the folder → **Send Folder to Obsidian…**.

### “Vault not found” when opening

The **file usually still wrote successfully**. The error is from Obsidian’s URL open:

- Wrong vault folder (parent of the real vault), or  
- Vault **display name** ≠ folder last component.

**Fix:** re-**Choose…** the folder that contains `.obsidian`, set optional vault name to the switcher name (e.g. `My notes`), or turn off **Open in Obsidian after send** and open the note from Obsidian’s file list.

With current builds, Grist prefers `obsidian://open?path=…` and falls back to Finder if the URI fails.

---

## Read summary aloud

Fully **on-device** via macOS `AVSpeechSynthesizer`. No Voicebox, no cloud TTS, no extra install.

1. (Optional, better quality) **macOS System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…** — download an **Enhanced** or **Premium** English voice.  
2. **Grist → Settings → Integrations → Read aloud** — pick voice, set **rate** / **pitch**, **Test voice**.  
3. Open a note/meeting with an AI summary → **Read summary** / **Stop**.

Markdown in summaries is stripped before speech (so TTS doesn’t say “asterisk”).

**Later (not shipped):** optional local neural TTS server (e.g. Kokoro / Qwen) — same disk tradeoff as Ollama, not required for clone/build.

---

## Project layout (UI)

Main UI is split for maintainability (not one mega-file):

| File | Role |
|------|------|
| `Sources/grist/MainView.swift` | State + root `body` |
| `MainView+Sidebar/Sheets/Config/Detail/Data/AI.swift` | Feature slices |
| `ChatView.swift`, `CreateItemSheet.swift`, `MeetingModels.swift` | Chat, create, models |
| `SpeechService.swift`, `SummarySpeechBar.swift` | Read aloud |
| `SettingsView.swift` | Settings sheet (fixed size + scroll) |

---

## Data & logs

| Path | What |
|------|------|
| `~/Library/Application Support/Grist/meetings.db` | Notes, meetings, chats, tasks, RAG chunks |
| `~/Library/Application Support/Grist/ai-config.json` | Per-role AI backends and models |
| `~/Library/Application Support/Grist/integrations.json` | Obsidian vault & options |
| `~/Library/Application Support/Grist/grist.log` | Diagnostics (Enhance, Ollama, chat, Obsidian) |

---

## MCP (optional)

```bash
cd grist-mcp-server && bun install
bun build ./index.js --compile --outfile grist-mcp-server
```

Point Claude Desktop at that binary. Tools: `list_folders`, `create_note`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Mic-only / bad transcript | Screen + System Audio Recording → quit & relaunch |
| YouTube fails | `brew install yt-dlp`; video needs captions |
| Weak / empty Ask everything | `ollama pull nomic-embed-text` → Settings → Rebuild search index |
| Answers are only titles | Use **New chat**; update to latest; prefer qwen for Ask everything |
| Enhance off-topic / long video | Check `grist.log` (map-reduce / truncate); try a stronger enhance model |
| Model dropdown ≠ Settings | Close Settings (reloads config); dropdown edits the active role |
| Can’t move unfiled items | Right-click → **Move to folder**, or drag onto a folder name |
| Lost a chat | Use **History** — **New chat** keeps old threads; pin/rename from history menu |
| Obsidian disabled / greyed out | Settings → Integrations → enable + **Choose…** vault (folder with `.obsidian`); Save |
| Obsidian “Vault not found” | File may already be in vault; pick folder that contains `.obsidian`; set vault name to switcher name (e.g. My notes); or disable open-after-send |
| Note not visible in Obsidian | Confirm path is *inside* the open vault (not a parent folder); expand **Grist** subfolder; ⌘O search title |
| No **Read summary** / **Read aloud** | Rebuild from latest; open **~/Applications/Grist.app**; Settings → **Integrations** |
| Read aloud silent / robotic | Install Enhanced system voices; pick them in Integrations → Read aloud; check Mac volume |
| Settings tabs clipped / sheet too tall | Use latest build (fixed 720×560 sheet + scroll) |
| DMG opens but no AI | Install/start Ollama + pull models; run setup or use Setup checklist |
| MCP not loading | Restart Claude; check binary path in config |

---

## Privacy

Local by default (audio, Whisper, Ollama, Obsidian file write). Cloud only if you set an OpenAI-compatible endpoint. No Grist telemetry.

---

## License

MIT — see [LICENSE](LICENSE).

PRs welcome. Keep **clone → `./setup.sh` → `./build_app.sh`** working.

**Planned (not built):** Notion push, notarized GitHub Releases — see `docs/plans/`.
