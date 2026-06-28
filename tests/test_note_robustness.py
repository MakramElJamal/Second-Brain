"""A note with malformed frontmatter must still be searchable, not silently
dropped from the index (regression for the 48-laws indexing bug the search eval
surfaced)."""

from obsidian_vault_mcp import config
from second_brain_ext import note

# An unquoted ':' in a value makes PyYAML raise — frontmatter is unparseable.
BAD = (
    "---\n"
    "summary: Core themes: conceal intentions, guard reputation\n"
    "tags: [strategy]\n"
    "---\n"
    "# Power Laws\n\n"
    "Conceal your intentions; never outshine the master.\n"
)


def test_malformed_frontmatter_is_indexed_body_only(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "VAULT_PATH", tmp_path)
    (tmp_path / "bad.md").write_text(BAD, encoding="utf-8")

    n = note.build_note("bad.md")
    assert n is not None                       # NOT dropped
    assert n.id == "bad.md"
    assert n.title == "Power Laws"             # H1 title still recovered
    assert "Conceal your intentions" in n.body  # body is searchable
    assert n.tags == []                        # unparseable metadata -> no tags
    # the frontmatter junk is stripped from the body, not indexed as content
    assert "Core themes" not in n.body


def test_malformed_note_is_included_in_full_scan(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "VAULT_PATH", tmp_path)
    (tmp_path / "good.md").write_text("---\ntags: [x]\n---\n# Good\n\nbody\n", encoding="utf-8")
    (tmp_path / "bad.md").write_text(BAD, encoding="utf-8")
    ids = {n.id for n in note.build_all()}
    assert ids == {"good.md", "bad.md"}        # neither is lost
