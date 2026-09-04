# 2026-09-04 — Meeting detect → prompt → record

## What

Grist watches for Zoom / Teams / Google Meet / Webex windows. When a call looks active:

1. Menu bar shows a badge + **Record in Grist** / **Not now**
2. A system notification offers the same actions (if allowed)
3. **Record** creates a meeting and starts mic + system capture

Settings → General → **Meeting detection** (Prompt by default; optional Auto-start).

## Files

- `MeetingDetector.swift`, `MeetingPromptController.swift`
- `RecordingStatus.swift`, `grist.swift`, `MainView(+Data).swift`, `SettingsView.swift`
