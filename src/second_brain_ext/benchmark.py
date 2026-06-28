"""Pillar 4 — token benchmark. Measure before optimizing.

The wedge of this server is token efficiency: it returns the *smallest useful
slice* instead of dumping whole notes into the model. That claim has been
asserted, not measured. This harness measures it.

Over a sample vault and a set of realistic queries it records, with a real
tokenizer (`tiktoken`, falling back to a char heuristic if unavailable):

- **`search_notes`** — tokens of the returned ranked snippets+summaries, per
  query, plus per-hit, with medians.
- **`get_note`** — tokens of a full-note payload, with medians; and the
  **progressive-disclosure ratio**: what a search answer costs vs. fetching the
  full text of every note it points at (the wedge, quantified).
- **`archive_chat`** — a round trip: a large raw transcript in, a compact
  distilled note out; the **compression ratio** and what that memory then costs
  to retrieve.
- **Tool definitions** — the JSON schemas of the curated tool surface, which are
  re-sent to the model *every turn*. This is the fixed per-turn tax the eight-
  tool curation already pays down; we make it a number.

Nothing here is an optimization. It is the ruler the next steps optimize against.
Run: ``second-brain-bench`` (or ``python -m second_brain_ext.benchmark``).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import statistics
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from obsidian_vault_mcp import config

from . import sections

# A bundled corpus so the benchmark runs with zero setup; override with --vault.
DEFAULT_VAULT = Path(__file__).resolve().parents[2] / "tests" / "bench_vault"

# Realistic questions a user would ask of *this* vault. Each should hit a note.
DEFAULT_QUERIES = [
    "how does the second brain mcp keep token usage low",
    "creatine dose for cognitive benefit and the brain",
    "napoleon work ethic and decisiveness",
    "law of power conceal your intentions",
    "fastest way to learn a new language",
    "pitch deck for the vpp project",
]


# --- tokenizer ----------------------------------------------------------------

def get_encoder(encoding: str = "cl100k_base") -> tuple[Callable[[str], int], str]:
    """Return ``(count_tokens, label)``. Prefer a real tokenizer; degrade safely.

    ``cl100k_base`` (GPT-4/3.5) is a widely used proxy for token cost; Claude's
    tokenizer differs slightly, so treat absolute counts as a close estimate and
    the *ratios* between tools as the durable signal.
    """
    try:
        import tiktoken

        enc = tiktoken.get_encoding(encoding)
        return (lambda s: len(enc.encode(s or ""))), f"tiktoken/{encoding}"
    except Exception:
        # ~4 chars per token is the standard rough estimate.
        return (lambda s: max(1, round(len(s or "") / 4))), "heuristic(len/4)"


# --- payload serialization ----------------------------------------------------

def _as_jsonable(obj: Any) -> Any:
    if isinstance(obj, BaseModel):
        return obj.model_dump()
    if isinstance(obj, list):
        return [_as_jsonable(o) for o in obj]
    return obj


def payload_json(obj: Any) -> str:
    """Serialize a tool's return value the way its structured content reaches the
    model — a compact JSON blob. Field values dominate the token cost, so this is
    a faithful stand-in for the wire payload."""
    return json.dumps(_as_jsonable(obj), ensure_ascii=False, default=str)


# --- harness ------------------------------------------------------------------

def _build_tools(vault: Path):
    """Point the server at ``vault`` and return ``(ext, name -> tool fn, mcp)``."""
    from mcp.server.fastmcp import FastMCP

    from .extension import SecondBrainExtension

    config.VAULT_PATH = vault
    ext = SecondBrainExtension()
    ext._rebuild_all()
    mcp = FastMCP("benchmark")
    ext.register_tools(mcp)
    fns = {t.name: t.fn for t in mcp._tool_manager.list_tools()}
    return ext, fns, mcp


def _tool_definition_cost(mcp, count: Callable[[str], int]) -> dict:
    """Tokens of the curated tool schemas — the tax re-sent to the model each turn."""
    wire_tools = asyncio.run(mcp.list_tools())
    per_tool = {
        t.name: count(t.model_dump_json(exclude_none=True)) for t in wire_tools
    }
    return {
        "tool_count": len(wire_tools),
        "per_tool": dict(sorted(per_tool.items(), key=lambda kv: -kv[1])),
        "total_tokens": sum(per_tool.values()),
    }


def _search_cost(fns, queries, count) -> dict:
    per_query = []
    for q in queries:
        hits = fns["search_notes"](query=q)
        tokens = count(payload_json(hits))
        per_query.append(
            {
                "query": q,
                "hits": len(hits),
                "tokens": tokens,
                "tokens_per_hit": round(tokens / len(hits), 1) if hits else 0,
                "hit_ids": [h.id for h in hits],
            }
        )
    with_hits = [r for r in per_query if r["hits"]]
    return {
        "per_query": per_query,
        "median_tokens": _median([r["tokens"] for r in with_hits]),
        "median_tokens_per_hit": _median([r["tokens_per_hit"] for r in with_hits]),
    }


def _get_note_cost(fns, note_ids, count) -> dict:
    per_note = []
    for nid in note_ids:
        note = fns["get_note"](id=nid)
        per_note.append({"id": nid, "tokens": count(payload_json(note))})
    per_note.sort(key=lambda r: -r["tokens"])
    return {
        "per_note": per_note,
        "median_tokens": _median([r["tokens"] for r in per_note]),
        "max_tokens": max((r["tokens"] for r in per_note), default=0),
        "section_fetch": _section_fetch(fns, per_note, count),
    }


def _section_fetch(fns, per_note, count) -> dict | None:
    """Section-level get_note vs the whole file, on the biggest multi-heading note
    — the win progressive disclosure buys inside a single long note."""
    for r in per_note:
        full = fns["get_note"](id=r["id"])
        heads = sections.outline(full.content)
        if len(heads) >= 2:
            name = heads[len(heads) // 2].lstrip("#").strip()  # a middle section
            sec = fns["get_note"](id=r["id"], section=name)
            sec_tokens = count(payload_json(sec))
            outline_tokens = count(payload_json(fns["get_note"](id=r["id"], outline=True)))
            return {
                "id": r["id"],
                "section": name,
                "headings": len(heads),
                "full_tokens": r["tokens"],
                "section_tokens": sec_tokens,
                "outline_tokens": outline_tokens,
                "ratio": round(sec_tokens / r["tokens"], 3) if r["tokens"] else None,
                "outline_ratio": round(outline_tokens / r["tokens"], 3) if r["tokens"] else None,
            }
    return None


def _vault_map_cost(fns, count) -> dict:
    """vault_map is called before writes; measure its (capped) payload."""
    vm = fns["vault_map"]()
    return {"tokens": count(payload_json(vm))}


def _progressive_disclosure(search, fns, count) -> dict:
    """The wedge, quantified, against a naive-RAG baseline.

    Apples to apples on the *same candidate set*: for each query, naive retrieval
    stuffs the full text of every matched note into context; progressive
    disclosure returns ranked snippets+summaries of those same notes and fetches a
    full note only on demand. We report the snippets-only ratio and a realistic
    "snippets + fetch the single top note in full" ratio.
    """
    full_cache: dict[str, int] = {}

    def full(nid: str) -> int:
        if nid not in full_cache:
            full_cache[nid] = count(payload_json(fns["get_note"](id=nid)))
        return full_cache[nid]

    naive = snippets = snippets_plus_top = 0
    for r in search["per_query"]:
        ids = r["hit_ids"]
        naive += sum(full(nid) for nid in ids)        # naive RAG: all hits, full text
        snippets += r["tokens"]                        # ours: snippets+summaries
        snippets_plus_top += r["tokens"] + (full(ids[0]) if ids else 0)
    return {
        "naive_full_fetch_tokens": naive,
        "progressive_snippet_tokens": snippets,
        "progressive_plus_top_note_tokens": snippets_plus_top,
        "ratio": round(snippets / naive, 3) if naive else None,
        "ratio_with_top_note": round(snippets_plus_top / naive, 3) if naive else None,
    }


# A synthetic but representative "long conversation" to archive. The point is the
# ratio of a big transcript to the tiny note it distills into.
_TRANSCRIPT_TURN = (
    "USER: Can you walk me through how we keep the MCP server token-light, and "
    "what tradeoffs we accepted along the way?\n"
    "ASSISTANT: Sure. The core idea is progressive disclosure. search_notes "
    "never returns full notes — it returns ranked snippets and a short extractive "
    "summary, and only get_note pulls a full file. We curated the tool surface "
    "from about twenty tools down to eight so the per-turn schema tax stays low, "
    "and raw chat transcripts are excluded from the index so memory is retrieved "
    "through tiny distilled notes. The tradeoff is that occasionally a snippet "
    "isn't enough and the model has to make a second call.\n"
)


def _archive_cost(fns, count) -> dict:
    transcript = _TRANSCRIPT_TURN * 40  # a few thousand tokens of "conversation"
    res = fns["archive_chat"](
        title="Token Efficiency Design Review",
        summary="Reviewed how the MCP stays token-light: progressive disclosure, "
        "an eight-tool curated surface, and raw transcripts excluded from search.",
        source="claude",
        decisions=[
            "search_notes returns snippets+summaries, never full notes",
            "curate the tool surface to eight tools",
            "exclude raw transcripts from the index",
        ],
        open_questions=["When is keyword search not enough to justify embeddings?"],
        tags=["mcp"],
        raw_transcript=transcript,
    )
    raw_tokens = count(transcript)
    distilled_get = count(payload_json(fns["get_note"](id=res.id)))
    result_tokens = count(payload_json(res))

    # What that memory costs to *find* later via search.
    hits = fns["search_notes"](query="token efficiency design review progressive disclosure")
    distilled_search = count(payload_json(hits)) if hits else 0

    return {
        "raw_transcript_tokens": raw_tokens,
        "distilled_note_tokens": distilled_get,
        "distilled_search_tokens": distilled_search,
        "archive_result_tokens": result_tokens,
        "compression_ratio": round(distilled_get / raw_tokens, 4) if raw_tokens else None,
        "distilled_id": res.id,
        "raw_id": res.raw_id,
    }


def _median(xs) -> float:
    return round(statistics.median(xs), 1) if xs else 0.0


def run_benchmark(
    vault_path: Path,
    queries: list[str] | None = None,
    encoding: str = "cl100k_base",
) -> dict:
    """Run the full benchmark against a *copy* of ``vault_path`` (archive_chat
    writes), returning a report dict. The source vault is never mutated."""
    queries = queries or DEFAULT_QUERIES
    count, tokenizer_label = get_encoder(encoding)

    with tempfile.TemporaryDirectory(prefix="sb-bench-") as tmp:
        work = Path(tmp) / "vault"
        shutil.copytree(vault_path, work)
        ext, fns, mcp = _build_tools(work)

        note_ids = sorted(n.id for n in ext._snapshot())
        tool_defs = _tool_definition_cost(mcp, count)
        search = _search_cost(fns, queries, count)
        get_note = _get_note_cost(fns, note_ids, count)
        get_note["progressive_disclosure"] = _progressive_disclosure(search, fns, count)
        vault_map = _vault_map_cost(fns, count)
        archive = _archive_cost(fns, count)

    return {
        "meta": {
            "tokenizer": tokenizer_label,
            "vault": str(vault_path),
            "note_count": len(note_ids),
            "query_count": len(queries),
        },
        "tool_definitions": tool_defs,
        "search_notes": search,
        "get_note": get_note,
        "vault_map": vault_map,
        "archive_chat": archive,
    }


# --- reporting ----------------------------------------------------------------

def format_report(report: dict) -> str:
    m = report["meta"]
    td = report["tool_definitions"]
    sn = report["search_notes"]
    gn = report["get_note"]
    pd = gn["progressive_disclosure"]
    ar = report["archive_chat"]
    out: list[str] = []
    w = out.append

    w("=" * 64)
    w("  Second Brain MCP - Token Benchmark (Pillar 4)")
    w("=" * 64)
    w(f"  tokenizer : {m['tokenizer']}")
    w(f"  vault     : {m['vault']}")
    w(f"  corpus    : {m['note_count']} notes, {m['query_count']} queries")
    w("")

    w("Tool-definition tax (re-sent EVERY turn)")
    w("-" * 64)
    for name, tok in td["per_tool"].items():
        w(f"  {name:<26} {tok:>6} tok")
    w(f"  {'TOTAL (' + str(td['tool_count']) + ' tools)':<26} {td['total_tokens']:>6} tok / turn")
    w("")

    w("search_notes (ranked snippets + summaries)")
    w("-" * 64)
    for r in sn["per_query"]:
        w(f"  [{r['tokens']:>5} tok | {r['hits']} hit(s)] {r['query'][:42]}")
    w(f"  median per answer : {sn['median_tokens']} tok")
    w(f"  median per hit    : {sn['median_tokens_per_hit']} tok")
    w("")

    w("get_note (full note payload)")
    w("-" * 64)
    w(f"  median : {gn['median_tokens']} tok   max : {gn['max_tokens']} tok")
    sf = gn.get("section_fetch")
    if sf:
        w(f"  section fetch: '{sf['section']}' of a {sf['headings']}-heading note "
          f"= {sf['section_tokens']} tok vs {sf['full_tokens']} full "
          f"({sf['ratio']}x, {round((1 - sf['ratio']) * 100)}% saved)")
        w(f"  outline only : {sf['outline_tokens']} tok vs {sf['full_tokens']} full "
          f"({sf['outline_ratio']}x, {round((1 - sf['outline_ratio']) * 100)}% saved)")
    w("  progressive disclosure vs naive RAG (same candidate notes):")
    w(f"    naive (all hits, full text) : {pd['naive_full_fetch_tokens']} tok")
    w(f"    snippets only               : {pd['progressive_snippet_tokens']} tok")
    w(f"    snippets + top note in full : {pd['progressive_plus_top_note_tokens']} tok")
    if pd["ratio"] is not None:
        w(f"    => snippets are {pd['ratio']}x of naive "
          f"({round((1 - pd['ratio']) * 100)}% saved); "
          f"with the top note fetched, {pd['ratio_with_top_note']}x "
          f"({round((1 - pd['ratio_with_top_note']) * 100)}% saved)")
    w("")

    w(f"vault_map (pre-write overview): {report['vault_map']['tokens']} tok")
    w("")

    w("archive_chat (cross-LLM memory round trip)")
    w("-" * 64)
    w(f"  raw transcript     : {ar['raw_transcript_tokens']} tok")
    w(f"  distilled note     : {ar['distilled_note_tokens']} tok (via get_note)")
    w(f"  found via search   : {ar['distilled_search_tokens']} tok")
    if ar["compression_ratio"] is not None:
        w(f"  => distilled to {ar['compression_ratio']}x of the transcript "
          f"({round((1 - ar['compression_ratio']) * 100)}% smaller)")
    w("=" * 64)
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="second-brain-bench",
        description="Pillar 4: measure tokens-per-answer for the MCP tools.",
    )
    parser.add_argument(
        "--vault", type=Path, default=DEFAULT_VAULT,
        help="Vault to benchmark against (copied to a temp dir; never mutated).",
    )
    parser.add_argument(
        "--queries", type=Path, default=None,
        help="Optional file of queries, one per line (defaults to a built-in set).",
    )
    parser.add_argument("--encoding", default="cl100k_base", help="tiktoken encoding name.")
    parser.add_argument("--json", action="store_true", help="Emit the raw report as JSON.")
    args = parser.parse_args(argv)

    if not args.vault.exists():
        parser.error(f"vault not found: {args.vault}")
    queries = None
    if args.queries:
        queries = [ln.strip() for ln in args.queries.read_text(encoding="utf-8").splitlines() if ln.strip()]

    report = run_benchmark(args.vault, queries=queries, encoding=args.encoding)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(format_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
