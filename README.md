# Grist

### Your meetings and notes. Your machine. Your AI.

**Grist** is a privacy-first macOS app for capturing meetings, writing notes, and turning them into summaries, tasks, and answers — with **local AI** by default.

No cloud transcription tax. No subscription to “unlock” your own library. Just a fast native app that stays on your Mac.

[Download / build](#install) · [Features](#features) · [Obsidian](#obsidian--phone) · [Privacy](#privacy)

---

## Why Grist

| | |
|--|--|
| **Local-first** | Audio, transcripts, and chat stay on your Mac. Ollama by default. |
| **Meetings that remember** | Mic + system audio, Whisper transcription, AI summaries you can trust. |
| **A real library** | Folders, search, tasks, and chat across everything you’ve captured. |
| **Works with your stack** | Export Markdown, send to Obsidian, optional MCP for Claude Desktop. |

Built for people who live in calls, articles, and follow-ups — and don’t want their notes shipped to a SaaS by default.

---

## Features

### Capture everything that matters

- **Meetings** — Record your mic and system audio (calls, browsers, Zoom/Meet). Whisper turns it into a transcript.
- **Notes** — Markdown write & preview. Paste freely; enhance when you’re ready.
- **Articles & YouTube** — Import pages or captions (`yt-dlp`). Append into the note you’re already in.
- **Menu bar** — Waveform when idle; **record** glyph while capturing. **Stop Recording** or **Show Grist** without digging for the window.

### Turn capture into clarity

- **Enhance** — Structured AI summaries from the *source* (notes + transcript), not a stale summary. Long videos get map-reduce so nothing important gets truncated away.
- **Read aloud** — Listen to summaries with macOS system voices (Enhanced voices supported). Fully on-device.
- **Tasks** — Pull action items after Enhance, or create them by hand. Filter Open / Done / All.
- **Chat** — Ask about *this* note, or **Ask everything** across your library with RAG + sources. Multi-thread history (new / search / pin / rename / delete).

### Stay organized

- **Folders** — Accordion sidebar, drag-and-drop, rename, summarize a whole folder, export a batch.
- **Library filters** — All · Unfiled · Meetings · Notes · Tasks · Ask everything.
- **Search** — Jump to the best tab with snippets.
- **Export** — Markdown with section picker (summary, notes, transcript, sources).

### Connect outward (still local)

- **Obsidian** — Send notes or whole folders as Markdown into your vault. Optional open-after-send.
- **MCP** — `list_folders` / `create_note` for Claude Desktop.
- **Your models** — Per-role backends (chat, enhance, embed, …). Ollama locally, or an OpenAI-compatible endpoint if you choose.

---

## See it in a day

1. **Record** a meeting (or import a YouTube with captions).  
2. Hit **Enhance** — get a structured summary + optional auto-title.  
3. **Chat** with the note, or **Ask everything** across your library.  
4. Extract **Tasks**, **Read aloud**, or **Send to Obsidian**.

Day to day: open **`~/Applications/Grist.app`** from Spotlight or the Dock. You don’t leave any install script running.

---

## Install

**Needs:** macOS 15+, Homebrew, Xcode Command Line Tools.

```bash
git clone https://github.com/askinjohn/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh          # Ollama models, Whisper, yt-dlp, optional MCP
./build_app.sh      # → Grist.app, Grist.dmg, installs ~/Applications/Grist.app
```

| Artifact | Path |
|----------|------|
| App | `./Grist.app` or **`~/Applications/Grist.app`** |
| Disk image | `./Grist.dmg` |

Flags: `SKIP_DMG=1` · `SKIP_INSTALL=1` · `SKIP_LAUNCH=1`

The DMG is the **app only**. Full AI needs Ollama + models (and Whisper / yt-dlp for capture & YouTube). Use `./setup.sh` or the in-app **Setup checklist**.

### Permissions

| Permission | Why |
|------------|-----|
| **Microphone** | Your voice |
| **Screen & System Audio Recording** | Call / browser audio |

Enable Screen Recording, then **fully quit and reopen** Grist.

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

---

## Obsidian & phone

Grist writes Markdown into a vault folder you choose — **no Grist cloud**.

1. **Settings → Integrations → Obsidian** — enable.  
2. **Choose…** the folder that contains **`.obsidian`** (e.g. **My notes**, not a parent “Obsidian” folder).  
3. Optional vault **display name** if open-after-send fails.  
4. Open a note → **Export → Send to Obsidian** (or sidebar right‑click).

Files land at `{vault}/Grist/{date}-{title}.md` by default.

**Phone (free):** Obsidian mobile is free. Sync the vault with something both devices share (e.g. personal Google Drive / Syncthing). Work Mac iCloud ≠ personal iPhone iCloud — use a shared free cloud or Git instead of Apple’s sync across accounts.

**“Vault not found”:** the file usually still wrote. Re-pick the vault root (folder with `.obsidian`) or set the vault name to match Obsidian’s switcher. Newer builds prefer `path=` open and fall back to Finder.

---

## AI setup

**Settings → AI Models** (or edit JSON):

```text
~/Library/Application Support/Grist/ai-config.json
```

`setup.sh` pulls **gemma2:2b** + **nomic-embed-text**. Stronger option: **qwen2.5:7b**.

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

The toolbar model dropdown stays in sync with the active role.

---

## Privacy

Local by default: audio, Whisper, Ollama, Obsidian file writes. Cloud only if **you** set an OpenAI-compatible endpoint. No Grist telemetry.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Mic-only / weak transcript | Screen + System Audio Recording → quit & relaunch |
| YouTube fails | `brew install yt-dlp`; video needs captions |
| Weak Ask everything | `ollama pull nomic-embed-text` → Settings → Rebuild search index |
| Enhance button blank (dark mode) | Update to latest build |
| Menu bar doesn’t show Stop | Update to latest; icon changes only while **recording** |
| Obsidian greyed out | Integrations → enable + Choose vault; Save |
| Obsidian “Vault not found” | Pick folder with `.obsidian`; set vault name; file may already be in `Grist/` |
| DMG opens but no AI | Start Ollama + pull models; run setup / Setup checklist |
| MCP spawn failed | Point Claude at `grist/grist-mcp-server/grist-mcp-server` (under the repo) |

---

## Data & logs

| Path | What |
|------|------|
| `~/Library/Application Support/Grist/meetings.db` | Notes, meetings, chats, tasks, RAG |
| `~/Library/Application Support/Grist/ai-config.json` | Per-role AI backends |
| `~/Library/Application Support/Grist/integrations.json` | Obsidian & options |
| `~/Library/Application Support/Grist/grist.log` | Diagnostics |

---

## MCP (optional)

```bash
cd grist-mcp-server && bun install
bun build ./index.js --compile --outfile grist-mcp-server
```

Point Claude Desktop at that binary. Tools: `list_folders`, `create_note`.

---

## License

MIT — see [LICENSE](LICENSE).

PRs welcome. Keep **clone → `./setup.sh` → `./build_app.sh`** working. `main` is protected — ship via pull requests.

**Planned (not built):** Notion push, notarized GitHub Releases — see `docs/plans/`.
