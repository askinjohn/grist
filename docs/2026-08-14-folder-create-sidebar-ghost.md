# 2026-08-14 — Fix floating meeting row when creating a folder

## What happened

Opening a meeting, then creating a folder showed **Empty folder** with a floating selected meeting row on top of it.

## Cause

1. **Create folder** set `focusedFolder = name`, switching the sidebar into “show only this folder” mode for a new empty folder.
2. The open meeting stayed in `selectedMeeting` but was **no longer listed** in the sidebar `List`.
3. macOS SwiftUI `List(selection:)` still held that selection and painted a **ghost selected row** over the empty state.

## Fix

- Creating a folder only **expands** it in the accordion (does not force focus mode).
- Sidebar list selection uses a binding that returns `nil` when the selected meeting is not currently tagged in the list (detail can stay open).

## Key files

- `Sources/grist/MainView+Sidebar.swift`
