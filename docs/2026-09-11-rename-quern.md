# 2026-09-11 — Rename Grist → Quern

## What

Product rename from **Grist** to **Quern** (hand mill — grind the call, keep the grain).

## Why

Avoid collision with the existing Grist spreadsheet product and claim a clearer brand for local-first meeting notes + agents.

## Migration

On first launch, `QuernPaths` moves or copies:

`~/Library/Application Support/Grist` → `~/Library/Application Support/Quern`

(including `meetings.db`, configs, whisper.cpp, recordings). A `.migrated-from-grist` flag prevents repeats.

MCP (`quern-mcp-server`) prefers the Quern DB path and falls back to Grist if Quern’s DB is not present yet.

## Key changes

- Swift package / binary: `quern` · app bundle `Quern.app` · bundle id `com.quern.meetingassistant`
- Sources: `Sources/quern/`
- Types: `QuernApp`, `QuernLog`, `QuernTask`, `QuernHealth*`, `Quern*UI`
- MCP folder: `quern-mcp-server/` (Claude config key `quern`)
- Default Obsidian subfolder: `Quern`

## Follow-ups

- Re-grant Microphone / Screen Recording after the new bundle id (TCC treats it as a new app)
- Point Claude Desktop MCP `command` at `…/quern-mcp-server/quern-mcp-server` and quit/reopen Claude
- Optional: rename the GitHub repo `askinjohn/grist` → `askinjohn/quern`
