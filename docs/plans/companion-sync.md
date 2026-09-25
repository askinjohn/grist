# Plan: Quern Companion (optional sync server + mobile reader)

**Status:** Phase 1–2 in progress  
**Goal:** Optional self-hosted mirror so a mobile app can read Quern notes/tasks. Mac remains source of truth.

## Shape (v1)

```
Quern (Mac) --HTTPS push--> quern-sync (your server) <--HTTPS GET-- Mobile (read-only)
```

- Opt-in in Settings → Integrations → Companion sync
- Token in Keychain / `QUERN_SYNC_TOKEN`
- No audio, RAG, chat, or AI config synced

## Stack

| Piece | Choice |
|-------|--------|
| Server | `quern-sync/` Bun + Hono + SQLite, Docker |
| Mac | `CompanionSync.swift` + Settings UI |
| Mobile | Expo (Phase 3) |

## Phases

0. File-split modularization — PR #43  
1. `quern-sync` API + Docker  
2. Mac push client + Settings  
3. Expo mobile reader  
4+. Mobile capture, E2E encryption, multi-device tokens  

## API

See `quern-sync/README.md`. Auth: `Authorization: Bearer <token>`.
