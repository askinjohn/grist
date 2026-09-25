# 2026-09-25 — Whisper preflight before recording

## What

Before starting capture, Quern now **actually launches** `whisper-cli --help` (and repairs stale `@rpath` from the Grist→Quern move). If Whisper can’t run, recording is blocked with a clear alert — so you don’t lose a 30‑minute meeting to a failed transcription.

## Why

After renaming Application Support `Grist` → `Quern`, Mach-O binaries still had:

`@rpath → …/Application Support/Grist/whisper.cpp/build/bin`

The binary *file* existed (health checklist passed), but dyld failed at runtime → `[Error: Whisper.cpp process failed…]` after Stop.

## Changes

- `WhisperTranscriber.preflightForRecording()` — real process probe + stderr
- `QuernPaths.fixWhisperRpathsIfNeeded()` — `install_name_tool` Grist→Quern rpath
- `startRecording` waits for preflight before mic/system capture
- Health checklist uses the same probe

## Key files

- `Sources/quern/WhisperTranscriber.swift`
- `Sources/quern/QuernPaths.swift`
- `Sources/quern/MainView+Data.swift`
- `Sources/quern/QuernHealth.swift`
- `Sources/quern/quern.swift`
