"""Search-accuracy eval: the scoreboard for ranking quality (ROADMAP §3).

Guards two things: the harness runs and reports, and current keyword ranking
finds the right note for every question in the set. If indexing or ranking
regresses, recall drops and these fail.
"""

from pathlib import Path

import pytest

from second_brain_ext import eval_search

VAULT = Path(__file__).parent / "bench_vault"


@pytest.fixture(scope="module")
def report():
    return eval_search.run_eval(VAULT)


def test_eval_runs_and_reports(report):
    assert report["meta"]["questions"] == 10
    assert {"recall@1", "recall@3", "recall@5"} <= set(report["recall"])
    assert 0.0 <= report["mrr"] <= 1.0
    assert all(set(c) >= {"query", "expected", "rank", "top3"} for c in report["per_query"])


def test_current_ranking_finds_every_note(report):
    # Keyword search currently nails this set — so embeddings aren't justified yet
    # (per the "no semantic search until keyword visibly fails" rule).
    assert report["recall"]["recall@5"] == 1.0
    assert report["misses"] == []


def test_48laws_note_is_findable(report):
    # Direct regression for the silent-drop indexing bug: both 48-laws queries
    # must resolve to that note (it was vanishing on a frontmatter parse error).
    by_query = {c["query"]: c for c in report["per_query"]}
    assert by_query["how to conceal your intentions to gain power"]["rank"] == 1


def test_format_report_renders(report):
    text = eval_search.format_report(report)
    assert "Search Accuracy" in text and "MRR" in text
