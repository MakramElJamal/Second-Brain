"""Low-level write operations: render, sanitize, house-style, create/edit.

All filesystem access goes through the upstream vault helpers (atomic writes,
path-traversal safety). This module only composes content and chooses paths;
it never touches disk directly except via those helpers.

Audit + write events: the upstream audit wrapper (`server._run_audited`) only
covers the upstream `vault_*` tools, and the extension prunes most of those from
the advertised surface -- so if the writes here didn't emit their own records,
the tools the model actually uses (create_note / edit_note / archive_chat) would
mutate the vault with NO audit trail. Every disk write below therefore funnels
through `_audited_write`, which emits the same append-only audit record the
upstream tools produce and fires the `write_events` seam.
"""

from __future__ import annotations

import re

import frontmatter
import yaml

from obsidian_vault_mcp.audit import (
    MUTATION_OPERATIONS,
    audit_enabled,
    build_audit_record,
    snapshot_path,
    write_audit_record,
)
from obsidian_vault_mcp.vault import read_file, resolve_vault_path, write_file_atomic
from obsidian_vault_mcp.write_events import fire_write

# Register the extension's operations so audit consumers (and anything that
# consults MUTATION_OPERATIONS) treat them as mutations, matching upstream tools.
MUTATION_OPERATIONS.update({"create_note", "edit_note", "archive_chat", "create_folder"})


def make_folder(rel: str) -> bool:
    """Create a folder inside the vault (path-safe, audited). True if newly made.

    Folders have no checksum, so the audit record carries only the operation and
    target path. Fires the write-event seam like every other mutation here.
    """
    path = resolve_vault_path(rel)
    if path.is_dir():
        return False
    path.mkdir(parents=True)
    if audit_enabled():
        write_audit_record(build_audit_record(
            operation="create_folder", target_path=rel, operation_status="success",
        ))
    fire_write("created", [rel])
    return True


def _audited_write(rel: str, content: str, operation: str) -> None:
    """write_file_atomic + audit record + write event.

    Mirrors upstream server._run_audited for mutations: snapshot (size, checksum)
    before and after, one JSON record per write, hashed principal via the request
    context. A failed write is recorded with operation_status="error" and
    re-raised; the audit write itself is best-effort (write_audit_record swallows
    its own failures) so the trail can never break a tool result.
    """
    if not audit_enabled():
        is_new = not resolve_vault_path(rel).exists()
        write_file_atomic(rel, content)
        fire_write("created" if is_new else "updated", [rel])
        return
    before = snapshot_path(rel)
    is_new = before.get("checksum") is None
    try:
        write_file_atomic(rel, content)
    except Exception:
        write_audit_record(build_audit_record(
            operation=operation, target_path=rel, before=before,
            operation_status="error", error="write exception",
        ))
        raise
    write_audit_record(build_audit_record(
        operation=operation, target_path=rel, before=before,
        after=snapshot_path(rel), operation_status="success",
    ))
    fire_write("created" if is_new else "updated", [rel])


_ILLEGAL = re.compile(r'[\\/:*?"<>|]')
_FENCE = re.compile(r"(```.*?```|~~~.*?~~~)", re.DOTALL)
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")


def sanitize_filename(title: str) -> str:
    name = _ILLEGAL.sub("", title).strip().strip(".")
    name = re.sub(r"\s+", " ", name)
    return (name or "Untitled")[:120]


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return (s or "untitled")[:60]


def apply_house_style(text: str) -> str:
    """Enforce the vault's prose rule: no long dashes (outside code fences)."""
    if not text:
        return text
    parts = _FENCE.split(text)
    for i in range(0, len(parts), 2):  # even indices are non-code segments
        parts[i] = parts[i].replace("—", " - ").replace("–", "-")
    return "".join(parts)


def render(frontmatter_dict: dict, body: str) -> str:
    """Serialize frontmatter (insertion order preserved) + body into a note."""
    y = yaml.safe_dump(
        frontmatter_dict, sort_keys=False, allow_unicode=True, default_flow_style=False
    ).strip()
    return f"---\n{y}\n---\n\n{body.strip()}\n"


def build_rel_path(bucket: str, folder: str | None, title: str) -> str:
    fname = sanitize_filename(title) + ".md"
    return "/".join(p for p in (bucket, (folder or "").strip("/"), fname) if p)


def create(bucket: str, folder: str | None, title: str, fm: dict, body: str,
           overwrite: bool = False) -> dict:
    rel = build_rel_path(bucket, folder, title)
    path = resolve_vault_path(rel)  # validates; also lets us check existence
    exists = path.exists()
    if exists and not overwrite:
        return {"created": False, "status": "exists", "id": rel, "path": str(path)}
    _audited_write(rel, render(fm, body), "create_note")
    return {
        "created": True,
        "status": "overwritten" if exists else "created",
        "id": rel,
        "path": str(path),
    }


def write_at(rel: str, fm: dict, body: str, overwrite: bool = False,
             operation: str = "archive_chat") -> dict:
    """Render + write a note at an explicit vault-relative path (no clobber by default)."""
    path = resolve_vault_path(rel)
    exists = path.exists()
    if exists and not overwrite:
        return {"created": False, "status": "exists", "id": rel, "path": str(path)}
    _audited_write(rel, render(fm, body), operation)
    return {
        "created": True,
        "status": "overwritten" if exists else "created",
        "id": rel,
        "path": str(path),
    }


def write_raw(rel: str, text: str, operation: str = "archive_chat") -> str:
    """Write a raw (un-templated) file, e.g. a chat transcript. Returns the id."""
    _audited_write(rel, text if text.endswith("\n") else text + "\n", operation)
    return rel


def append(rel: str, content: str, operation: str = "edit_note") -> None:
    old, _ = read_file(rel)
    new = old.rstrip() + "\n\n" + content.strip() + "\n"
    _audited_write(rel, new, operation)


def replace_section(rel: str, section: str, content: str) -> None:
    old, _ = read_file(rel)
    lines = old.splitlines()
    hdr_idx = level = None
    for i, line in enumerate(lines):
        m = _HEADING.match(line)
        if m and m.group(2).strip().lower() == section.strip().lower():
            hdr_idx, level = i, len(m.group(1))
            break
    if hdr_idx is None:
        raise ValueError(f"Section '{section}' not found in {rel}")
    end = len(lines)
    for j in range(hdr_idx + 1, len(lines)):
        m = _HEADING.match(lines[j])
        if m and len(m.group(1)) <= level:
            end = j
            break
    new_lines = lines[: hdr_idx + 1] + ["", content.strip(), ""] + lines[end:]
    _audited_write(rel, "\n".join(new_lines).rstrip() + "\n", "edit_note")


def set_frontmatter(rel: str, fields: dict) -> None:
    raw, _ = read_file(rel)
    post = frontmatter.loads(raw)
    meta = dict(post.metadata)
    meta.update(fields)
    _audited_write(rel, render(meta, post.content), "edit_note")
