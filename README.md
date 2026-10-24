# Quern

> Formerly **Grist**. Existing libraries under `~/Library/Application Support/Grist` migrate automatically to `…/Quern` on first launch.

**Privacy-first AI notes and meeting assistant for macOS.**

Record meetings, write notes, import articles or YouTube captions, and turn them into summaries, tasks, and answers — with **local AI** by default. Your audio and library stay on your machine unless you opt into a cloud model endpoint.

---

## What you get

### Capture
- **Meetings** — Microphone + system audio (calls, browsers, video apps), transcribed with Whisper  
- **Meeting detection** — Uses meeting window titles and microphone activity to notice Zoom / Teams / Google Meet / Webex and ask whether to record. Unconfirmed browser activity always asks first.
- **Notes** — Markdown editor with write / preview  
- **Attach files** — Drop in `.md`, `.txt`, or `.pdf`; text is appended into the note so Enhance / Chat can read it  
- **Articles & YouTube** — Paste one or many URLs; fetch page text or captions and attach them to a note  

Quern stays in the **menu bar** so you can record, stop, or act on a detected meeting without hunting for the window.

### Understand
- **Enhance** — Structured AI summary from the original transcript and notes (handles long sources)  
- **Live transcription** — While recording, a rolling transcript appears in the Transcript tab (local Whisper); a final pass still runs when you stop  
- **Chat** — Ask about the open item, or **Ask everything** across your library with sources  
- **Tasks** — Extract action items after Enhance, or create them manually  
- **Today** — A daily dashboard for open tasks, today’s meetings, and today’s notes
- **Read aloud** — Listen to summaries with macOS system voices (on-device)  

### Organize
- **Folders** — Group notes and meetings; drag to move; rename; summarize or export a whole folder  
- **Library** — Filter by All, Unfiled, Meetings, Notes, Tasks, or Ask everything  
- **Search** — Find across titles and content and jump to the right tab  

### Connect
- **Export Markdown** — Pick sections (summary, notes, transcript, sources)  
- **Obsidian** — Write notes into a local vault folder you choose  
- **Notion** — Append notes and meetings directly to a Notion page shared with your integration
- **Your models** — Ollama locally, or an OpenAI-compatible API per job (chat, enhance, embed, …)  
- **MCP** — Optional tools for Claude Desktop (`list_folders`, `create_note`)  

Quern also sits in the **macOS menu bar** so you can return to the app quickly while recording or after a meeting.

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
git clone https://github.com/askinjohn/quern.git
cd quern
chmod +x setup.sh build_app.sh
./setup.sh          # local AI, Whisper, yt-dlp, optional MCP
./build_app.sh      # builds Quern.app + Quern.dmg, installs to ~/Applications
```

The macOS Today widget is included in the app. The build needs Xcode and
`xcodegen` (`brew install xcodegen`). After opening Quern, use macOS **Edit Widgets**
and search for **Quern Today**. The widget shows open tasks, upcoming Calendar
meetings when Calendar is connected, and recent notes. Click a row to open it
in Quern. Calendar access can be enabled in Quern’s Today page or Settings.

Then open **Quern** from `~/Applications/Quern.app`, Spotlight, or the Dock.

| Output | Where |
|--------|--------|
| App | `./Quern.app` and `~/Applications/Quern.app` |
| Disk image | `./Quern.dmg` |

Rebuild after pulling updates: `./build_app.sh`  
Useful flags: `SKIP_DMG=1` · `SKIP_INSTALL=1` · `SKIP_LAUNCH=1`

Run `swift test` for regression checks. `python3 Scripts/eval_ask.py qwen2.5:7b`
runs a small synthetic Ask check against a locally running Ollama model.

The packaged app does **not** include Ollama models. Run `./setup.sh` (or use the in-app setup checklist) for a full AI setup.

### First launch permissions

| Permission | Purpose |
|------------|---------|
| Microphone | Your voice when recording |
| Screen & System Audio Recording | Capture call / browser audio |

After enabling Screen Recording, fully quit and reopen Quern.

```bash
tccutil reset ScreenCapture com.quern.meetingassistant
```

---

## Using Quern

1. Create a **Meeting**, **Note**, or **Article** from the sidebar.  
2. For meetings, record (optionally start recording as soon as the meeting is created).  
3. Run **Enhance** for a structured summary (and optional auto-title / tasks).  
4. Use **Chat** on that item, or **Ask everything** across the library.  
5. Export Markdown or send to Obsidian when you want notes in another tool.

**Settings** covers workflow toggles, per-role AI models, enhance templates, Obsidian, and read-aloud voice preferences.

The **Today** library view is the daily home for tasks and material created today. During recording, Quern switches to a focused capture view with live transcript, elapsed time, and independent microphone/system-audio status.

For Google Meet in Chrome, keep Quern running and enable **Settings → General → Meeting detection → Google Meet (browser)**. Use **Test meeting prompt** to check delivery without starting a recording. When system alerts are disabled, Quern shows a floating prompt. macOS Focus can still silence enabled notification banners.

While recording, Quern can ask whether to stop after supported meeting-app microphone activity has been absent for 3 minutes. Choose **Stop Recording** to save and transcribe, or **Keep Recording** to snooze that question for 15 minutes. Ignoring the prompt leaves recording active.

Window titles help identify Google Meet; Screen Recording permission may be needed to read them. If Chrome is using the microphone but the meeting title is unavailable, Quern asks whether this is a meeting. Browser dictation or other audio sites can also trigger this fallback, and a muted call with no visible meeting title may not be detected.

Use the item's **Audio → Retry transcription from saved audio** after a transcription failure. **Show saved recordings** opens its audio folder; previous sessions are preserved in the `recordings` subfolder before new capture begins.

---

## Obsidian

Quern can write Markdown files into an Obsidian vault on disk (no Quern cloud account).

1. **Settings → Integrations → Obsidian** — enable.  
2. Choose your **vault folder** (the directory Obsidian uses for that vault).  
3. Optionally set a subfolder (default `Quern`) and which sections to include.  
4. Open a note → **Export → Send to Obsidian**, or use the sidebar context menu.  

Batch-send a folder from the folder’s context menu when you want many notes at once.

Config is stored at:

```text
~/Library/Application Support/Quern/integrations.json
```

## Notion

Quern can append a note or meeting to a Notion page. In **Settings → Integrations → Notion**, create or copy an internal-integration token, enter it, and paste the destination page ID from its Notion URL. Share that destination page with the integration in Notion. The token stays in macOS Keychain; `integrations.json` stores only the destination and export preferences.

Use **Export → Send to Notion** on an open item, or enable **Export after Enhance**. Quern writes headings, paragraphs, and bullets beneath the destination page. It does not create a Notion database schema or import content back from Notion.

Automatic exports read the saved token without opening a Keychain password or permission dialog. If access is unavailable, the export stops with an error instead of prompting. Open **Settings → Integrations → Notion → Repair saved access** to authorize this signed Quern installation to use the existing token. macOS may ask for approval once during repair; subsequent exports use the saved access. The token remains in Keychain, with access restricted to Quern.

---

## AI configuration

Edit models in **Settings → AI Models**, or in:

```text
~/Library/Application Support/Quern/ai-config.json
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

