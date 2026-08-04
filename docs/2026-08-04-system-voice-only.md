# 2026-08-04 — Read aloud (system voice) + Settings UI + MainView split

## What changed

### Read aloud
- **AI Summary** bar: **Read summary** / **Stop**
- **macOS system voice only** (`AVSpeechSynthesizer`) — no Voicebox / cloud
- **Settings → Integrations → Read aloud**: voice picker, rate, pitch, Test voice, open System Settings

### Settings UI
- Fixed sheet **720×560**
- Sticky header + four tabs always visible
- **General / AI Models / Integrations** scroll inside; **AI Templates** split sidebar + editor

### MainView split
- `MainView.swift` ~state + body; extensions and companions for chat, create, models, speech

## Why

Zero extra TTS app for users; Settings usable without clipping; codebase maintainable.

## Key files

- `Sources/grist/SpeechService.swift`, `SummarySpeechBar.swift`
- `Sources/grist/SettingsView.swift`, `MainView.swift` (+ `MainView+*.swift`)
- `README.md`

## Follow-ups

- Optional scripted local neural TTS (Kokoro/Qwen) later
