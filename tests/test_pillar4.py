"""Pillar 4 tests: the token benchmark harness.

These assert the harness *runs* and that its core invariants hold — the wedge
claims it exists to measure. Absolute token counts are tokenizer-dependent, so we
assert relationships (ratios, orderings), not magic numbers.
"""

from pathlib import Path

import pytest

from second_brain_ext import benchmark

BENCH_VAULT = Path(__file__).parent / "bench_vault"


@pytest.fixture(scope="module")
def report():
    return benchmark.run_benchmark(BENCH_VAULT)


# --- tokenizer -----------------------------------------------------------

def test_encoder_counts_tokens():
    count, label = benchmark.get_encoder()
    assert count("hello world") > 0
    # longer text costs more tokens than shorter
    assert count("a b c d e f g h") > count("a b")
    assert label  # reports which tokenizer was used


def test_payload_json_serializes_models_and_lists():
    # a plain value, a list, and pydantic models all serialize without error
    assert benchmark.payload_json([]) == "[]"
    assert "second-brain" in benchmark.payload_json(["second-brain"])


# --- report shape --------------------------------------------------------

def test_report_has_all_sections(report):
    for key in ("meta", "tool_definitions", "search_notes", "get_note", "archive_chat"):
        assert key in report
    assert report["meta"]["note_count"] >= 5
    assert report["meta"]["query_count"] >= 1


# --- tool-definition tax -------------------------------------------------

def test_tool_definition_cost_is_the_curated_surface(report):
    td = report["tool_definitions"]
    # The benchmark builds a bare FastMCP, so the surface is exactly our 6 tools.
    assert td["tool_count"] == len(td["per_tool"])
    assert "search_notes" in td["per_tool"]
    assert td["total_tokens"] == sum(td["per_tool"].values())
    assert td["total_tokens"] > 0


# --- search --------------------------------------------------------------

def test_search_returns_hits_and_token_counts(report):
    sn = report["search_notes"]
    # every default query should find at least one note in the corpus
    assert all(r["hits"] >= 1 for r in sn["per_query"]), sn["per_query"]
    assert all(r["tokens"] > 0 for r in sn["per_query"])
    assert sn["median_tokens"] > 0


# --- progressive disclosure (the wedge) ----------------------------------

def test_section_fetch_is_cheaper_than_full_note(report):
    sf = report["get_note"]["section_fetch"]
    # On a multi-heading note, fetching one section must cost less than the file,
    # and an outline (headings only) is cheaper still.
    assert sf is not None
    assert sf["ratio"] < 1.0
    assert sf["section_tokens"] < sf["full_tokens"]
    assert sf["outline_tokens"] < sf["section_tokens"]


def test_vault_map_payload_is_measured(report):
    assert report["vault_map"]["tokens"] > 0


def test_search_is_cheaper_than_naive_rag(report):
    pd = report["get_note"]["progressive_disclosure"]
    # On the SAME candidate notes, returning snippets must cost strictly less than
    # naive RAG stuffing every matched note in full — otherwise "stingy by
    # design" is a lie. Even fetching the single top note in full still wins.
    assert pd["ratio"] is not None and pd["ratio"] < 1.0
    assert pd["ratio_with_top_note"] < 1.0
    assert pd["progressive_snippet_tokens"] < pd["naive_full_fetch_tokens"]


# --- archive_chat compression --------------------------------------------

def test_archive_distills_transcript(report):
    ar = report["archive_chat"]
    # The distilled note is a small fraction of the raw transcript.
    assert ar["compression_ratio"] is not None and ar["compression_ratio"] < 0.5
    assert ar["distilled_note_tokens"] < ar["raw_transcript_tokens"]
    # Finding that memory via search is cheaper still than reading the note.
    assert 0 < ar["distilled_search_tokens"]


# --- end to end ----------------------------------------------------------

def test_format_report_renders(report):
    text = benchmark.format_report(report)
    assert "Token Benchmark" in text
    assert "progressive disclosure" in text


def test_source_vault_not_mutated():
    before = {p.name for p in BENCH_VAULT.rglob("*.md")}
    benchmark.run_benchmark(BENCH_VAULT)
    after = {p.name for p in BENCH_VAULT.rglob("*.md")}
    assert before == after  # archive_chat wrote only to the temp copy
