# Companion server and mobile reader

## Goal

Let a person point Quern at one hosted server, then use their meetings, notes, tasks, and Today dashboard in a view-only mobile companion. The same server should expose a documented, scoped API for apps built on a user’s own data.

## Product boundary for the first release

- Quern remains the capture and editing app.
- Desktop uploads item and task changes to the configured server in the background.
- Mobile is read-only: Today, tasks, list/search, meeting/note detail, and transcript/summary.
- The server never runs a user’s local AI model or reads microphone audio.
- Audio stays on the desktop for v1. Transcript and note text are synchronized only when the user enables the server.

## Required security decision

A server URL alone cannot authenticate a person safely on a shared hosted service. The server needs a sign-in step that creates a user identity and device session; after that first sign-in, desktop and mobile can only ask for the server URL. The recommended initial choice is email magic-link sign-in because it has no password recovery burden and works equally on Mac and mobile.

## API shape

`GET /v1/me/today` returns a compact Today snapshot.

`GET /v1/items?cursor=` returns metadata, summaries, and a change cursor.

`GET /v1/items/:id` returns one synchronized item.

`GET /v1/tasks?status=open` returns tasks.

`POST /v1/sync/push` accepts immutable change records from the desktop.

`GET /v1/sync/pull?cursor=` returns ordered remote changes.

Every request is tenant-scoped by the signed-in user. API tokens for third-party apps are created in the account, are hashed at rest, carry scopes such as `items:read` and `tasks:read`, and are revocable.

## Data and conflict strategy

Each item and task needs `updated_at`, `deleted_at`, stable UUID, device ID, and revision. The server records an append-only change log. V1 uses last-write-wins per field for notes, summaries, task state, title, and folder; the client retains a local conflict copy when text fields conflict rather than silently deleting either edit.

## Deployment

The production server should use Postgres, object storage only if audio sync is later added, an encrypted secrets store, and a transactional job queue. SQLite is useful for a local development server but is not the hosted multi-user datastore. The API, web dashboard, and mobile companion should be separate targets from the macOS desktop app.
