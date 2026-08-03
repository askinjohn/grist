# Grist

**Privacy-first AI notes & meeting assistant for macOS.**

Record meetings (mic + system audio), write notes, import articles or YouTube captions, and summarize with local AI. Optional OpenAI-compatible APIs and MCP for Claude Desktop.

---

## Features

- **Meetings** — ScreenCaptureKit capture, Whisper transcription, AI summary  
- **Notes** — Markdown write / preview  
- **Articles & YouTube** — URL import (`yt-dlp` captions); multi-URL; append to open item  
- **Folders** — Accordion sidebar; unfiled items under Today / Yesterday / …  
- **Search & export** — Library search; Markdown export with section picker  
- **Chat** — Per-item + **Ask everything** (RAG); multi-thread history (New chat / search / delete)  
- **Tasks** — Extract action items after Enhance  
- **AI roles** — Settings → per-job model (`chat`, `askEverything`, `enhance`, `embed`); toolbar stays in sync  
- **Local-first** — Ollama by default; optional cloud-compatible endpoint  

---

## Quick start

```bash
git clone https://github.com/askinjohn/grist.git
cd grist
chmod +x setup.sh build_app.sh
./setup.sh          # AI, Whisper, yt-dlp, optional MCP
./build_app.sh      # → Grist.app, Grist.dmg, ~/Applications/Grist.app
```

**Needs:** macOS 15+, Homebrew, Xcode CLT. Optional: Claude Desktop (MCP), Apple ID for stable mic/screen permissions, `yt-dlp` for YouTube.

| Output | Path |
|--------|------|
| App bundle | `./Grist.app` |
| **Disk image** | `./Grist.dmg` — open, drag **Grist** → **Applications** |
| Dev install | `~/Applications/Grist.app` (launched after build) |

Rebuild: `./build_app.sh`  

Skip pieces if needed: `SKIP_DMG=1`, `SKIP_INSTALL=1`, `SKIP_LAUNCH=1`.

---

## First-run permissions

| Permission | Why |
|------------|-----|
| **Microphone** | Your voice |
| **Screen & System Audio Recording** | Call / browser audio |

Enable Screen Recording, then **fully quit and reopen** Grist. If capture stays stuck:

```bash
tccutil reset ScreenCapture com.grist.meetingassistant
```

---

## AI setup

**Settings → AI Models** (or edit JSON):

```text
~/Library/Application Support/Grist/ai-config.json
```

`setup.sh` pulls **gemma2:2b** + **nomic-embed-text**. Optional stronger chat/enhance: **qwen2.5:7b**.

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

---

## Obsidian

1. **Settings → Integrations → Obsidian** — enable and **Choose…** your vault folder.  
2. Optional: subfolder (default `Grist`), filename `{date}-{title}`, sections to include.  
3. On a note/meeting: **Export → Send to Obsidian** (or auto after Enhance).  
4. Grist writes a new `.md` file (never overwrites; adds `-2` if needed).  

Config: `~/Library/Application Support/Grist/integrations.json`

## Data

| Path | What |
|------|------|
| `~/Library/Application Support/Grist/meetings.db` | Notes, chats, tasks, RAG |
| `~/Library/Application Support/Grist/ai-config.json` | Model roles |
| `~/Library/Application Support/Grist/integrations.json` | Obsidian vault path & options |
| `~/Library/Application Support/Grist/grist.log` | Diagnostics |

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
| Weak Ask everything | `ollama pull nomic-embed-text` → Settings → Rebuild search index |
| Enhance off-topic | Check `grist.log`; try qwen; long videos are truncated for local models |
| Lost a chat | Use **History** — **New chat** keeps old threads |

---

## Privacy

Local by default (audio, Whisper, Ollama). Cloud only if you set an OpenAI-compatible endpoint. No Grist telemetry.

---

## License

MIT — see [LICENSE](LICENSE).

PRs welcome. Keep **clone → `./setup.sh` → `./build_app.sh`** working.

Planned later: Obsidian / Notion — see `docs/plans/`.
