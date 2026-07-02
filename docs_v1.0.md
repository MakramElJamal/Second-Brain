# Second Brain MCP — Documentation v1.0

A complete description of what this app is, how it works, and everything built
so far (the three pillars of the read/write layer).

---

## 1. What this is

A **local-first, token-light MCP server** that lets any MCP-capable assistant
(Claude, ChatGPT, Gemini, …) **search, read, and write** your personal Obsidian /
markdown "second brain" — from the desktop app *or* over the web — without ever
moving your notes off your machine.

**The wedge:** most "AI + notes" tools dump whole files into the model. This one
is **stingy by design** — it returns the *smallest useful slice* (ranked snippets
+ summaries), and only fetches a full note when asked. The vault stays the source
of truth: plain markdown on disk, no lock-in.

**Three things it does:**
1. **Read** your brain token-efficiently (ranked search, progressive disclosure).
2. **Write** to your brain in *your* house style (PARA placement, templates, tag
   governance) so every LLM files notes consistently.
3. **Remember across tools** — distill a conversation into a compact note so a
   different LLM, in a different project, next week, can pick up the context.

---

## 2. Architecture

```
   Obsidian (you, editing)
            │
            ▼
   Filesystem: <vault>/*.md   ◀── single source of truth
            │
            ▼
   second-brain-web-mcp  (Python, FastMCP, 127.0.0.1:8531, Streamable HTTP)
     ├─ obsidian_vault_mcp/   upstream secure core (fork, unmodified)
     └─ second_brain_ext/     our token-light read/write + tool-curation layer
            │
            ▼
   Cloudflare Tunnel  (outbound-only, TLS at the edge)
            │
            ▼
   https://vault.<your-domain>   ◀── connector URL
            │
        ┌───┴────────────┬──────────────┐
     Claude.ai        ChatGPT          (any MCP client)
```

- **The server runs on your machine** (where the vault is). The tunnel only
  forwards traffic addressed to your hostname; nothing else (e.g. your network /
  gaming traffic) is touched. When the machine is off, clients cleanly error —
  there is no data loss, because your machine is the single writer.
- **Two transports:** local **stdio** (for desktop clients on the same machine)
  and **Streamable HTTP** (for web clients via the tunnel). v1 deployment uses
  HTTP + Cloudflare Tunnel.
