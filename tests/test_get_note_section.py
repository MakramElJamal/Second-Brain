"""Section-level get_note + the sections helper (token-light reads of long notes)."""

import shutil
from pathlib import Path

import pytest
from mcp.server.fastmcp import FastMCP

from obsidian_vault_mcp import config
from second_brain_ext import sections
from second_brain_ext.extension import SecondBrainExtension

SAMPLE = Path(__file__).parent / "bench_vault"

NOTE_WITH_FENCE = """# Title

## Setup

Run the script.

```bash
# this is a comment, NOT a heading
echo hi
```

## Usage

Do the thing.

### Detail

A nested point.

## Teardown

Clean up.
"""


# --- sections helper -----------------------------------------------------

def test_outline_lists_real_headings_only():
    out = sections.outline(NOTE_WITH_FENCE)
    assert out == ["# Title", "## Setup", "## Usage", "### Detail", "## Teardown"]
    # the '# comment' inside the code fence is not treated as a heading
    assert not any("comment" in h for h in out)


def test_extract_section_returns_subtree_until_same_level():
    sec = sections.extract_section(NOTE_WITH_FENCE, "Usage")
    assert sec.startswith("## Usage")
    assert "Do the thing." in sec
    assert "### Detail" in sec and "A nested point." in sec  # nested kept
    assert "Teardown" not in sec  # stops at the next same-level heading


def test_extract_section_is_case_insensitive_and_strips_hashes():
    assert sections.extract_section(NOTE_WITH_FENCE, "## setup") is not None
    assert sections.extract_section(NOTE_WITH_FENCE, "SETUP") is not None


def test_extract_section_unknown_returns_none():
    assert sections.extract_section(NOTE_WITH_FENCE, "nope") is None


# --- get_note tool -------------------------------------------------------

@pytest.fixture
def fn(tmp_path, monkeypatch):
    dst = tmp_path / "vault"
    shutil.copytree(SAMPLE, dst)
    monkeypatch.setattr(config, "VAULT_PATH", dst)
    ext = SecondBrainExtension()
    ext._rebuild_all()
    mcp = FastMCP("test")
    ext.register_tools(mcp)
    return {t.name: t.fn for t in mcp._tool_manager.list_tools()}


def test_get_note_full_by_default(fn):
    note = fn["get_note"](id="Areas/Historic Figures/napoleon.md")
    assert "Work ethic" in note.content and "Decisiveness" in note.content


def test_get_note_section_returns_only_that_section(fn):
    note = fn["get_note"](id="Areas/Historic Figures/napoleon.md", section="Work ethic")
    assert "## Work ethic" in note.content
    assert "eighteen-hour days" in note.content
    assert "Decisiveness" not in note.content  # other sections excluded
    # and it is strictly smaller than the whole note
    full = fn["get_note"](id="Areas/Historic Figures/napoleon.md")
    assert len(note.content) < len(full.content)


def test_get_note_bad_section_lists_headings(fn):
    with pytest.raises(ValueError) as exc:
        fn["get_note"](id="Areas/Historic Figures/napoleon.md", section="nonexistent")
    msg = str(exc.value)
    assert "Available headings" in msg and "Work ethic" in msg


def test_get_note_outline_returns_headings_only(fn):
    note = fn["get_note"](id="Areas/Historic Figures/napoleon.md", outline=True)
    assert "## Work ethic" in note.content and "## Decisiveness" in note.content
    # body prose is gone — outline is just the map
    assert "eighteen-hour days" not in note.content
    full = fn["get_note"](id="Areas/Historic Figures/napoleon.md")
    assert len(note.content) < len(full.content)
