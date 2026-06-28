"""Pillar 3 tests: archive_chat (distilled note + linked raw, raw excluded from search)."""

import datetime
import shutil
from pathlib import Path

import pytest
from mcp.server.fastmcp import FastMCP

from obsidian_vault_mcp import config
from second_brain_ext.extension import SecondBrainExtension

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


def _expected_id(source, title):
    d = datetime.date.today().strftime("%Y%m%d")
    return f"Chat Archive/{d}-{source}-{title}.md"


def test_archive_chat_writes_distilled_and_raw(vault):
    ext, fn = _tools(vault)
    res = fn["archive_chat"](
        title="MCP Build Session",
        summary="We built pillars 1-3 of the second-brain MCP.",
        source="claude",
        decisions=["Use the extension seam", "Curate the tool surface"],
        open_questions=["Add semantic search?"],
        tags=["strategy", "mcp"],
        project="VPP Pitch Deck",
        raw_transcript="USER: hi\nASSISTANT: hello, here is a very long transcript...",
    )
    assert res.created and res.status == "created"
    assert res.id == _expected_id("claude", "mcp-build-session")

    text = (vault / res.id).read_text(encoding="utf-8")
    assert "source: claude" in text and "type: chat" in text
    assert "> [!abstract] Summary" in text
    assert "## Key decisions" in text and "## Open questions" in text
    assert "[Full transcript](raw/" in text          # link to raw
    assert "[[VPP Pitch Deck]]" in text              # project link

    # raw transcript saved to a separate, underscore-prefixed file
    assert res.raw_id and (vault / res.raw_id).exists()
    assert "very long transcript" in (vault / res.raw_id).read_text(encoding="utf-8")

    # tag governance
    assert res.tags_used == ["strategy"] and "mcp" in res.proposed_tags


def test_raw_excluded_from_index_but_distilled_searchable(vault):
    ext, fn = _tools(vault)
    res = fn["archive_chat"](title="Cross LLM Memory", summary="Portable memory across tools.",
                             source="chatgpt", raw_transcript="big raw text " * 50)
    ext._rebuild_all()  # rescan from disk
    ids = {n.id for n in ext._snapshot()}
    assert res.id in ids               # distilled note is indexed
    assert res.raw_id not in ids       # raw transcript is NOT indexed
    # distilled note is findable via search; raw is not surfaced
    hits = fn["search_notes"](query="portable memory across tools")
    assert any(h.id == res.id for h in hits)


def test_raw_still_fetchable_by_id(vault):
    _, fn = _tools(vault)
    res = fn["archive_chat"](title="Fetch Raw", summary="s", source="claude",
                             raw_transcript="SECRET TRANSCRIPT MARKER")
    got = fn["get_note"](id=res.raw_id)
    assert "SECRET TRANSCRIPT MARKER" in got.content


def test_archive_chat_continuation_appends(vault):
    _, fn = _tools(vault)
    first = fn["archive_chat"](title="Ongoing Thread", summary="part one", source="claude")
    cont = fn["archive_chat"](title="Ongoing Thread", summary="part two follow-up",
                              source="claude", continue_id=first.id)
    assert cont.status == "continued" and cont.id == first.id
    text = (vault / first.id).read_text(encoding="utf-8")
    assert "part one" in text and "## Update" in text and "part two follow-up" in text


def test_archive_chat_is_exposed(vault):
    _, fn = _tools(vault)
    assert "archive_chat" in fn
