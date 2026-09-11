# 2026-09-11 — Attach local files into a note

## What

**Attach file** on notes/meetings: pick `.md`, `.txt`, or `.pdf`. Extracted text is appended into the note body (Write tab) with an `Attached: filename` header so Enhance, Chat, and RAG can use it.

## Why

Users often take notes elsewhere and need them in Quern without retyping. URL import already covers the web; this covers local files.

## Behavior

- Multi-select via `NSOpenPanel`
- UTF-8 (or Latin-1 fallback) for text/Markdown
- PDF via PDFKit page text (image-only scans fail with a clear error)
- Saves + switches to Write; reindexes for Ask everything

## Key files

- `Sources/quern/NoteFileImporter.swift`
- `Sources/quern/MainView+Data.swift` — `attachFilesToCurrentNote()`
- `Sources/quern/MainView+Detail.swift` — toolbar / Write controls
- `README.md`

## Follow-ups

- Keep binary attachments on disk (not only extracted text)
- OCR for scanned PDFs
- Drag-and-drop onto the Write editor
