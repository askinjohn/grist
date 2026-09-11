# 2026-09-07 — Delete note inside folder must not delete folder

## What

Right-click Delete on a note/meeting inside a folder accordion was often running **Delete Folder…** instead of soft-deleting that one item.

## Why

Folder actions (including destructive Delete Folder) were attached to the whole `DisclosureGroup`. On macOS `List`, that parent context menu frequently wins when right-clicking nested rows, so “delete this file” wiped the folder.

## Fix

- Move the folder `contextMenu` onto the **folder label only**
- Clarify per-item menu labels: “Delete Note” / “Delete Meeting”
- Soft-delete still targets a single meeting id; folders table is untouched

## Key files

- `Sources/quern/MainView+Config.swift`
- `Sources/quern/LibrarySidebarRows.swift`
- `Sources/quern/MainView.swift`
