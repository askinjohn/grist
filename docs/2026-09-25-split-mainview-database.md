# 2026-09-25 — Split MainView+Data/Detail and Database

## What

Compile-only modularization of the remaining large files after the Aug MainView split and system-review hardening.

## Why

`MainView+Data`, `MainView+Detail`, and `Database` were each ~1.1–1.2k lines. Domain files make navigation and review easier with no behavior change.

## Layout

### MainView+Data →

| File | Role |
|------|------|
| `MainView+Library.swift` | Search/filter, export folder, time grouping |
| `MainView+Import.swift` | URL/YouTube import, attach files |
| `MainView+Data.swift` | Load/save, tasks, create session |
| `MainView+Recording.swift` | Start/stop capture + Whisper |

### MainView+Detail →

| File | Role |
|------|------|
| `MainView+Detail.swift` | Router, shared chrome, toolbar, empty state |
| `MainView+NoteDetail.swift` | Note-focused UI |
| `MainView+MeetingDetail.swift` | Meeting-focused UI |

Hygiene: `sidebarCreateButton` → Sidebar; `folderChip` → Config.

### Database →

| File | Role |
|------|------|
| `Database.swift` | Open, schema, migrations, `execute` |
| `Database+Meetings.swift` | Meeting CRUD |
| `Database+Folders.swift` | Folders |
| `Database+Templates.swift` | AITemplate + CRUD |
| `Database+Chat.swift` | Conversations / messages |
| `Database+Chunks.swift` | RAG chunks |
| `Database+Tasks.swift` | Tasks |

`db` and `execute` are module-internal so sibling extensions can use them.

## Follow-ups

- Optional: split `MainView+Config` if it keeps growing
- Companion sync (optional server + mobile) — see `docs/plans/companion-sync.md`
