# Desktop completion — 30 September 2026

## Implemented

- Sidebar contains navigation and folders; notes, meetings, folder contents, search results and tasks render in the main pane. Lists have sorting and item actions; detail views have a return route.
- Tasks have persistent Open / Completed / All filters in the main header, completion from Today, due dates, priority, assignee and sorting. A date-only deadline becomes overdue the following day.
- Today separates overdue tasks, shows recent notes and offers opt-in calendar events for the next seven days.
- Meeting detection debounces microphone/window signals into an episode and prefills a useful Google Meet title when available.
- Settings are grouped into Workflow, AI models, Templates, Integrations, Search & data, and Voice.
- Notion supports token and destination checks, page/data-source discovery, explicit destination selection, bounded append batches and local export history. Tokens use Keychain.
- Ask supports folder/creation-date scope, searchable/pinned history, evidence cards, source opening, copy, save as note, create task and explicit Notion export.
- Retrieval combines lexical and semantic rankings with deduplication, reads current source passages, bounds context, preserves evidence with chat history and rejects unknown citation IDs after one repair attempt. If embeddings fail, lexical retrieval remains available.
- Existing recording/index/database reliability fixes have regression coverage.

## Validation and limits

`swift test` covers recording preservation, index transaction rollback/stale writes, meeting episodes, task migrations/planning, saved evidence, overlapping rankings, scope exclusions, synthetic lexical retrieval, citation IDs, verbatim passages and Notion payload limits. These are deterministic offline tests, not a quality benchmark of a live language model.

Live Notion permissions and calendar access require the user's configured account/OS grant. No private content was exported during validation. Notion append failures after partial success are reported without automatic retries, because retries could duplicate content.

Citation validation establishes that a cited ID exists; it cannot establish that every claim is supported. Embedding similarity thresholds remain heuristics. Before changing retrieval models, evaluate representative answerable, unanswerable and conflicting questions against manually checked source passages. Track retrieved-source recall, factual support, abstention and latency separately.

The installed build was reopened and the Today deep link reached Today. The
widget extension and app were signed with the same App Group entitlement, and
the app wrote a snapshot to the shared container. Placement through macOS Edit
Widgets and Calendar/Notion account access remain user-side checks.

## Explicit future roadmap

The macOS Today widget is now packaged with Quern. The hosted multi-user server,
URL-configured sync and view-only mobile companion remain separate future work.
See `plans/companion-server.md`. Graph RAG and model reranking are not enabled;
they should follow measured retrieval failures rather than being added without evidence.

The synthetic Ask smoke suite passes four locally served qwen2.5:7b cases:
answerable fact, unsupported deadline, conflicting deadlines, and an instruction
in source text. This is a small behavioral check, not an accuracy estimate on
real notes.
