"""Low-level write operations: render, sanitize, house-style, create/edit.

All filesystem access goes through the upstream vault helpers (atomic writes,
path-traversal safety, audit logging). This module only composes content and
chooses paths; it never touches disk directly except via those helpers.
"""

from __future__ import annotations

import re

import frontmatter
import yaml

from obsidian_vault_mcp.vault import read_file, resolve_vault_path, write_file_atomic

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
    write_file_atomic(rel, render(fm, body))
    return {
        "created": True,
        "status": "overwritten" if exists else "created",
        "id": rel,
        "path": str(path),
    }


def write_at(rel: str, fm: dict, body: str, overwrite: bool = False) -> dict:
    """Render + write a note at an explicit vault-relative path (no clobber by default)."""
    path = resolve_vault_path(rel)
    exists = path.exists()
    if exists and not overwrite:
        return {"created": False, "status": "exists", "id": rel, "path": str(path)}
    write_file_atomic(rel, render(fm, body))
    return {
        "created": True,
        "status": "overwritten" if exists else "created",
        "id": rel,
        "path": str(path),
    }


def write_raw(rel: str, text: str) -> str:
    """Write a raw (un-templated) file, e.g. a chat transcript. Returns the id."""
    write_file_atomic(rel, text if text.endswith("\n") else text + "\n")
    return rel


def append(rel: str, content: str) -> None:
    old, _ = read_file(rel)
    new = old.rstrip() + "\n\n" + content.strip() + "\n"
    write_file_atomic(rel, new)


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
    write_file_atomic(rel, "\n".join(new_lines).rstrip() + "\n")


def set_frontmatter(rel: str, fields: dict) -> None:
    raw, _ = read_file(rel)
    post = frontmatter.loads(raw)
    meta = dict(post.metadata)
    meta.update(fields)
    write_file_atomic(rel, render(meta, post.content))
