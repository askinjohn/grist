# 2026-09-11 — Enhance large Attach-file notes without timeout

## What

Enhance on large attached notes (e.g. ~25k-char study `.md`) was timing out at 180s. Fix: map-reduce earlier, smaller single-pass caps, and pause RAG embeds while Enhance runs.

## Why

Logs showed Attach worked; Enhance sent one ~26k-char prompt while local Ollama ran with a small context (~4k tokens) and concurrent `nomic-embed-text` jobs from reindexing.

## Changes

- Map-reduce threshold **32k → 12k** chars; chunk size **12k → 8k**; single-pass max **28k → 12k**
- Pause RAG indexing during Enhance; resume and drain deferred ids after
- Delay post-Attach reindex (8s) so Enhance can start cleanly
- Clearer timeout status message; status “Enhancing long note (chunked)…” for large sources

## Key files

- `Sources/quern/OllamaClient.swift`
- `Sources/quern/RAGEngine.swift`
- `Sources/quern/MainView+AI.swift`
- `Sources/quern/MainView+Data.swift`
