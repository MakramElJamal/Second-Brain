---
tags: [projects, mcp]
created: 2026-06-20
source: project
status: active
summary: A local-first, token-light MCP server that lets any AI assistant search, read, and write this Obsidian vault — returning the smallest useful slice instead of dumping whole files into the model.
---

# second-brain-mcp

> [!abstract] In one line
> A local-first, token-light MCP server that lets any AI assistant (Claude,
> ChatGPT, Gemini) search, read, and write this Obsidian second brain without the
> notes ever leaving the machine.

## Goal

Most "AI + notes" tools dump whole files into the model. This one is stingy by
design: `search_notes` returns ranked snippets plus an extractive summary, and a
full note is fetched only when the snippet is not enough. The vault stays the
source of truth — plain markdown on disk, no lock-in.

## How token efficiency is achieved

- Search returns slices, not files: ranked snippets and a short summary per hit.
- `vault_map` answers "where does this go / what tags exist" in one small call.
- A curated eight-tool surface keeps the per-turn tool-definition tokens low.
- Raw chat transcripts are excluded from the index; memory is retrieved through
  tiny distilled notes.
- Edits send only the changed slice, never the whole note.

## Tasks

- [x] Pillar 1 — in-memory index, vault_map, tool curation.
- [x] Pillar 2 — write subsystem (create_note / edit_note).
- [x] Pillar 3 — archive_chat for cross-LLM memory.
- [ ] Pillar 4 — token benchmark, then optimize against it.