- **Built on** [`jimprosser/obsidian-web-mcp`](https://github.com/jimprosser/obsidian-web-mcp)
  (MIT) for the hardened, secure substrate; our value-add lives entirely in
  `second_brain_ext/` via that project's **extension seam** — upstream core is
  untouched, so upstream security fixes merge cleanly. See `NOTICE.md`.

---

## 3. The tool surface (8 curated tools)

The LLM sees a small, opinionated set. Upstream ships ~20 low-level tools; we
**prune to an allowlist** (reversible — the code stays, it's just un-advertised)
to save tokens and steer the model to safe, house-style operations.

| Tool | Kind | What it does |
|---|---|---|
| `search_notes` | read | Ranked snippets + summaries (never full notes). Filters: `bucket`, `tags`, `date_from/to`. |
| `get_note` | read | One note by id; `section=` returns a single heading's subtree, `outline=true` just the headings (token-light reads of long notes). |
| `vault_map` | read | Cheap structural overview: buckets+counts, **folder tree**, projects+status, approved tags, recent notes, total. Call before writing. |
| `create_note` | write | New note, PARA-placed, templated, tag- **and folder-governed**, idempotent filename. |
| `edit_note` | write | `append` / `replace_section` / `set_frontmatter` — send only the changed slice. |
| `archive_chat` | write | Distill THIS chat into a compact note (+ optional linked raw transcript) for cross-LLM memory. |
| `vault_search_frontmatter` | read | Query by frontmatter field (e.g. `status=active`). Kept from upstream. |
| `vault_move` | write | Move / rename a note. Kept from upstream. |

**Pruned (still in code, un-advertised):** `vault_read`, `vault_search`,
`vault_list`, `vault_write`, `vault_edit`, `vault_append`, `vault_delete`
(blocked by the *archive-don't-delete* rule), `vault_batch_read`,
`vault_write_binary`, `vault_batch_frontmatter_update`, `vault_canvas_*`,
`vault_daily_note_*`, `vault_analytics_*`. Re-enable by editing `ALLOWLIST` in
`second_brain_ext/extension.py`.

---

## 4. The three pillars (what was built)

### Pillar 1 — Indexing, `vault_map`, and tool curation
The foundation for correct, token-light reads and placement.
- An **in-memory content index** of every note (`id, title, bucket, tags,
  created, source, summary, body, modified, status`), built at startup and kept
  fresh via the upstream frontmatter index's change listener. AI-instruction
  files (`CLAUDE.md`, `GEMINI.md`, `AGENTS.md`) and `_*`/hidden files are excluded.
- **`vault_map`** — one cheap call that tells the model the buckets, current
  projects (with status), the approved tag vocabulary, and recent notes, so it
  can file and tag new notes correctly without listing directories.
- **Tool curation** — prune the surface from ~20 to 8 via `mcp.remove_tool`,
  after upstream + our tools register.

### Pillar 2 — The write subsystem (`create_note`, `edit_note`)
Writes go through *your* house style, enforced for every LLM.
- **PARA placement:** the model picks the bucket (Projects/Areas/Resources/
  Archives/Daily Notes); the tool validates it and files there. Unknown bucket →
  `status="needs_bucket"` (nothing written) so the model can confirm with you.
- **Per-type templates:** e.g. a project gets `status: active` + Goal/Tasks/Notes
  scaffold; a resource gets a Summary callout. House-style frontmatter standard
  (`tags, created, source`).
- **Tag governance:** writes may only use tags from your **approved vocabulary**
  (`_claude-tags.md`, bootstrapped from your existing tags on first write).
  Unknown tags are returned in `proposed_tags` and *not* applied unless
  `approve_new_tags=true`. Keeps search clean and matches your "never invent
  tags" rule.
- **Folder governance (housekeeping):** `vault_map` surfaces the existing folder
  tree, and `create_note`'s `folder` snaps to an existing folder when it nearly
  matches (case/format-insensitive) so the tree doesn't sprawl with near-duplicates
  ("historic figures" → "Historic Figures"); a genuinely new folder is created but
  flagged (`new_folder`) with close existing ones in `similar_folders`.
- **Token-efficient edits:** `edit_note` appends / replaces a section / merges
  frontmatter — you never resend the whole note. Responses are minimal (id +
  status), never an echo of the file.
- **House-style enforcement:** long dashes (—/–) are normalized outside code
  fences; idempotent filenames (no accidental clobber); deletes are not exposed.

### Pillar 3 — Chat archive (`archive_chat`) — cross-LLM memory
Turn a conversation into reusable, queryable memory.
- The **LLM distills the conversation at save time** (no LLM runs on the server):
  a tight `summary` plus optional `decisions`, `open_questions`, `key_points`.
- A compact **distilled note** is written to `Chat Archive/{YYYYMMDD}-{source}-{slug}.md`
  with frontmatter (`source`, `type: chat`, `summary`, optional `project` link,
  `participants`) — this is what `search_notes` retrieves.
- The optional **full transcript** is written to
  `Chat Archive/raw/_{id}.md` and linked from the distilled note. The leading
  underscore keeps it **out of the search index** (token-light) while remaining
  fetchable by id via `get_note`.
- **Continuation:** pass `continue_id` to append a dated update to an existing
  archive instead of creating a new one.
- **The payoff:** a 50k-token conversation becomes a ~300-token retrievable
  memory that any client can pull later, scoped by `source`, `tags`, or project.

---

## 5. Data model & conventions

**Note frontmatter standard:** `tags`, `created`, `source` (+ `status` for
projects). PARA buckets are the top-level folders. Filenames are human-readable
note titles (sanitized); chat archives use a date-prefixed id.

**Tag vocabulary:** `_claude-tags.md` at the vault root is the approved list;
edit it to curate. If absent, the vocabulary is derived from tags already in use.

**Chat archive layout:**
```
Chat Archive/
  20260628-claude-designing-the-mcp.md     ← distilled, searchable
  raw/
    _20260628-claude-designing-the-mcp.md  ← full transcript, excluded from search
```

---

## 6. Token efficiency

- **Search returns slices, not files** — ranked snippets + an extractive summary
  per hit; full content only via `get_note` (progressive disclosure).
- **`vault_map`** answers "where does this go / what tags exist" in one small
  call instead of many directory/file reads.
- **Curated 8-tool surface** keeps tool-definition tokens (sent every turn) low.
- **Raw transcripts are excluded from the index**, so chat memory is retrieved
  via tiny distilled notes.
- **Edits send only the changed slice.**
- Ranking is keyword-based and **coverage-dominated with stopword filtering**, so
  short, on-topic notes beat long notes that merely repeat common words. (A token
  benchmark to quantify all of this is the next item — see Roadmap.)

---

## 7. Security model

Inherited from the hardened upstream core, plus our additions:
- **Auth:** OAuth 2.0 authorization-code + **mandatory PKCE (S256)** with an
  interactive human login gate; per-request **bearer token** compared in constant
  time; **fails closed** if no token/password is set.
- **No token pass-through / URL spoofing defense:** pinned `VAULT_MCP_PUBLIC_URL`
  + allowed-hosts (DNS-rebinding protection); trusted-forwarder allowlist.
- **Filesystem safety:** path-traversal, symlink, null-byte, and dotfile access
  rejected; **atomic writes** (temp + rename, no-clobber); soft-delete to
  `.trash` (and `vault_delete` isn't even exposed).
- **Audit log** of mutations with a SHA-256 hash of the token (never the raw
  token); secrets file ACL-restricted on Windows.
- **Our layer:** curated tool surface, tag governance, archive-don't-delete.
- **Operational note:** Cloudflare's "Block AI Scrapers and Crawlers" must be
  **off** for the connector host, or it blocks the LLMs' tool calls.
- **Residual risks** (see `SECURITY.md`): prompt-injection from note content,
  single shared bearer token (no per-client scoping yet), and reliance on your
  tunnel/identity provider. Keep a human in the loop for writes; the vault's git
  history is your backup.

---

## 8. Deployment

- **Local (desktop clients):** run over stdio, point the client's MCP config at
  the server. (See the original stdio prototype, below.)
- **Remote (web clients):** run the server on loopback + a Cloudflare named
  tunnel to `https://vault.<your-domain>`; register that URL as a custom
  connector in Claude.ai and a developer-mode connector in ChatGPT. Full guides:
  - `DEPLOY.md` (index), `docs/deploy-cloudflare.md`, `docs/deploy-tailscale.md`.
- **Durability:** `scripts/install-server-task.ps1 -CloudflaredTunnel <name>`
  registers auto-start tasks for the server + tunnel (run as Administrator) and
  disables sleep on AC power, so it survives reboots.
- **Config:** `.env` (gitignored) holds `VAULT_PATH`, secrets, and the pinned
  public URL; `run.ps1` loads it, hardens the secrets ACL, and starts the server.

---

## 9. Project layout

```
second-brain-web-mcp/
  src/
    obsidian_vault_mcp/      # upstream secure core (fork; unmodified)
    second_brain_ext/        # OUR layer
      extension.py           # tools, tool-curation, in-memory index, lifecycle
      note.py                # parse vault markdown -> Note objects
      ranking.py             # keyword + metadata ranking (coverage, stopwords)
      tags.py                # approved-tag vocabulary + governance + bootstrap
      templates.py           # PARA bucket routing + per-type templates
      writing.py             # render, house-style, create/append/section/frontmatter
      chat.py                # chat-archive distillation (distilled + raw)
      sections.py            # read-side section slicing for section-level get_note
      benchmark.py           # Pillar 4: token benchmark (second-brain-bench)
      eval_search.py         # search-accuracy eval / scoreboard (second-brain-eval)
      entry.py               # console entry: serve([SecondBrainExtension()])
  tests/                     # 59 extension tests + sample & bench vault fixtures
  docs/                      # deploy guides (cloudflare, tailscale)
  DEPLOY.md  SECURITY.md  NOTICE.md  docs_v1.0.md
  run.ps1  scripts/install-server-task.ps1
  pyproject.toml  .env(.example)
```

There is also an earlier, lean **stdio-only prototype** in the sibling
`second-brain-mcp/` directory — read-only, the original Phase 1 proof
(search_notes/get_note over stdio). The web fork supersedes it for the full
read/write/remote app.

---

## 10. Testing

- **Extension:** `pytest` over `tests/` — 59 tests covering note parsing
  (incl. malformed-frontmatter robustness), ranking, `vault_map` (incl. payload
  caps), tool curation, `create_note`/`edit_note` (placement, templates,
  governance, idempotency, house style), `archive_chat` (distilled + raw,
  exclusion, continuation), **section + outline `get_note`** (fence-aware), the
  **Pillar 4 token benchmark** (tokenizer, payload serialization, the
  progressive-disclosure, section-fetch, outline, and compression invariants,
  source-vault immutability), and the **search-accuracy eval** (recall/MRR).
- **Benchmark:** `second-brain-bench` (or `python -m second_brain_ext.benchmark`)
  prints the token report; `--json` emits the raw numbers; `--vault <path>` runs
  it against any vault (copied to a temp dir, never mutated).
- **Search eval:** `second-brain-eval` scores whether search returns the *right*
  note (recall@k + MRR over a fixed Q&A set) — the scoreboard for ranking work.
- **Upstream:** its own suite (369 pass on Windows; 3 Windows-only perms/ripgrep
  failures are environmental, not code).
- Run: `pip install -e ".[dev]"` then `pytest`.

---

## 11. Roadmap

- **Pillar 4 — token benchmark (DONE):** `second_brain_ext/benchmark.py`
  (`second-brain-bench`) measures tokens-per-answer with a real tokenizer
  (`tiktoken`/cl100k_base, char-heuristic fallback) over a bundled corpus +
  realistic queries. It reports: the per-turn **tool-definition tax** (the curated
  6-tool surface ≈ 3.0k tok/turn), `search_notes` cost per query/per hit (median
  ≈ 145 tok/hit), `get_note` full-note cost, the **progressive-disclosure ratio**
  vs naive RAG (snippets ≈ 0.44x of loading every matched note in full — ~56%
  saved), and the `archive_chat` **compression ratio** (a transcript distills to
  ≈ 0.05x — ~95% smaller). This is the ruler the next items optimize against.
- **Token optimization vs the benchmark (mostly done):** measured each change
  before/after. Trimmed output-schema field descriptions + tool docstrings (the
  per-turn tool-definition tax dropped ~9%); dieted search snippets/summaries
  (`SNIPPET_RADIUS` 120→90, `SUMMARY_MAX` 320→240; ~8% fewer tokens/hit);
  **section-level `get_note`** (`section=`, fence-aware via `sections.py`, ~65%
  cheaper than the full note); **outline mode** (`outline=true` returns just the
  headings — ~83% cheaper, the cheapest peek into a long note; costs ~30 tok/turn
  of schema, net tax still ~2.7k); and **`vault_map` caps** (`recent`/`tags`
  bounded so the pre-write overview can't balloon on a large vault). The one
  remaining item — a `search_notes` `fields`/`limit` projection — is deliberately
  deferred: an opt-in param raises the *always-paid* per-turn schema cost to save
  tokens only when a model uses it, which works against the token-light goal.
- **Search-accuracy eval (DONE):** `eval_search.py` (`second-brain-eval`) — 10
  verifiable Q&A pairs over the bench vault, scored by recall@k + MRR, so ranking
  changes are measured, not guessed. It immediately paid for itself by surfacing a
  silent bug: a note with malformed frontmatter (an unquoted `:` in a value) was
  dropping out of the index entirely; `note.build_note` now falls back to
  body-only indexing so a note never vanishes from search. Current keyword ranking
  scores **100% recall / MRR 1.0** on the set — so per the "no embeddings until
  keyword search demonstrably misses" rule, semantic search is **not** justified
  yet; the eval is the trigger that will tell us when it is.
- **Durability finish:** run the admin auto-start script + a reboot test.
- **Later:** real section-level `get_note`, per-client tokens, daily-note capture
  re-exposed, VPS/always-on deployment docs, optional Cloudflare Access.

---

## 12. Credits

Built on **obsidian-web-mcp** by Jim Prosser (MIT) — the secure transport, OAuth,
path-safety, atomic writes, and extension seam. Our `second_brain_ext` layer adds
the token-light retrieval, opinionated write subsystem, and chat archive. See
`LICENSE` and `NOTICE.md`.
