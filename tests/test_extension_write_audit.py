"""The extension's write path must emit audit records (fix for audit gap H-1).

The upstream audit wrapper (server._run_audited) only covers upstream vault_*
tools, and the extension prunes those from the advertised surface -- so
create_note / edit_note / archive_chat writes went through writing.py with NO
audit trail. These tests pin the fix: every writing.py disk write emits one
append-only JSON record (same shape as upstream's) and fires the write-event
seam, and with auditing disabled nothing is written.
"""

import json

import pytest

from obsidian_vault_mcp import config, write_events
from second_brain_ext import writing


@pytest.fixture
def audit_log(vault_dir, tmp_path, monkeypatch):
    """Enable auditing to a log OUTSIDE the vault; return its path."""
    log = tmp_path / "audit" / "audit.jsonl"
    monkeypatch.setattr(config, "VAULT_AUDIT_LOG_PATH", str(log))
    return log


def _records(log):
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]


def test_create_emits_audit_record(audit_log, vault_dir):
    res = writing.create("Projects", None, "Audit Me", {"tags": []}, "body text")
    assert res["created"] is True

    recs = _records(audit_log)
    assert len(recs) == 1
    rec = recs[0]
    assert rec["operation"] == "create_note"
    assert rec["target_path"] == "Projects/Audit Me.md"
    assert rec["operation_status"] == "success"
    assert rec["checksum_before"] is None          # new file
    assert rec["checksum_after"]                   # written content hashed
    assert rec["size_after"] > 0


def test_append_and_sections_emit_edit_records(audit_log, vault_dir):
    writing.create("Projects", None, "Editable", {"tags": []}, "# Editable\n\n## Notes\nold")
    before = len(_records(audit_log))

    writing.append("Projects/Editable.md", "appended line")
    writing.replace_section("Projects/Editable.md", "Notes", "new body")
    writing.set_frontmatter("Projects/Editable.md", {"status": "active"})

    recs = _records(audit_log)[before:]
    assert [r["operation"] for r in recs] == ["edit_note", "edit_note", "edit_note"]
    for r in recs:
        assert r["operation_status"] == "success"
        assert r["target_path"] == "Projects/Editable.md"
        assert r["checksum_before"]               # file existed before each edit
        assert r["checksum_after"] != r["checksum_before"]


def test_archive_chat_paths_emit_archive_records(audit_log, vault_dir):
    writing.write_at("Chat Archive/20260702-claude-x.md", {"type": "chat"}, "# X\nsummary")
    writing.write_raw("Chat Archive/raw/_20260702-claude-x.md", "full transcript")
    writing.append("Chat Archive/20260702-claude-x.md", "## Update\nmore",
                   operation="archive_chat")

    ops = [r["operation"] for r in _records(audit_log)]
    assert ops == ["archive_chat", "archive_chat", "archive_chat"]


def test_no_records_when_audit_disabled(vault_dir, tmp_path, monkeypatch):
    monkeypatch.setattr(config, "VAULT_AUDIT_LOG_PATH", "")
    log = tmp_path / "audit" / "audit.jsonl"
    writing.create("Projects", None, "Silent", {"tags": []}, "body")
    assert not log.exists()


def test_write_events_fire_for_extension_writes(audit_log, vault_dir):
    seen = []
    write_events.register_write_listener(lambda op, paths: seen.append((op, list(paths))))
    try:
        writing.create("Projects", None, "Evented", {"tags": []}, "body")
        writing.append("Projects/Evented.md", "more")
    finally:
        write_events._write_listeners.clear()

    assert ("created", ["Projects/Evented.md"]) in seen
    assert ("updated", ["Projects/Evented.md"]) in seen


def test_extension_operations_registered_as_mutations(vault_dir):
    from obsidian_vault_mcp.audit import MUTATION_OPERATIONS
    assert {"create_note", "edit_note", "archive_chat"} <= MUTATION_OPERATIONS
