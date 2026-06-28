"""Tests for the token-light extension layer (second_brain_ext)."""

from pathlib import Path

import pytest

from obsidian_vault_mcp import config
from second_brain_ext import ranking
from second_brain_ext.note import build_all
from second_brain_ext.extension import SecondBrainExtension

SAMPLE = Path(__file__).parent / "sb_sample_vault"


@pytest.fixture(autouse=True)
def _point_config_at_sample(monkeypatch):
    monkeypatch.setattr(config, "VAULT_PATH", SAMPLE)


def test_excludes_meta_and_hidden():
    ids = {n.id for n in build_all()}
    assert "_index.md" not in ids
    assert all(not i.startswith(".") for i in ids)


def test_indexes_content_notes():
    assert len(build_all()) == 3  # strategy, creatine, project (meta + hidden excluded)


def test_title_and_summary_extraction():
    notes = {n.id: n for n in build_all()}
    strat = notes["Resources/Books/example-strategy.md"]
    assert strat.title == "Concentrate Your Forces"  # from H1
    assert "Intensity defeats dispersion" in strat.summary  # from callout
    clip = notes["Clippings/creatine-and-the-brain.md"]
    assert clip.title.startswith("Creatine and the Brain")  # from frontmatter
    assert "brain energy metabolism" in clip.summary  # from description


def test_ranking_finds_relevant_note_first():
    notes = build_all()
    hits = ranking.search(notes, "what do my notes say about creatine and the brain")
    assert hits and hits[0].note.id == "Clippings/creatine-and-the-brain.md"


def test_bucket_filter():
    notes = build_all()
    hits = ranking.search(notes, "focus strategy", bucket="Resources")
    assert hits and all(h.note.bucket == "Resources" for h in hits)


def test_extension_change_listener_updates_index():
    ext = SecondBrainExtension()
    ext._rebuild_all()
    assert ext._get("Clippings/creatine-and-the-brain.md") is not None
    # Simulate deletion event from the upstream frontmatter index.
    abs_path = str(SAMPLE / "Clippings" / "creatine-and-the-brain.md")
    ext._on_change(abs_path, exists=False)
    assert ext._get("Clippings/creatine-and-the-brain.md") is None
