# Quern Mobile (companion reader)

Read-only Expo app for notes/tasks mirrored by **quern-sync**.

## Setup

1. Run `quern-sync` (see `../../quern-sync/README.md`).
2. In Mac Quern → Settings → Integrations → Companion sync: set URL + token, Sync now.
3. Here:

```bash
cd apps/quern-mobile
npm install
npx expo start
```

Enter the same base URL and token under **Settings**.

## Screens

- **Library** — list notes/meetings; open summary / notes / transcript
- **Tasks** — open tasks
- **Settings** — server URL + API token (AsyncStorage)

## Notes

- Requires network reachability to your sync host (same LAN or VPN/TLS).
- No editing in v1.
