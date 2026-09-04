# 2026-09-04 — Reload library on window focus

## What

When Grist becomes active again (e.g. after using Claude/Cursor MCP tools), re-read notes, folders, and tasks from SQLite and show a short top-of-window “Fetching latest notes…” indicator.

## Why

MCP writes directly to `meetings.db` outside the app process. The UI kept an in-memory list and only reloaded on appear / in-app mutations, so new MCP notes did not appear until quit/relaunch.

## Behavior

- Trigger: `NSApplication.didBecomeActiveNotification` (after a short post-launch grace so cold start does not flash the banner)
- Banner: capsule at top with spinner + “Fetching latest notes…”
- Preserves the currently open note’s editor state (edits already autosave) to avoid cursor jumps
- Skips refresh while recording, enhancing, importing, organizing, or extracting tasks

## Key files

- `Sources/grist/MainView.swift` — state, overlay banner, `didBecomeActive` handler
- `Sources/grist/MainView+Data.swift` — `refreshLibraryOnFocus()`, `libraryRefreshBanner`

## Follow-ups

- Optional: also refresh the open note’s body from DB when MCP updates that same id (today we only refresh the list so the editor is not reset)
- Optional: FSEvents / mtime poll for near-instant updates without waiting for focus
