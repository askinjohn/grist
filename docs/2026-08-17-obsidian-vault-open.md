# 2026-08-17 — Obsidian vault path / open fix + README

## What

- Prefer `obsidian://open?path=` so open does not depend on vault display name
- Resolve vault root via `.obsidian`
- Optional `vaultName` in integrations config / Settings
- Finder fallback if URI fails
- README: Obsidian setup and generic “vault not found” troubleshooting

## Pitfall (generic)

Choosing a **parent** folder of the real vault means files may be written outside the vault Obsidian has open, and `vault=` in the URI may not match the name in Obsidian’s vault switcher.

## Key files

- `Sources/grist/IntegrationsConfig.swift`
- `Sources/grist/SettingsView.swift`
- `README.md`
