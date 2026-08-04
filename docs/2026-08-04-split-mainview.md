# 2026-08-04 — Split MainView.swift

## What changed

`MainView.swift` grew past **6,300 lines** (models, chat, create sheet, sidebar, AI, data, etc.). It is now a thin shell (~**290 lines**: state + `body`) with focused companions.

| File | Role |
|------|------|
| `MainView.swift` | State properties + root `body` |
| `MainView+Sidebar.swift` | Library sidebar + tasks UI |
| `MainView+Sheets.swift` | Export options + folder summarize sheets |
| `MainView+Config.swift` | Model picker ↔ ai-config + Obsidian |
| `MainView+Detail.swift` | Note/meeting detail, empty state, toolbar |
| `MainView+Data.swift` | Computed data, export, load/save, recording |
| `MainView+AI.swift` | Enhance / title / clipboard helpers |
| `MeetingModels.swift` | `Meeting`, filters, create kinds, presets |
| `RootView.swift` | App root sheet + keyboard chrome |
| `LibrarySidebarRows.swift` | `SidebarRow`, `TaskSidebarRow` |
| `ChatView.swift` | Chat scope, threads, bubbles |
| `CreateItemSheet.swift` | New meeting/note/article sheet |
| `SummarySpeechBar.swift` | Read-aloud bar |

No intentional behavior changes — compile-only modularization. Members used across `MainView` extensions are module-internal (not `private`) so multi-file extensions work.

## Why

Easier navigation, review, and ownership; reduce merge pain on one mega-file.

## Follow-ups

- Split `MainView+Detail` (note vs meeting) and `ChatView` further if they keep growing
- Optionally re-`private` helpers that stay single-file
