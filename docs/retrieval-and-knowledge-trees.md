# Retrieval and knowledge trees

How search finds the right note, what a "knowledge tree" is, how this codebase
uses one, what measurements against a real vault showed, and where the field is
heading. Written 2026-10-28.

---

## 1. What a knowledge tree is

A knowledge tree is a hierarchy of nodes at increasing levels of abstraction:
leaves hold the detail, and each internal node summarizes the nodes beneath it.
Its point in retrieval is that **questions come at different levels**:

| Question | Right level |
|---|---|
| "What photocurrent did run 2 give at 0.6 V?" | a leaf (one day's log) |
| "What did I do the week of 10-16 August?" | an internal node (the week) |
| "What did I do in August?" | a higher node (the month) |
| "What do I know about agent memory competitors?" | a synthesis node |

Flat retrieval (rank every chunk, return the top k) is good at the first row and
bad at the rest. It returns one arbitrary day for "what did I do in August",
because no single leaf is *about* August.

**RAPTOR** (Sarthi et al., Stanford, ICLR 2024) is the reference method. It
embeds chunks, clusters them, has an LLM write a summary of each cluster, and
repeats until it has a tree. At query time the best variant ("collapsed tree")
puts *every* node, leaves and summaries alike, into one pool and ranks them
together, so broad questions match summaries and detailed questions match leaves.

**A PARA / Obsidian vault already is a knowledge tree, written by hand:**

```
Areas/                                   bucket
└── Lab-Internship/                      area           README.md            <- hub
    └── engineering-logs/
        ├── August 2026/                 month          00 - August 2026 Index.md  <- hub
        │   ├── 3-9August/               week           00 - Index.md        <- hub
        │   │   ├── 01 - 4 August 2026 - ....md         leaf
        │   │   └── 02 - 6 August 2026 - ....md         leaf
        │   └── 10-16August/ ...
        └── October 2026/ ...
Projects/second-brain-mcp/
    ├── second-brain-mcp.md                             <- hub (folder note)
    └── business/competitor analysis/
        ├── Agent Memory Landscape - Synthesis.md       <- hub (links down into subfolders)
        ├── zep/ mem0/ letta/ ...                       leaves
```

The index, README, map and synthesis notes are the internal nodes. RAPTOR spends
LLM calls to *generate* that layer; here it already exists, written by the person
who knows what matters. Recent work suggests the generated summaries were never
the essential part: the structure is (see §5).

---

## 2. How this codebase uses it (`src/second_brain_ext/ranking.py`)

Three deterministic layers. No model calls, no new dependencies.

**BM25F lexical score.** Each query term is weighted by IDF (how rare it is in the
vault) and by the best field it appears in: title 5, tags 3, folder path 2,
summary 1.5, body 1. Term frequency saturates (k1 = 1.2) and body counts are
length-normalized (b = 0.75). Before this, every term counted equally, so "2026"
and "October" (in hundreds of notes) weighed as much as "dichroic" (in three).
Two query terms adjacent in both query and title ("10 August") add a phrase
bonus. A small stemmer folds plurals and -ed/-ing ("tripped" -> "trip"), and the
tokenizer splits letters from digits ("19-23October" -> 19, 23, october).

**The folder path is a field.** A note inherits its ancestors' words:
`competitor analysis/zep/Zep - Business Overview.md` matches "competitor". This
is the vault's version of Anthropic's *contextual retrieval* (prepend a chunk's
document context before indexing it). The context is already in where the note
was filed.

**Hub promotion (the tree).** A note is a hub of its folder if it is named like
one (`index`, `readme`, `moc`, `map`, `… Index`, `00 - Index`, or a folder note
`x/x.md`), or if it links to at least 3 notes filed in subfolders beneath it (this
catches a synthesis note). A hub's score is lifted by the mean of its best 3
**leaf** descendants:

```
final(hub) = own(hub) + λ · mean(top-3 leaf scores beneath it)
λ = 0.9 when the query asks for a level ("overview", "everything", "summary",
        "all", "week", "month", ...), else 0.1
```

Four details carry most of the accuracy, each found by a failing eval case:

1. **Only leaves count as evidence.** Otherwise a month index rides the score of
   the week index beneath it and wins "the first week of August".
2. **A hub is indexed without its wikilink list.** A hub's body repeats every
   child's title; scoring those words as its own content counts the subtree twice
   and lets the week index beat the day the question names.
3. **"Overview" is intent, not content.** Matched literally, it ranks every
   "X - Business Overview" note above the synthesis the user wanted.
4. **A hub must match the query itself** before its subtree can lift it.

Indexing is incremental: per-note analysis is cached by object identity, so after
one edit only that note is re-tokenized. On a synthetic 2,900-note vault: cold
build ~2.5 s once, rebuild after an edit ~0.25 s, query ~20 ms (the previous
ranker re-tokenized the whole vault on every query: ~0.6 s).

### Measured effect

`tests/tree_vault` is a synthetic 37-note vault shaped like a real one (month ->
week -> day logs with index hubs, a research and competitor tree, and the
confusers real vaults have: per-competitor "Business Overview" notes, same-day
status notes, long roll-up documents). Run it with:

```
python -m second_brain_ext.eval_search --vault tests/tree_vault --eval tests/tree_eval.json
```

| Set | Before (recall@1 / MRR) | After |
|---|---|---|
| `tree_eval.json` (24 q, used for tuning) | 88% / 0.931 | 100% / 1.000 |
| `tree_eval_holdout.json` (14 q, written after tuning) | 100% / 1.000 | 100% / 1.000 |
| `bench_vault` (original 10 q) | 100% / 1.000 | 100% / 1.000 |

By question type on the tuning set: broad 86% -> 100%, date 75% -> 100%,
paraphrase 80% -> 100%, specific 100% -> 100%.

Caveats: the vault and questions are synthetic and small, and the weights were
tuned on the first set. One held-out failure (a month hub beating a week hub)
also drove the leaf-only-evidence fix, so the held-out set is no longer pristine.
The real test is a gold set over the real vault (§6).

---

## 3. What the live server's `recall` showed

The hosted server's code is not in this repository. Its `recall` tool was probed
read-only against a real ~700-note vault with questions whose correct note is
unambiguous (its title contains the key words). Each query also ran through the
same server's `search_notes`, which is just the keyword rung `recall` builds on.

| | keyword rung only | fused `recall` (the default tool) |
|---|---|---|
| correct note ranked #1 | 6 of 9 | **0 of 9** |
| MRR | ~0.75 | **~0.19** |

Small sample and biased toward keyword-friendly questions, but the direction is
unambiguous: **the fusion step is discarding correct keyword hits.** In several
cases a note whose title contained every query word was missing from the top 5
entirely, yet appeared in the `related` list of the wrong top hit.

Symptoms and the likely cause of each (to be confirmed in the server code):

1. **Rank fusion out-votes a confident lexical winner.** The project's design notes
   specify reciprocal rank fusion (RRF, k = 60). RRF ignores score margins: a note
   ranked #1 by keyword search but absent from the semantic list scores
   1/61 ≈ 0.016, while a note ranked #5 by both lists scores 2/65 ≈ 0.031. Agreement
   between mediocre lists beats one confident list. Fixes, cheapest first:
   - **Anchor rule:** if the keyword rung's #1 has a clear margin over its #2, or
     covers most of the query's IDF mass in its title, pin it first.
   - **Weighted, score-aware fusion:** a convex combination of per-retriever
     normalized scores. Bruch, Gai & Ingber ("An Analysis of Fusion Functions for
     Hybrid Retrieval", ACM TOIS 2023) found it beats RRF and needs only a handful
     of labeled queries to tune.
   - Weight the keyword list above the semantic one for short queries.
2. **Long notes win through one section.** Winning snippets were often a single
   heading ("Main engineering conclusions", "PART 4 - RESULTS"). This is consistent
   with chunk-level scoring max-pooled to the note: a long note gets many draws
   and generic sections ("Results", "Conclusions") match many questions. Fixes:
   prepend the note title and folder path to every chunk before embedding
   (contextual chunk headers), aggregate chunk scores to the note with a mean of
   the top 2-3 chunks rather than the max, and length-normalize as BM25 does.
3. **The exact-title rung is too strict.** It fires only on exact equality, so
   "dichroic filter angle in water" does not trigger it for a title that contains
   all four words. Make it fuzzy: fire when the title covers most of the query's
   IDF mass.
4. **Spreadsheets leak into every result.** The same one or two workbooks are
   appended to almost every query, including unrelated ones, at scores 10-20x
   below the top note. Give them a relevance floor (e.g. at least half the top
   note's score), or return them only when the query has numeric/tabular intent.
5. **Broad questions miss the summary node in both rungs**, the gap §2's hub
   promotion closes.

---

## 4. Where this sits relative to other approaches

| Approach | Tree built by | Query time | Fit for a personal vault |
|---|---|---|---|
| Flat chunk RAG | nothing | rank chunks | weak on broad questions |
| RAPTOR (2024) | LLM cluster summaries | rank all nodes together | good, but costs LLM calls and re-summarizing on change |
| GraphRAG (Microsoft, 2024) | LLM entity graph + community summaries | map-reduce over communities | strong on corpus-wide questions, very expensive indexing |
| LazyGraphRAG | defers graph work to query time | per query | much cheaper indexing than GraphRAG |
| HippoRAG 2 (2025) | LLM triples + passage graph | Personalized PageRank | strong multi-hop; needs a well-connected graph |
| PageIndex | heuristic table-of-contents tree, LLM node summaries | LLM reasons down the tree | no vectors; self-reported 98.7% on FinanceBench |
| **This vault** | **the human: folders + index notes + wikilinks** | **BM25F + hub lift; graph hop via links** | **free, current, already curated** |

The vault's advantage is that its tree and graph are authored, not inferred, so
there is no extraction error and no rebuild cost.

---

## 5. State of the art and where it is moving (as of late 2026)

Most of what follows comes from 2026 preprints and vendor material found through
search; the arXiv pages themselves could not be opened from this environment.
Treat numbers as self-reported unless noted.

**Tree retrieval is getting cheaper, not smarter.** The 2026 RAPTOR follow-ups
mostly remove the LLM from tree construction:
- *SproutRAG* (arXiv 2606.18381, EMNLP 2026 Findings): binary tree over sentences
  from LM attention, hierarchical beam search, no LLM calls at inference.
- *SVD-RAG* (arXiv 2607.10316): SVD-based extractive summaries instead of LLM
  summaries; within 1-5% of RAPTOR, ~317x faster to build.
- *NavTree* (arXiv 2610.06902): deterministic tree, no LLM summaries; beats a
  re-implemented RAPTOR at matched cost.
- *VecTree-RAG* (arXiv 2607.23006): vectors to find documents, tree navigation
  inside them.

Reading: the structure matters more than the generated prose. That favors a vault
whose structure is hand-built.

**Agentic search: let the model walk the tree.** Coding agents (Claude Code,
Cursor and others) dropped vector indexes for tools the model calls: grep, read,
list. *Is Grep All You Need?* (arXiv 2605.15184) ran LongMemEval questions with a
grep tool and a vector tool in the same agents: grep generally scored higher, and
**changing the agent harness moved accuracy more than changing the retriever**.
The result is conditional (vector search won some configurations), but the
direction is clear: retrieval is becoming a *navigation tool surface* (search,
then outline, then section, then neighbors) more than a single ranked list.
PageIndex is this idea applied to documents.

**Agent memory has converged; its benchmarks have not.** Mem0, Zep/Graphiti,
Letta, AWS AgentCore and others share one architecture: extract, consolidate with
supersession, hybrid retrieval, a background consolidation pass. Top systems
self-report 85-95% on LongMemEval, but a 2026 audit (arXiv 2607.21962) found about
6% of LoCoMo answer keys wrong and an LLM judge that accepts many deliberately
wrong answers. Independent re-runs of vendor systems often land far lower. The
practical lesson is to trust **your own gold set** over leaderboards.

**Temporal validity is now table stakes.** Zep-style bi-temporal facts (valid from
/ invalid at) and "current truth first, point-in-time on request" are standard.
The live server already ranks superseded notes down and accepts `as_of`.

**Background compute (sleep-time).** Letta's sleep-time agents and Cognee's
"memify" run consolidation off the request path. For a tree this means
maintaining hubs: drafting an index for a folder that has none, refreshing a
month index when its weeks change, proposing links. The project's "Alfred" design
is this idea.

---

## 6. Next steps, in order

1. **Build a real gold set (the blocker for everything else).** 30-60 questions
   over the real vault with their correct note ids, split by type (specific, date,
   broad, paraphrase, temporal). Keep it private: it names private notes. Run it
   against this ranker (`eval_search --vault <vault> --eval <gold.json>`) and,
   via a small MCP client, against the live `recall`. Every later change reports
   a delta on it.
2. **Fix fusion on the server** (§3.1-3.3). Expected to be the largest single gain,
   since the keyword rung already beats the fused output.
3. **Port this ranker as the server's keyword rung.** `ranking.py` is
   self-contained (stdlib only) and works on any list of notes.
4. **Add the spreadsheet relevance floor** (§3.4). A token saving on almost
   every call.
5. **Expose the tree to the model.** Add a `browse(folder)` tool, or extend
   `recall` to return a hit's breadcrumb (`Areas › Lab › logs › August › 10-16`)
   and its hub, so the model can move up or down a level itself, the agentic
   pattern from §5.
6. **Background hub maintenance.** Detect folders with more than N notes and no
   hub, and queue a drafted index for approval: RAPTOR's summary layer, but
   written once, reviewed, and kept as a normal note.

---

## References

- Sarthi et al., *RAPTOR: Recursive Abstractive Processing for Tree-Organized
  Retrieval*, ICLR 2024 (arXiv 2401.18059).
- Edge et al., *From Local to Global: A Graph RAG Approach to Query-Focused
  Summarization*, Microsoft Research 2024 (arXiv 2404.16130).
- Gutiérrez et al., *HippoRAG* (NeurIPS 2024) and *From RAG to Memory: Non-
  Parametric Continual Learning for LLMs* (HippoRAG 2, 2025).
- Anthropic, *Introducing Contextual Retrieval*, September 2024.
- Bruch, Gai & Ingber, *An Analysis of Fusion Functions for Hybrid Retrieval*,
  ACM TOIS 2023.
- Rasmussen et al., *Zep: A Temporal Knowledge Graph Architecture for Agent
  Memory*, 2025 (arXiv 2501.13956).
- Chhikara et al., *Mem0: Building Production-Ready AI Agents with Scalable
  Long-Term Memory*, 2025 (arXiv 2504.19413).
- Wu et al., *LongMemEval*, ICLR 2025.
- 2026 preprints: SproutRAG (2606.18381), SVD-RAG (2607.10316), NavTree
  (2610.06902), VecTree-RAG (2607.23006), *Is Grep All You Need?* (2605.15184),
  memory-benchmark audit (2607.21962).
- PageIndex (VectifyAI), https://pypi.org/project/PageIndex/
