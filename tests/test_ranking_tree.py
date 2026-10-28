"""Ranking behaviors behind the knowledge-tree eval (tests/tree_vault).

Each test pins one mechanism, so a change that breaks it fails here by name
rather than only as a dip in the aggregate eval score.
"""

import dataclasses
import json
from pathlib import Path

import pytest

from obsidian_vault_mcp import config
from second_brain_ext import eval_search, ranking
from second_brain_ext.note import build_all

TREE = Path(__file__).parent / "tree_vault"
LOGS = "Areas/Lab-Internship/engineering-logs"
CA = "Projects/second-brain-mcp/business/competitor analysis"


@pytest.fixture(scope="module")
def notes():
    saved = config.VAULT_PATH
    config.VAULT_PATH = TREE
    try:
        yield build_all()
    finally:
        config.VAULT_PATH = saved


def top(notes, query, **kw):
    hits = ranking.search(notes, query, **kw)
    return hits[0].note.id if hits else None


# -- tokenizer ----------------------------------------------------------------

def test_tokenizer_splits_letters_from_digits():
    assert ranking.tokenize("19-23October") == ["19", "23", "october"]
    assert ranking.tokenize("Run2 v0.4.11") == ["run", "2", "v", "0", "4", "11"]


def test_tokenizer_folds_plurals_and_verb_endings():
    assert ranking.tokenize("experiments competitors studies") == ["experiment", "competitor", "study"]
    assert ranking.tokenize("tripped running worked") == ["trip", "run", "work"]
    # guarded cases: no vowel left, or -ss/-us/-is endings
    assert ranking.tokenize("string analysis status class") == ["string", "analysis", "status", "class"]


def test_broad_cues_are_intent_not_content():
    assert ranking.is_broad("overview of agent memory")
    assert ranking.is_broad("the first week of August")
    assert not ranking.is_broad("dichroic filter angle")
    assert "overview" not in ranking.query_terms("overview of agent memory")
    assert "week" in ranking.query_terms("the first week of August")  # level cue stays a term


# -- the tree -------------------------------------------------------------------

def test_hub_detection(notes):
    index = ranking._index_for(notes)
    hubs = {index.notes[i].id for i in index.hubs}
    assert f"{LOGS}/August 2026/00 - August 2026 Index.md" in hubs  # "... Index"
    assert f"{LOGS}/August 2026/10-16August/00 - Index.md" in hubs  # "00 - Index"
    assert "Areas/Lab-Internship/README.md" in hubs
    assert f"{CA}/Competitor Analysis - Map.md" in hubs
    assert "Projects/second-brain-mcp/second-brain-mcp.md" in hubs  # folder note
    # not named like an index, but links down into zep/, mem0/, letta/
    assert f"{CA}/Agent Memory Landscape - Synthesis.md" in hubs
    # a leaf that cross-links its siblings is still a leaf
    assert f"{LOGS}/August 2026/10-16August/02 - 12 August 2026 - Photocurrent U-I Curve Run 1.md" not in hubs


def test_broad_query_lands_on_hub_specific_on_leaf(notes):
    assert top(notes, "what did I do in August at the lab") == f"{LOGS}/August 2026/00 - August 2026 Index.md"
    assert top(notes, "potential-held method photocurrent result").endswith("Potential-Held Method.md")


def test_overview_does_not_match_business_overview_titles(notes):
    assert top(notes, "overview of everything I know about agent memory competitors") in {
        f"{CA}/Agent Memory Landscape - Synthesis.md",
        f"{CA}/Competitor Analysis - Map.md",
    }


def test_week_hub_beats_month_hub_for_a_week_question(notes):
    # month index must not ride the week index's score (leaf-only evidence)
    assert top(notes, "what happened in the first week of August") == f"{LOGS}/August 2026/3-9August/00 - Index.md"


def test_title_phrase_beats_folder_range(notes):
    # "10" is in the "10-16August" folder of every note that week; only the
    # leaf has "10 August" as a phrase in its title.
    assert top(notes, "what happened on 10 August").endswith("01 - 10 August 2026 - Solar Reactor Test 45.md")


def test_hubs_are_not_scored_on_their_link_lists(notes):
    # the week index lists this note's full title as a wikilink; it must not win
    assert top(notes, "solar reactor test 45").endswith("Solar Reactor Test 45.md")


def test_stemming_matches_inflected_body_words(notes):
    assert top(notes, "why did the reactor pump trip").endswith("Solar Reactor Test 45.md")


def test_filters_still_apply(notes):
    hits = ranking.search(notes, "agent memory", bucket="Areas")
    assert all(h.note.bucket == "Areas" for h in hits)


def test_snippet_finds_words_as_typed(notes):
    hits = ranking.search(notes, "studies of electrode degradation")
    assert hits and all(isinstance(h.snippet, str) for h in hits)
    hit = ranking.search(notes, "pump tripped")[0]
    assert "tripped" in hit.snippet


# -- index cache ----------------------------------------------------------------

def test_index_reused_for_same_snapshot_and_rebuilt_on_change(notes):
    first = ranking._index_for(list(notes))
    assert ranking._index_for(list(notes)) is first  # new list, same Note objects
    changed = list(notes)
    changed[0] = dataclasses.replace(notes[0], body=notes[0].body + " zyxwvut")
    rebuilt = ranking._index_for(changed)
    assert rebuilt is not first
    assert top(changed, "zyxwvut") == notes[0].id


# -- eval scoreboard --------------------------------------------------------------

@pytest.mark.parametrize("eval_file", ["tree_eval.json", "tree_eval_holdout.json"])
def test_tree_eval_scores(eval_file):
    cases = json.loads((Path(__file__).parent / eval_file).read_text(encoding="utf-8"))
    report = eval_search.run_eval(TREE, cases)
    assert report["recall"]["recall@1"] == 1.0, report["misses"] or [
        (r["query"], r["rank"]) for r in report["per_query"] if r["rank"] != 1
    ]
