"""Parse vault markdown into Note objects for token-light ranking.

Reuses the upstream server's configured vault root and exclusion set so this
layer indexes exactly what the rest of the server exposes. Read-only; nothing
here writes to disk.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

import frontmatter

from obsidian_vault_mcp import config

logger = logging.getLogger(__name__)

# A leading YAML frontmatter fence (tolerant of a BOM and CRLF), used to strip
# unparseable frontmatter off the body when we fall back to body-only indexing.
_FM_BLOCK = re.compile(r"^﻿?---\r?\n.*?\r?\n(?:---|\.\.\.)\r?\n", re.DOTALL)


def _strip_frontmatter_block(raw: str) -> str:
    return _FM_BLOCK.sub("", raw, count=1)

# Files skipped in addition to config.EXCLUDED_DIRS. A leading underscore is a
# common convention for index/meta notes (e.g. _index.md); CLAUDE.md/GEMINI.md/
# AGENTS.md are AI-agent instruction files, not knowledge notes.
EXCLUDE_GLOBS = ("_*.md", "CLAUDE.md", "GEMINI.md", "AGENTS.md")

# Summaries ride along on every search hit, so keep them tight. ~240 chars is
# enough for an extractive gist; the full note is one get_note away.
SUMMARY_MAX = 240

_CALLOUT = re.compile(r"^>\s*\[!\w+\][^\n]*\n((?:>[^\n]*\n?)+)", re.MULTILINE)
_H1 = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)
_WS = re.compile(r"\s+")
_PARA_SPLIT = re.compile(r"\n\s*\n")


@dataclass
class Note:
    """One markdown file, parsed. ``id`` is the vault-relative path (POSIX)."""

    id: str
    title: str
    bucket: str  # top-level folder, or "" for notes at the vault root
    tags: list[str]
    created: str | None
    source: str | None
    summary: str
    body: str
    modified: str | None = None  # ISO timestamp from file mtime (for "recent")
    status: str | None = None  # frontmatter `status`, e.g. a project's "active"

    @property
    def tags_text(self) -> str:
        return " ".join(self.tags)


def _normalize_tags(raw) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        out: list[str] = []
        for item in raw:
            out.extend(_normalize_tags(item))
        return out
    if isinstance(raw, str):
        parts = re.split(r"[,\s]+", raw.strip())
    else:
        parts = [str(raw)]
    return [p.lstrip("#").strip() for p in parts if p and p.strip()]


def _normalize_date(raw) -> str | None:
    if raw is None:
        return None
    if isinstance(raw, datetime):
        return raw.date().isoformat()
    if isinstance(raw, date):
        return raw.isoformat()
    s = str(raw).strip()
    return s or None


def _stringify_source(raw) -> str | None:
    if raw is None:
        return None
    if isinstance(raw, (list, tuple)):
        return ", ".join(str(x) for x in raw) or None
    s = str(raw).strip()
    return s or None


def _clean(text: str) -> str:
    return _WS.sub(" ", text).strip()


def _truncate(s: str, limit: int = SUMMARY_MAX) -> str:
    if len(s) <= limit:
        return s
    return s[:limit].rsplit(" ", 1)[0].rstrip() + "…"


def _extract_title(meta: dict, body: str, path: Path) -> str:
    raw = meta.get("title")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    m = _H1.search(body)
    if m:
        return m.group(1).strip()
    return path.stem


def _extract_summary(meta: dict, body: str) -> str:
    """Token-light summary: explicit field, else a callout, else the lead. Extractive only."""
    for key in ("summary", "description"):
        val = meta.get(key)
        if isinstance(val, str) and val.strip():
            return _truncate(_clean(val))
    m = _CALLOUT.search(body)
    if m:
        callout = re.sub(r"^>\s?", "", m.group(1), flags=re.MULTILINE)
        cleaned = _clean(callout)
        if cleaned:
            return _truncate(cleaned)
    for block in _PARA_SPLIT.split(body):
        b = block.strip()
        if not b or b.startswith(("#", ">", "![", "---")):
            continue
        return _truncate(_clean(b))
    return ""


def _excluded(rel: Path) -> bool:
    parts = rel.parts
    for part in parts[:-1]:
        if part in config.EXCLUDED_DIRS or part.startswith("."):
            return True
    name = parts[-1]
    if name.startswith("."):
        return True
    return any(rel.match(glob) for glob in EXCLUDE_GLOBS)


def is_excluded(rel_path: str) -> bool:
    """Whether a vault-relative path should be kept out of the content index."""
    if not rel_path.endswith(".md"):
        return True
    return _excluded(Path(rel_path))


def _mtime_iso(path: Path) -> str | None:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec="seconds")
    except OSError:
        return None


def build_note(rel_path: str) -> Note | None:
    """Parse a single vault-relative ``.md`` path into a Note, or None on failure."""
    root = config.VAULT_PATH
    path = root / rel_path
    try:
        post = frontmatter.load(str(path))
        meta = post.metadata or {}
        body = post.content or ""
    except FileNotFoundError:
        return None
    except Exception as exc:
        # Malformed frontmatter (e.g. an unquoted ':' in a value) must NOT make a
        # note vanish from search. Index it body-only and carry on — the vault is
        # the source of truth, so be forgiving about what's on disk.
        logger.warning(
            "second_brain_ext: frontmatter parse failed for %s (%s); indexing body-only",
            rel_path, exc,
        )
        try:
            body = _strip_frontmatter_block(path.read_text(encoding="utf-8"))
        except OSError:
            return None
        meta = {}
    rel = Path(rel_path)
    parts = rel.parts
    status = meta.get("status")
    return Note(
        id=rel.as_posix(),
        title=_extract_title(meta, body, path),
        bucket=parts[0] if len(parts) > 1 else "",
        tags=_normalize_tags(meta.get("tags")),
        created=_normalize_date(meta.get("created") or meta.get("published")),
        source=_stringify_source(meta.get("source")),
        summary=_extract_summary(meta, body),
        body=body,
        modified=_mtime_iso(path),
        status=str(status).strip() if status not in (None, "") else None,
    )


def build_all() -> list[Note]:
    """Scan the configured vault for content notes and parse each into a Note."""
    root = config.VAULT_PATH
    notes: list[Note] = []
    for path in sorted(root.rglob("*.md")):
        rel = path.relative_to(root)
        if _excluded(rel):
            continue
        note = build_note(rel.as_posix())
        if note is not None:
            notes.append(note)
    return notes
