# 2026-09-25 — System review hardening

## What

Hardened recording, DB concurrency, health checks, soft-delete RAG cleanup, folder rename atomicity, live transcript clock, attach I/O, focus reload, and Enhance progress after a full-system review.

## Why

Review findings: Stop could early-return before `recorder.stop()` when selection changed; SQLite lacked WAL/busy_timeout for app+MCP; health treated any model as chat; soft-deleted notes left RAG orphans; folder rename was non-atomic; live ASR advanced the window on extract/ASR failure; Attach blocked the main thread; focus refresh skipped reloading MCP-updated open notes; Enhance used stringly status gating.

## Changes

- **Recording**: `recordingMeetingId` pins the capture target; `stopRecording` always stops mic/SCK and saves by id
- **SQLite**: `PRAGMA journal_mode=WAL`, `busy_timeout=5000`, `synchronous=NORMAL` in app DB + MCP server
- **Health**: chat vs embed detection no longer classifies “any model” as chat; embed match prefers configured/capability names
- **ffmpeg**: resolve Homebrew Intel/Apple Silicon, PATH, UserDefaults (same pattern as yt-dlp)
- **Soft-delete**: single meeting and folder soft-delete both drop `chunks` rows
- **renameFolder**: `BEGIN IMMEDIATE` + rollback-on-failure
- **Live transcript**: only advance `nextStart` after successful extract + ASR
- **Attach**: parse files off the main actor via `Task.detached`
- **Focus reload**: reload open note from disk when MCP/external writers changed content
- **Enhance**: `isEnhancing` flag + map-reduce `onProgress` status updates

## Key files

- `Sources/quern/MainView.swift`
- `Sources/quern/MainView+Data.swift`
- `Sources/quern/MainView+AI.swift`
- `Sources/quern/Database.swift`
- `Sources/quern/QuernHealth.swift`
- `Sources/quern/WhisperTranscriber.swift`
- `Sources/quern/LiveTranscriptionService.swift`
- `Sources/quern/OllamaClient.swift`
- `quern-mcp-server/index.js`

## Follow-ups

- P2: split large MainView / Database god-objects (deferred; behavior fixes only in this MR)
