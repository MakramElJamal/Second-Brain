"""Pillar 2 tests: create_note + edit_note (placement, templates, tag governance).

These write, so each test runs against a fresh temp copy of the sample vault.
"""

import shutil
from pathlib import Path

import pytest
from mcp.server.fastmcp import FastMCP

from obsidian_vault_mcp import config
from second_brain_ext import tags as tag_gov
from second_brain_ext.extension import ALLOWLIST, SecondBrainExtension

SAMPLE = Path(__file__).parent / "sb_sample_vault"


@pytest.fixture
def vault(tmp_path, monkeypatch):
    dst = tmp_path / "vault"
    shutil.copytree(SAMPLE, dst)
    monkeypatch.setattr(config, "VAULT_PATH", dst)
    return dst


def _tools(vault):
    ext = SecondBrainExtension()
    ext._rebuild_all()
    mcp = FastMCP("test")
    ext.register_tools(mcp)
    return ext, {t.name: t.fn for t in mcp._tool_manager.list_tools()}


def _dummy(name):
    def fn(path: str = "") -> str:
        """dummy upstream tool"""
        return name
    fn.__name__ = name
    return fn


# --- create_note --------------------------------------------------------

def test_create_note_places_in_bucket_with_template(vault):
    _, fn = _tools(vault)
    res = fn["create_note"](title="VPP Pitch Deck", bucket="projects",
                            content="Build the deck.", tags=["projects", "app"])
    assert res.created and res.status == "created"
    assert res.id == "Projects/VPP Pitch Deck.md"
    text = (vault / "Projects" / "VPP Pitch Deck.md").read_text(encoding="utf-8")
    assert "# VPP Pitch Deck" in text
    assert "status: active" in text          # project template frontmatter
    assert "created:" in text and "tags:" in text
    assert set(res.tags_used) == {"projects", "app"} and res.proposed_tags == []


def test_unknown_bucket_writes_nothing(vault):
    _, fn = _tools(vault)
    res = fn["create_note"](title="X", bucket="nonsense")
    assert not res.created and res.status == "needs_bucket"
    assert "Projects" in res.suggestions
    assert not (vault / "nonsense").exists()


def test_idempotent_no_clobber(vault):
    _, fn = _tools(vault)
    fn["create_note"](title="Dup", bucket="Areas")
    res2 = fn["create_note"](title="Dup", bucket="Areas")
    assert not res2.created and res2.status == "exists"


def test_tag_governance_proposes_unknown(vault):
    _, fn = _tools(vault)
    res = fn["create_note"](title="New Topic", bucket="Resources",
                            tags=["strategy", "quantum-computing"])
    assert "strategy" in res.tags_used
    assert "quantum-computing" in res.proposed_tags
    text = (vault / "Resources" / "New Topic.md").read_text(encoding="utf-8")
    assert "quantum-computing" not in text   # governed out of the written note


def test_approve_new_tags_adds_to_vocabulary(vault):
    _, fn = _tools(vault)
    res = fn["create_note"](title="Quantum", bucket="Resources",
                            tags=["quantum"], approve_new_tags=True)
    assert "quantum" in res.tags_used and res.proposed_tags == []
    assert "quantum" in (tag_gov.read_approved_tags(vault) or [])


def test_bootstraps_approved_tags_file(vault):
    _, fn = _tools(vault)
    assert not (vault / "_claude-tags.md").exists()
    fn["create_note"](title="Seed", bucket="Areas", tags=["strategy"])
    approved = tag_gov.read_approved_tags(vault)
    assert approved and "strategy" in approved and "clippings" in approved


# --- folder governance (housekeeping: file into the right tree) ---------

def test_folder_snaps_to_existing_case_insensitive(vault):
    # The sample vault already has Resources/Books; asking for "books" must NOT
    # create a duplicate "books" folder — it snaps to the existing "Books".
    _, fn = _tools(vault)
    res = fn["create_note"](title="Strategy Two", bucket="Resources", folder="books")
    assert res.created
    assert res.id == "Resources/Books/Strategy Two.md"
    assert res.folder == "Books" and res.new_folder is False
    assert (vault / "Resources" / "Books" / "Strategy Two.md").exists()


