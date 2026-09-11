# 2026-08-17 — Rename folders

## What

Right-click a folder in the sidebar → **Rename…**. Updates the folder row and every note/meeting in that folder.

## Why

Folders could only be created/deleted; rename was missing for reorganizing the library.

## Key files

- `Sources/quern/Database.swift` — `renameFolder(from:to:)`
- `Sources/quern/MainView+Config.swift` — context menu + commit handler
- `Sources/quern/MainView+Sidebar.swift` — rename alert
- `Sources/quern/MainView.swift` — rename state
