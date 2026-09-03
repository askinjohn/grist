# 2026-09-02 — Live transcription (rolling Whisper)

## What

While a meeting is recording, the **Transcript** tab shows a rolling live transcript (local whisper.cpp on short mic windows). On **Stop**, the existing full Whisper pass still runs and replaces the draft.

## Settings

**Settings → General → Live transcription** (default on).

## Files

- `LiveTranscriptionService.swift`
- `WhisperTranscriber.swift` (`transcribeChunk`, `extractChunkWAV`)
- `MainView+Data.swift`, `MainView+Detail.swift`, `SettingsView.swift`, `RecordingStatus.swift`
