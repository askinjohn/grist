# 2026-08-04 — Read aloud: system voice only

## What changed

Removed Voicebox / external TTS integration. **Read summary** uses macOS `AVSpeechSynthesizer` only.

Settings → Integrations → **Read aloud**:
- Voice picker (English; Enhanced/Premium preferred)
- Rate & pitch
- Open System Settings for downloading better voices
- Test voice

## Why

Keep Grist zero-extra-app for speech. Neural local TTS (Kokoro/Qwen script) deferred.

## Expressiveness

macOS can sound better with Enhanced/Premium voices and rate/pitch, but not “instruct” emotion or cloning. True expressive TTS is a later optional stack.

## Key files

- `Sources/grist/SpeechService.swift`
- `Sources/grist/SettingsView.swift` (`VoiceSettingsCard`)
- `Sources/grist/SummarySpeechBar.swift`
- `README.md`
