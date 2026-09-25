# Plan: Quern Companion (optional sync server + native iOS reader)

**Status:** Phase 1–2 in PR #44 (server + Mac push). **Mobile deferred** — native SwiftUI when ready.  
**Goal:** Optional self-hosted mirror so an iPhone app can read Quern notes/tasks. Mac remains source of truth.

## Shape (v1 API)

```
Quern (Mac) --HTTPS push--> quern-sync (your server) <--HTTPS GET-- iOS app (read-only, later)
```

- Opt-in in Settings → Integrations → Companion sync
- Token in Keychain / `QUERN_SYNC_TOKEN`
- No audio, RAG, chat, or AI config synced

## Stack

| Piece | Choice |
|-------|--------|
| Server | `quern-sync/` Bun + Hono + SQLite, Docker |
| Mac | `CompanionSync.swift` + Settings UI |
| Mobile | **Native SwiftUI (iOS)** — separate target/app later. Not Expo / React Native. |

## Phases

0. File-split modularization — PR #43  
1. `quern-sync` API + Docker — shipped in #44  
2. Mac push client + Settings — shipped in #44  
3. **Native iOS SwiftUI reader** (deferred)  
4+. Mobile capture, E2E encryption, multi-device tokens  

## Phase 3 sketch (when we build mobile)

- New Xcode / SwiftPM iOS app (e.g. `QuernCompanion`)
- Reuse API models as Codable DTOs matching `quern-sync` JSON
- Screens: setup (URL + token in Keychain), library list, note detail (summary / notes / transcript), open tasks
- `URLSession` + pull-to-refresh; optional on-device SQLite cache later
- Same bearer token as Mac / server

## API

See `quern-sync/README.md`. Auth: `Authorization: Bearer <token>`.