def test_bucket_prefixed_folder_is_stripped(vault):
    # Model passes the full path including the bucket; we tolerate and dedupe it.
    _, fn = _tools(vault)
    res = fn["create_note"](title="Strategy Three", bucket="Resources",
                            folder="Resources/Books")
    assert res.id == "Resources/Books/Strategy Three.md" and res.folder == "Books"


def test_new_folder_is_flagged_with_similar(vault):
    # "Book" doesn't match "Books" exactly -> new folder, but we surface the close
    # existing one so the model/user can refile instead of fragmenting.
    _, fn = _tools(vault)
    res = fn["create_note"](title="Lone", bucket="Resources", folder="Book")
    assert res.created and res.new_folder is True
    assert "Books" in res.similar_folders
    assert res.id == "Resources/Book/Lone.md"


def test_no_folder_files_at_bucket_root(vault):
    _, fn = _tools(vault)
    res = fn["create_note"](title="Rooted", bucket="Areas")
    assert res.folder is None and res.new_folder is False
    assert res.id == "Areas/Rooted.md"


@pytest.mark.parametrize("evil", ["../../escape", "..\\..\\escape", "sub/../../../etc"])
def test_folder_path_traversal_is_rejected(vault, evil):
    # Security: a malicious `folder` must not write outside the vault. Upstream
    # path-safety rejects '..'; nothing is created outside the vault root.
    _, fn = _tools(vault)
    with pytest.raises(Exception):
        fn["create_note"](title="Evil", bucket="Areas", folder=evil)
    assert not (vault.parent / "escape").exists()
    assert not (vault.parent.parent / "etc").exists()


# --- edit_note ----------------------------------------------------------

def test_edit_append(vault):
    _, fn = _tools(vault)
    fn["create_note"](title="Log", bucket="Areas", content="Line one.")
    r = fn["edit_note"](id="Areas/Log.md", operation="append", content="Line two.")
    assert r.ok
    text = (vault / "Areas" / "Log.md").read_text(encoding="utf-8")
    assert "Line one." in text and "Line two." in text


def test_edit_replace_section(vault):
    _, fn = _tools(vault)
    fn["create_note"](title="Proj", bucket="Projects", content="## Notes\noriginal body")
    fn["edit_note"](id="Projects/Proj.md", operation="replace_section",
                    section="Notes", content="updated body")
    text = (vault / "Projects" / "Proj.md").read_text(encoding="utf-8")
    assert "updated body" in text and "original body" not in text


def test_edit_set_frontmatter_governs_tags(vault):
    _, fn = _tools(vault)
    fn["create_note"](title="Meta", bucket="Resources", tags=["strategy"])
    r = fn["edit_note"](id="Resources/Meta.md", operation="set_frontmatter",
                        frontmatter={"tags": ["strategy", "newtag"], "status": "review"})
    assert "newtag" in r.proposed_tags
    text = (vault / "Resources" / "Meta.md").read_text(encoding="utf-8")
    assert "status: review" in text and "strategy" in text and "newtag" not in text


def test_house_style_strips_long_dashes(vault):
    _, fn = _tools(vault)
    fn["create_note"](title="Dash", bucket="Areas", content="alpha—beta")
    text = (vault / "Areas" / "Dash.md").read_text(encoding="utf-8")
    assert "—" not in text


# --- allowlist ----------------------------------------------------------

def test_allowlist_drops_raw_write_tools(vault):
    ext = SecondBrainExtension()
    ext._rebuild_all()
    mcp = FastMCP("test")
    for nm in ["vault_write", "vault_edit", "vault_append", "vault_read", "vault_move"]:
        mcp.add_tool(_dummy(nm), name=nm)
    ext.register_tools(mcp)
    names = {t.name for t in mcp._tool_manager.list_tools()}
    assert {"create_note", "edit_note"} <= names
    assert "vault_write" not in names and "vault_edit" not in names and "vault_append" not in names
    assert "vault_move" in names          # still a kept extra
    assert names <= ALLOWLIST
