# 2026-08-17 — Obsidian vault path / open fix + README

## What

- Prefer `obsidian://open?path=` so open does not depend on vault display name
- Resolve vault root via `.obsidian`
- Optional `vaultName` in integrations config / Settings
- Finder fallback if URI fails
- **README:** full Obsidian setup, send existing notes, “Vault not found”, troubleshooting

## User pitfall

Choosing parent folder `…/Obsidian` while the real vault is `…/Obsidian/My notes` (name **My notes**). Files land outside the vault; open URL uses `vault=Obsidian` → Obsidian error.

## Key files

- `Sources/grist/IntegrationsConfig.swift`
- `Sources/grist/SettingsView.swift`
- `README.md`
