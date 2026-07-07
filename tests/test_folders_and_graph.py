"""create_folder, related_notes (wikilink graph), and the folder-move
staleness fix: a moved DIRECTORY produces no per-file watcher events, so the
extension listens on the write-event seam and rebuilds both indexes.
"""

import json

import pytest
from mcp.server.fastmcp import FastMCP

from obsidian_vault_mcp import config, write_events
from obsidian_vault_mcp.frontmatter_index import FrontmatterIndex
from obsidian_vault_mcp.tools.manage import vault_move
from second_brain_ext.extension import SecondBrainExtension


@pytest.fixture(autouse=True)
def _clean_write_listeners():
    write_events._write_listeners.clear()
    yield
    write_events._write_listeners.clear()


def _tools(ext):
    mcp = FastMCP("test")
    ext.register_tools(mcp)
    return {t.name: t.fn for t in mcp._tool_manager.list_tools()}


@pytest.fixture
def ext(vault_dir):
    e = SecondBrainExtension()
    e._rebuild_all()
    return e


# -- create_folder ----------------------------------------------------------

def test_create_folder_creates_directory(ext, vault_dir):
    res = _tools(ext)["create_folder"](bucket="Projects", folder="Apollo")
    assert res.created is True and res.status == "created"
    assert res.path == "Projects/Apollo"
    assert (vault_dir / "Projects" / "Apollo").is_dir()


def test_create_folder_snaps_to_near_duplicate(ext, vault_dir):
    tools = _tools(ext)
    tools["create_folder"](bucket="Projects", folder="Historic Figures")
    # case/format variant must snap to the existing folder, not fragment
    res = tools["create_folder"](bucket="Projects", folder="historic-figures")
    assert res.created is False and res.status == "exists"
    assert res.path == "Projects/Historic Figures"


def test_create_folder_unknown_bucket(ext):
    res = _tools(ext)["create_folder"](bucket="Nonsense", folder="X")
    assert res.created is False and res.status == "needs_bucket"
    assert "Projects" in res.suggestions


def test_create_folder_requires_name(ext):
    res = _tools(ext)["create_folder"](bucket="Projects", folder="  / ")
    assert res.created is False and res.status == "needs_folder"


def test_empty_folder_visible_in_vault_map(ext, vault_dir):
    tools = _tools(ext)
    tools["create_folder"](bucket="Projects", folder="Apollo")
    vm = tools["vault_map"]()
    assert vm.folders.get("Projects/Apollo") == 0


def test_create_folder_is_audited(ext, vault_dir, tmp_path, monkeypatch):
    log = tmp_path / "audit" / "audit.jsonl"
    monkeypatch.setattr(config, "VAULT_AUDIT_LOG_PATH", str(log))
    _tools(ext)["create_folder"](bucket="Projects", folder="Audited")
    recs = [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines()]
    assert recs and recs[-1]["operation"] == "create_folder"
    assert recs[-1]["target_path"] == "Projects/Audited"


# -- related_notes ----------------------------------------------------------

@pytest.fixture
def linked_vault(vault_dir):
    (vault_dir / "hub.md").write_text(
        "---\ntitle: Hub Note\n---\n# Hub Note\nSee [[Nested Note|the nested one]] "
        "and [[Nowhere Note]] and [[Nested Note#Some Section]].\n",
        encoding="utf-8",
    )
    (vault_dir / "subfolder" / "nested-note.md").write_text(
        "---\ntitle: Nested Note\n---\nPoints back at [[Hub Note]].\n",
        encoding="utf-8",
    )
    return vault_dir


def test_related_notes_resolves_links_and_backlinks(linked_vault):
    ext = SecondBrainExtension()
    ext._rebuild_all()
    tools = _tools(ext)

    rel = tools["related_notes"](id="hub.md")
    ids_to = [r.id for r in rel.links_to]
    assert ids_to == ["subfolder/nested-note.md"]  # deduped despite two links
    assert rel.unresolved == ["Nowhere Note"]
    assert [r.id for r in rel.linked_from] == ["subfolder/nested-note.md"]

    back = tools["related_notes"](id="subfolder/nested-note.md")
    assert [r.id for r in back.links_to] == ["hub.md"]
    assert [r.id for r in back.linked_from] == ["hub.md"]


def test_related_notes_unknown_id(ext):
    with pytest.raises(ValueError, match="search_notes"):
        _tools(ext)["related_notes"](id="does/not/exist.md")


# -- folder-move staleness fix ----------------------------------------------

def test_folder_move_rebuilds_both_indexes(vault_dir):
    fm_index = FrontmatterIndex()
    fm_index.rebuild()
    ext = SecondBrainExtension()
    ext.before_indexes_start(fm_index)  # registers the write listener

    assert ext._get("subfolder/nested-note.md") is not None
    assert "subfolder/nested-note.md" in fm_index._index

    out = json.loads(vault_move("subfolder", "Archives/subfolder"))
    assert out.get("moved") is True

    # No watcher runs in this test -- only the write-event listener could have
    # refreshed the indexes. Both must reflect the new location already.
    assert ext._get("subfolder/nested-note.md") is None
    assert ext._get("Archives/subfolder/nested-note.md") is not None
    assert "subfolder/nested-note.md" not in fm_index._index
    assert "Archives/subfolder/nested-note.md" in fm_index._index


def test_single_note_move_does_not_trigger_full_rebuild(vault_dir, monkeypatch):
    fm_index = FrontmatterIndex()
    fm_index.rebuild()
    ext = SecondBrainExtension()
    ext.before_indexes_start(fm_index)

    calls = {"n": 0}
    monkeypatch.setattr(ext, "_rebuild_all", lambda: calls.__setitem__("n", calls["n"] + 1))
    vault_move("test-note.md", "Archives/test-note.md")
    # .md-only moves are the watcher's job (debounced); the listener must not
    # add a full rebuild on every single-note move.
    assert calls["n"] == 0
