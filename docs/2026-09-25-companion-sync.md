# 2026-09-25 — Companion sync (optional server + Mac push)

## What

Optional self-hosted sync so a mobile companion can read Quern notes and tasks. Mac remains source of truth; nothing leaves the machine until Companion sync is enabled.

## Why

Read notes/summaries/tasks on a phone without turning Quern into a cloud product. Same opt-in spirit as Obsidian export.

## Changes

### `quern-sync/` (Bun + Hono + SQLite)

- `POST /v1/sync/push` — Mac upsert
- `GET /v1/library`, `/v1/notes/:id`, `/v1/tasks`, `/v1/folders`, `/v1/changes`
- Bearer auth via `QUERN_SYNC_TOKEN`
- Docker Compose for homelab/VPS

### Mac Quern

- Settings → Integrations → **Companion sync** (URL, Keychain token, section toggles)
- `CompanionSyncManager` — debounced push on save, tombstones on soft-delete, Sync now / Test connection
- Token stored in Keychain (`QuernKeychain`), not `integrations.json`

### Mobile

- `apps/quern-mobile` — Expo reader (Phase 3)

## Key files

- `quern-sync/`
- `Sources/quern/CompanionSync.swift`
- `Sources/quern/QuernKeychain.swift`
- `Sources/quern/IntegrationsConfig.swift`
- `Sources/quern/SettingsView.swift`
- `docs/plans/companion-sync.md`

## Follow-ups

- Offline cache on mobile
- Mobile quick-capture → Mac pull
- E2E encryption if desired
