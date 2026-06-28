"""Approved-tag vocabulary for the vault.

Source of truth, in order:
1. `_claude-tags.md` at the vault root, if it exists (the user's curated list).
2. Otherwise, derive the vocabulary from tags already used across the vault.

Read-only. Pillar 2 (the write subsystem) bootstraps `_claude-tags.md` from the
derived list so the user has a file to curate; this module just reads.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

from obsidian_vault_mcp import config

APPROVED_TAGS_FILE = "_claude-tags.md"
_TAG_LINE = re.compile(r"[#`-]*\s*([A-Za-z0-9][\w/\-]+)")


def read_approved_tags(vault_path: Path | None = None) -> list[str] | None:
    """Return the curated tag list from `_claude-tags.md`, or None if absent."""
    root = Path(vault_path) if vault_path else config.VAULT_PATH
    f = root / APPROVED_TAGS_FILE
    if not f.is_file():
        return None
    tags: list[str] = []
    for line in f.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#") and not s.lstrip("#").strip().startswith("#"):
            # allow markdown headings to be skipped, but keep "#tag" tokens below
            pass
        m = _TAG_LINE.match(s.lstrip("-*> ").strip())
        if m:
            tags.append(m.group(1).lower())
    # de-dupe, preserve order
    seen: set[str] = set()
    out = []
    for t in tags:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out or None


def derive_vocabulary(notes, limit: int = 60) -> list[str]:
    """Tags actually used across the vault, most frequent first (capped)."""
    counter: Counter[str] = Counter()
    for n in notes:
        for t in n.tags:
            counter[t.lower()] += 1
    return [tag for tag, _ in counter.most_common(limit)]


def tag_vocabulary(notes, vault_path: Path | None = None, limit: int = 60) -> list[str]:
    """The approved vocabulary: curated file if present, else derived from usage."""
    approved = read_approved_tags(vault_path)
    if approved is not None:
        return approved
    return derive_vocabulary(notes, limit=limit)


def validate(requested, approved) -> tuple[list[str], list[str]]:
    """Split requested tags into (approved_used, proposed_new), de-duped + normalized."""
    approved_lower = {a.lower() for a in approved}
    used: list[str] = []
    proposed: list[str] = []
    seen: set[str] = set()
    for t in requested or []:
        tl = str(t).strip().lstrip("#").lower()
        if not tl or tl in seen:
            continue
        seen.add(tl)
        (used if tl in approved_lower else proposed).append(tl)
    return used, proposed


_HEADER = (
    "# Approved Tags\n\n"
    "Curated tag vocabulary. Writes may only use tags in this list; new tags are "
    "proposed for your approval. Add or remove freely.\n\n"
)


def _write_list(root: Path, all_tags) -> None:
    body = _HEADER + "".join(f"- {t}\n" for t in sorted(set(all_tags)))
    (root / APPROVED_TAGS_FILE).write_text(body, encoding="utf-8")


def ensure_approved_file(notes, vault_path: Path | None = None) -> bool:
    """Create `_claude-tags.md` from existing usage if it doesn't exist yet.

    Returns True if it was created. Idempotent: a no-op once the file exists.
    """
    root = Path(vault_path) if vault_path else config.VAULT_PATH
    if (root / APPROVED_TAGS_FILE).is_file():
        return False
    _write_list(root, derive_vocabulary(notes, limit=500))
    return True


def add_approved(new_tags, vault_path: Path | None = None) -> None:
    """Add tags to the approved vocabulary file (creating it if needed)."""
    root = Path(vault_path) if vault_path else config.VAULT_PATH
    existing = read_approved_tags(root) or []
    have = {e.lower() for e in existing}
    merged = existing + [t for t in new_tags if t.lower() not in have]
    _write_list(root, merged)
