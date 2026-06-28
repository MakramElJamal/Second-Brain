"""Pillar 1 tests: vault_map content + tool curation (allowlist pruning)."""

from pathlib import Path

import pytest
from mcp.server.fastmcp import FastMCP

from obsidian_vault_mcp import config
from second_brain_ext import extension as ext_mod
from second_brain_ext.extension import ALLOWLIST, SecondBrainExtension

SAMPLE = Path(__file__).parent / "sb_sample_vault"


@pytest.fixture(autouse=True)
def _point_config_at_sample(monkeypatch):
    monkeypatch.setattr(config, "VAULT_PATH", SAMPLE)


# --- vault_map ----------------------------------------------------------

def _map():
    ext = SecondBrainExtension()
    ext._rebuild_all()
    return ext._vault_map()


def test_vault_map_counts_buckets():
    m = _map()
    assert m.total_notes == 3  # strategy, creatine, project (meta + hidden excluded)
    assert m.buckets.get("Projects") == 1
    assert m.buckets.get("Resources") == 1
    assert m.buckets.get("Clippings") == 1


def test_vault_map_lists_active_projects_with_status():
    m = _map()
    titles = {(p.title, p.status) for p in m.active_projects}
    assert ("Launch the App", "active") in titles


def test_vault_map_returns_tag_vocabulary():
    m = _map()
    assert "strategy" in m.tags and "projects" in m.tags


def test_vault_map_exposes_folder_tree():
    m = _map()
    # folders the model should file INTO, with counts (nested paths included)
    assert m.folders.get("Resources/Books") == 1
    assert "Clippings" in m.folders


def test_vault_map_recent_is_populated_and_bodyless():
    m = _map()
    assert m.recent and all(r.id and r.title for r in m.recent)
    # NoteRef carries no body field — vault_map stays token-light.
    assert not any(hasattr(r, "body") for r in m.recent)


def test_vault_map_recent_is_capped(monkeypatch):
    # Even if a caller asks for a huge recent list, the payload stays bounded.
    monkeypatch.setattr(ext_mod, "MAX_RECENT", 2)
    ext = SecondBrainExtension()
    ext._rebuild_all()
    assert len(ext._vault_map(recent_limit=1000).recent) == 2


def test_vault_map_tags_are_capped(monkeypatch):
    monkeypatch.setattr(ext_mod, "MAX_TAGS", 1)
    ext = SecondBrainExtension()
    ext._rebuild_all()
    assert len(ext._vault_map().tags) <= 1


# --- tool curation ------------------------------------------------------

def _dummy(name):
    def fn(path: str = "") -> str:
        """dummy upstream tool"""
        return name
    fn.__name__ = name
    return fn


def test_tool_curation_prunes_to_allowlist():
    ext = SecondBrainExtension()
    ext._rebuild_all()
    mcp = FastMCP("test")
    # Simulate upstream tools registered before our extension runs.
    for nm in ["vault_read", "vault_delete", "vault_canvas_read",
               "vault_move", "vault_search_frontmatter", "vault_write"]:
        mcp.add_tool(_dummy(nm), name=nm)

    ext.register_tools(mcp)
    names = {t.name for t in mcp._tool_manager.list_tools()}

    # our tools present
    assert {"search_notes", "get_note", "vault_map"} <= names
    # replaced / house-rule -> pruned
    assert "vault_read" not in names
    assert "vault_delete" not in names
    assert "vault_canvas_read" not in names
    # deliberately kept extras
    assert "vault_move" in names
    assert "vault_search_frontmatter" in names
    # raw write tools are pruned (replaced by create_note/edit_note)
    assert "vault_write" not in names
    # nothing outside the allowlist survives
    assert names <= ALLOWLIST
