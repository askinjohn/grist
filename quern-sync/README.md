# quern-sync

Companion sync server for Quern. The Mac app pushes meetings, folders, and tasks; a future **native iOS** client (or any HTTP client) can read them. Auth is a shared bearer token. Data lives in a local SQLite file.

## Requirements

- [Bun](https://bun.sh) 1.x

## Quick start (local)

```bash
cd quern-sync
bun install

export QUERN_SYNC_TOKEN="dev-secret-change-me"
bun start
# listens on http://0.0.0.0:8787
```

If `QUERN_SYNC_TOKEN` is unset, the server generates a one-off token and prints a warning (dev only).

### Env

| Variable | Default | Notes |
|---|---|---|
| `QUERN_SYNC_TOKEN` | (generated) | Required for all `/v1/*` routes except health |
| `PORT` | `8787` | |
| `HOST` | `0.0.0.0` | |
| `DB_PATH` | `./data/quern-sync.db` | Parent dir is created automatically |

## Docker

```bash
export QUERN_SYNC_TOKEN="prod-secret"
docker compose up --build -d
```

Persists SQLite under the `quern-sync-data` volume at `/data/quern-sync.db`.

## API

All routes under `/v1` (except health) require:

```
Authorization: Bearer <QUERN_SYNC_TOKEN>
```

### Health

```bash
curl -s http://127.0.0.1:8787/v1/health
# {"ok":true,"version":"0.1.0"}
```

### Push (upsert, last-write-wins by `updated_at`)

```bash
TOKEN=dev-secret-change-me
curl -s -X POST http://127.0.0.1:8787/v1/sync/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "meetings": [{
      "id": "m1",
      "title": "Standup",
      "timestamp": 1727000000,
      "manual_notes": "",
      "transcript": "hello",
      "summary": "short",
      "template": "Meeting",
      "group_name": "Work",
      "duration_seconds": 600,
      "is_deleted": false,
      "updated_at": 1727000100
    }],
    "folders": [{
      "name": "Work",
      "created_at": 1726990000,
      "updated_at": 1726990000
    }],
    "tasks": [{
      "id": "t1",
      "title": "Follow up",
      "notes": "",
      "source_meeting_id": "m1",
      "source_title": "Standup",
      "status": "open",
      "created_at": 1727000200,
      "completed_at": null,
      "is_deleted": false,
      "updated_at": 1727000200
    }]
  }'
# {"ok":true,"upserted":{"meetings":1,"folders":1,"tasks":1}}
```

### Library

```bash
curl -s "http://127.0.0.1:8787/v1/library?limit=50&folder=Work&q=Stand" \
  -H "Authorization: Bearer $TOKEN"
```

### Note / meeting detail

```bash
curl -s http://127.0.0.1:8787/v1/notes/m1 \
  -H "Authorization: Bearer $TOKEN"
```

### Tasks

```bash
curl -s "http://127.0.0.1:8787/v1/tasks?status=open" \
  -H "Authorization: Bearer $TOKEN"
```

### Folders

```bash
curl -s http://127.0.0.1:8787/v1/folders \
  -H "Authorization: Bearer $TOKEN"
```

### Changes since timestamp (includes tombstones)

```bash
curl -s "http://127.0.0.1:8787/v1/changes?since=0" \
  -H "Authorization: Bearer $TOKEN"
```

## License

MIT
