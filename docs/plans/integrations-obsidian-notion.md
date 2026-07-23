# Plan: Obsidian & Notion integrations

**Status:** Planned — not implemented  
**Priority:** After core Tasks / AI roles / RAG land on main  
**Goal:** Optional “link and push” so users can send Grist notes, summaries, and tasks into tools they already use.

---

## Principles

1. **Local-first stays default.** Integrations are opt-in; nothing leaves the machine unless the user connects a cloud service.
2. **User supplies connection details.** We do not scrape or guess vaults/workspaces.
3. **Start thin.** Push note / summary / tasks first; two-way sync later if needed.
4. **Reuse export.** Markdown we already produce is the natural payload for Obsidian (and a fine format for Notion pages).

---

## Obsidian

### What we ask the user (Settings → Integrations → Obsidian)

| Field | Why |
|--------|-----|
| **Enable Obsidian export** | Master toggle |
| **Vault folder path** | Absolute path to their Obsidian vault (folder picker) |
| **Subfolder (optional)** | e.g. `Grist/` or `Meetings/` inside the vault |
| **Filename pattern** | e.g. `{date}-{title}.md` |
| **What to export by default** | Summary only / notes / full (same section choices as Export) |
| **After Enhance** (optional) | Auto-write Markdown into vault |

Optional later:

| Field | Why |
|--------|-----|
| **Obsidian Local REST API** base URL + API key | If they use the community plugin for richer “open note” / append |
| **URI handler** | `obsidian://open?vault=…&file=…` after write |

### How it works (v1)

1. User picks vault root once.
2. On **Send to Obsidian** (or auto after Enhance):
   - Build Markdown via existing `NoteExporter` / section options.
   - Write file under vault + subfolder.
   - Optional: open via `obsidian://` if vault name known.
3. No Obsidian app API required for v1 — **filesystem only**.

### Why this is easy / safe

- Vault = normal directory; privacy stays on disk.
- User explicitly grants folder access (macOS may prompt for Desktop/Documents).

### Risks / notes

- Concurrent edits if both apps rewrite the same file → prefer **new files** or **append with timestamp**, not blind overwrite.
- Symlinked or iCloud vaults: document “vault must be a local path Grist can write”.

---

## Notion

### What we ask the user (Settings → Integrations → Notion)

| Field | Why |
|--------|-----|
| **Enable Notion** | Master toggle |
| **Integration token** (or OAuth later) | Notion internal integration secret / user OAuth |
| **Parent page or database ID** | Where new pages/rows go |
| **Property map (if database)** | Title, Date, Folder, Source URL → Notion properties |
| **What to push** | Page body = Markdown summary/notes; optional Tasks as checklist or child pages |

User setup steps we document:

1. Create a Notion integration at [notion.so/my-integrations](https://www.notion.so/my-integrations).
2. Share the target page/database with that integration.
3. Paste token + parent ID into Grist.

### How it works (v1)

1. Store token in Keychain (not plain README); optional `apiKeyEnv` pattern like `ai-config.json`.
2. **Send to Notion**:
   - Create page under parent **or** create database row.
   - Body = converted Markdown (or plain text if conversion deferred).
3. Optional: push open **Tasks** as a checklist block or linked database.

### Risks / notes

- Cloud: content leaves the device — call out in UI.
- Rate limits, token scope, “integration must have access to page”.
- OAuth is nicer UX than raw tokens but more work; **token-first is fine for v1**.

---

## Shared product UX

### Settings

```
Settings
  └── Integrations
        ├── Obsidian  [off/on]  Vault…  Subfolder…  Defaults…
        └── Notion    [off/on]  Token…  Parent page/DB…  Defaults…
```

### Actions (per note / meeting / task)

- **Send to Obsidian…**
- **Send to Notion…**
- Optional: multi-select or folder export → batch send

### Config storage (proposed)

```text
~/Library/Application Support/Grist/integrations.json
```

Example shape (illustrative):

```json
{
  "version": 1,
  "obsidian": {
    "enabled": false,
    "vaultPath": "",
    "subfolder": "Grist",
    "filenamePattern": "{date}-{title}.md",
    "defaultSections": ["summary", "notes"],
    "autoAfterEnhance": false
  },
  "notion": {
    "enabled": false,
    "tokenEnv": "NOTION_TOKEN",
    "parentPageId": "",
    "databaseId": "",
    "autoAfterEnhance": false
  }
}
```

Keys: prefer Keychain / env vars over committing secrets into JSON when possible.

---

## Implementation phases (later)

| Phase | Scope |
|-------|--------|
| **P0** | Plan only (this doc) |
| **P1 — Obsidian** | Folder picker + write Markdown + menu action |
| **P2 — Notion** | Token + create page/row + menu action |
| **P3** | Auto-export after Enhance; push Tasks; batch folder |
| **P4** | OAuth for Notion; Local REST API for Obsidian; conflict UX |

---

## Out of scope (for now)

- Two-way sync / live mirror  
- Importing entire Obsidian vault or Notion workspace into Grist  
- Replacing Grist’s own library with a remote CMS  

---

## Success criteria

- User can link Obsidian with **only a folder path** and get a file in the vault.  
- User can link Notion with **token + parent** and get a page created.  
- Disconnect / disable removes future pushes without deleting remote content.  
- Core Grist works fully with both integrations off.

---

## Open questions

1. Default Obsidian subfolder name (`Grist/` vs `Inbox/`)?  
2. Notion: pages under a parent vs database rows first?  
3. Should Tasks sync to Notion Todo / checklist or stay Grist-only until P3?  
4. Marketing: “export” vs “sync” wording (we should say **export/push** until two-way exists).
