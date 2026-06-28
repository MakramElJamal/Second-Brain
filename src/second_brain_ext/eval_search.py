"""Search-accuracy eval — the scoreboard for ranking work (ROADMAP §3 / Phase 4).

The token benchmark answers "how cheap is the answer." This answers the other
question: "did search return the RIGHT note?" Without it, tuning the ranking is
guesswork — you can't tell an improvement from a reshuffle.

It is deliberately dumb: a fixed list of realistic questions, each tagged with the
note that *should* come back, run through the same ranking the server uses. We
report, over the set:

- **recall@k** — fraction of questions whose correct note is in the top k hits.
- **MRR** — mean reciprocal rank (1/rank of the correct note; 0 if missed), so a
  correct note at position 1 scores better than one scraped in at position 5.
- a per-question table with the rank it landed at and the actual top 3.

Re-run it before/after a ranking change: the score moving up is the only proof a
change helped. Run: ``second-brain-eval`` (or ``python -m second_brain_ext.eval_search``).
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

from obsidian_vault_mcp import config

from . import ranking
from .note import build_all

DEFAULT_VAULT = Path(__file__).resolve().parents[2] / "tests" / "bench_vault"

# 10 read-only, verifiable Q&A pairs over the bundled bench vault. `expected` is
# the note that should be the top hit; a list means any of them is acceptable.
# The set is mixed on purpose: most are keyword-friendly, a couple paraphrase the
# note's idea with little word overlap to stress the ranking honestly.
EVAL_SET: list[dict] = [
    {"query": "how does the second brain mcp stay token efficient",
     "expected": "Projects/second-brain-mcp.md"},
    {"query": "what dose of creatine helps the brain and cognition",
     "expected": "Clippings/creatine-and-the-brain.md"},
    {"query": "napoleon's work ethic and discipline",
     "expected": "Areas/Historic Figures/napoleon.md"},
    {"query": "how to conceal your intentions to gain power",
     "expected": "Resources/Books/48-laws-of-power.md"},
    {"query": "fastest way to learn a new language",
     "expected": "Clippings/learning-languages.md"},
    {"query": "investor pitch deck for a seed round",
     "expected": "Projects/vpp-pitch-deck.md"},
    {"query": "how much protein should I eat to build muscle",
     "expected": "Areas/fitness.md"},
    {"query": "which supplements actually have evidence behind them",
     "expected": ["Areas/fitness.md", "Clippings/creatine-and-the-brain.md"]},
    # paraphrase, low keyword overlap with "conceal your intentions":
    {"query": "hiding your true plans from rivals until it is too late",
     "expected": "Resources/Books/48-laws-of-power.md"},
    {"query": "using comprehensible input for language acquisition",
     "expected": "Clippings/learning-languages.md"},
]


def _expected_ids(expected) -> set[str]:
    return set(expected) if isinstance(expected, (list, tuple)) else {expected}


def _rank_of(ranked_ids: list[str], expected) -> int | None:
    """1-based rank of the first acceptable note in the ranked list, or None."""
    wanted = _expected_ids(expected)
    for i, nid in enumerate(ranked_ids, start=1):
        if nid in wanted:
            return i
    return None


def run_eval(vault_path: Path, eval_set: list[dict] | None = None,
             k_values=(1, 3, 5)) -> dict:
    eval_set = eval_set or EVAL_SET
    config.VAULT_PATH = vault_path
    notes = build_all()
    depth = max(k_values)

    per_query = []
    for case in eval_set:
        hits = ranking.search(notes, case["query"], limit=depth)
        ranked_ids = [h.note.id for h in hits]
        rank = _rank_of(ranked_ids, case["expected"])
        per_query.append({
            "query": case["query"],
            "expected": case["expected"],
            "rank": rank,
            "reciprocal": round(1 / rank, 3) if rank else 0.0,
            "top3": ranked_ids[:3],
        })

    n = len(per_query)
    recall = {
        f"recall@{k}": round(sum(1 for r in per_query if r["rank"] and r["rank"] <= k) / n, 3)
        for k in k_values
    }
    return {
        "meta": {"vault": str(vault_path), "questions": n},
        "recall": recall,
        "mrr": round(statistics.mean(r["reciprocal"] for r in per_query), 3),
        "misses": [r["query"] for r in per_query if r["rank"] is None],
        "per_query": per_query,
    }


def format_report(report: dict) -> str:
    out: list[str] = []
    w = out.append
    w("=" * 64)
    w("  Second Brain MCP - Search Accuracy Eval (ROADMAP 3)")
    w("=" * 64)
    w(f"  vault     : {report['meta']['vault']}")
    w(f"  questions : {report['meta']['questions']}")
    w("")
    w("Per question (rank of the correct note; '-' = missed)")
    w("-" * 64)
    for r in report["per_query"]:
        rank = r["rank"] if r["rank"] else "-"
        flag = " " if r["rank"] == 1 else ("." if r["rank"] else "X")
        w(f"  {flag} rank={str(rank):<3} {r['query'][:50]}")
    w("")
    w("Aggregate")
    w("-" * 64)
    for k, v in report["recall"].items():
        w(f"  {k:<10} {v:>6.0%}")
    w(f"  {'MRR':<10} {report['mrr']:>6.3f}")
    if report["misses"]:
        w("")
        w(f"  Misses ({len(report['misses'])}): not in top results —")
        for q in report["misses"]:
            w(f"    - {q}")
    w("=" * 64)
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="second-brain-eval",
        description="ROADMAP 3: score whether search returns the right note.",
    )
    parser.add_argument("--vault", type=Path, default=DEFAULT_VAULT,
                        help="Vault to evaluate against (read-only).")
    parser.add_argument("--eval", type=Path, default=None,
                        help="Optional JSON file: a list of {query, expected} cases.")
    parser.add_argument("--json", action="store_true", help="Emit the raw report as JSON.")
    args = parser.parse_args(argv)

    if not args.vault.exists():
        parser.error(f"vault not found: {args.vault}")
    eval_set = None
    if args.eval:
        eval_set = json.loads(args.eval.read_text(encoding="utf-8"))

    report = run_eval(args.vault, eval_set=eval_set)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(format_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
