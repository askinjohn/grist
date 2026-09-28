# 2026-09-28 — Clear stale menu-bar “Recording 0:00”

## What

Menu bar could show **Recording 0:00** (and Stop Recording) when nothing was capturing.

## Why

Recording chrome lives in `RecordingStatus.shared` (menu bar), while the session flag is `@State isRecording` on `MainView`. If SwiftUI remounts `MainView`, local state resets to idle but the singleton stays “recording”. Menu **Stop** only called `stopRecording()` when `@State` was true — so Stop did nothing and the ghost UI stuck at 0:00 (timer gone with the view).

## Changes

- Stop request always clears via `handleStopRecordingRequest()` (session **or** stale chrome / orphaned capture)
- Reconcile on appear + app become-active: drop ghost chrome; force-stop orphaned mic/SCK
- Menu Stop fallback clears hardware + chrome if MainView didn’t
- `AudioRecorder.isMicRecording` / `isActivelyCapturing` for truth checks

## Key files

- `Sources/quern/RecordingStatus.swift`
- `Sources/quern/MainView+Recording.swift`
- `Sources/quern/MainView.swift`
- `Sources/quern/quern.swift`
- `Sources/quern/AudioRecorder.swift`
