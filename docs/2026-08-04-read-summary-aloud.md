# 2026-08-04 — Read summary aloud (local TTS)

## What changed

AI Summary views (notes + meetings) get a **Read summary** bar. Speech is local-first:

1. **Voicebox** ([voicebox.sh](https://voicebox.sh/)) — local voice studio/API on `http://127.0.0.1:17493`. Hosts engines such as Qwen3-TTS and Chatterbox (“Ollama for voices,” not Ollama itself). Quern calls `POST /generate` and plays the returned audio.
2. **macOS system voice** (`AVSpeechSynthesizer`) — always-available fallback when Voicebox is off.

Settings → Integrations → **Read aloud (TTS)** for backend preference, Voicebox URL, and voice profile (when listed).

## Why

NotebookLM-style listen-to-summary without cloud TTS (no ElevenLabs). Keeps Quern privacy-first: models and audio stay on the machine when Voicebox is used.

## Key files

- `Sources/quern/SpeechService.swift` — Voicebox health/profiles/generate + system fallback
- `Sources/quern/MainView.swift` — `SummarySpeechBar` on note/meeting AI Summary
- `Sources/quern/SettingsView.swift` — `VoiceSettingsCard`
- `README.md` — TTS setup table

## Follow-ups

- Optional delivery `instruct` string for Qwen3-TTS expression control
- Chunk long summaries if Voicebox engines hit length limits
- Optional save/export of generated audio