Builds derive the widget App Group from the local signing identity; developer team identifiers are not hardcoded in source. Generated signing files stay under the ignored `.build/` directory.

- Default path is **local**: recordings, transcripts, SQLite library, and Ollama inference on your Mac.  
- Obsidian export is a **local file write** into a folder you pick.  
- Cloud AI is used only if you configure an OpenAI-compatible backend.  
- Quern does not send telemetry.

---

## Data locations

| Path | Contents |
|------|----------|
| `~/Library/Application Support/Quern/meetings.db` | Notes, meetings, chats, tasks, search index |
| `~/Library/Application Support/Quern/ai-config.json` | AI backends and role → model mapping |
| `~/Library/Application Support/Quern/integrations.json` | Obsidian and related options |
| `~/Library/Application Support/Quern/quern.log` | Diagnostics |

---

## Optional: MCP for Claude Desktop

```bash
cd quern-mcp-server && bun install
bun build ./index.js --compile --outfile quern-mcp-server
```

Point Claude Desktop’s MCP config at the compiled binary under `quern/quern-mcp-server/quern-mcp-server`.

| Tool | Purpose |
|------|---------|
| `list_folders` | List folder names |
| `list_notes` | Search/list notes & meetings (ids for updates) |
| `get_note` | Fetch one note by id or title |
| `create_note` | Create a note (body → written notes) |
| `update_note` | Update title, notes, summary, and/or folder (`append` optional) |
| `list_tasks` | List tasks (`open` / `done` / `all`, optional meeting link) |
| `get_task` | Fetch one task by id or title |
| `create_task` | Create an open task (optional link to a meeting/note) |
| `complete_task` | Mark a task done |
| `reopen_task` | Mark a task open again |
| `update_task` | Change title, notes, or source link |
| `delete_task` | Soft-delete a task |

---

## Troubleshooting

| Issue | What to try |
|-------|-------------|
| Transcript is mic-only | Check the capture warning and `quern.log`. Quit Quern, toggle its Screen & System Audio Recording permission off and on, reopen, then test with speech playing. Confirm “Recording mic + system audio”. |
| Notion export reports saved access needs attention | Open Settings → Integrations → Notion → Repair saved access. macOS may ask once during repair; automatic exports do not open password prompts. |
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

Ideas under consideration (not shipped): notarized GitHub Releases — see `docs/plans/`.
