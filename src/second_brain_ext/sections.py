"""Read-side section slicing for get_note: return one heading's subtree instead
of a whole file. Fence-aware, so ``#`` comments inside code blocks (common in
this vault's PowerShell/bash snippets) are never mistaken for headings.

The write-side analogue is ``writing.replace_section``; this is its read twin.
"""

from __future__ import annotations

import re

_FENCE_LINE = re.compile(r"^\s*(```|~~~)")
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")


def _headings(content: str) -> list[tuple[int, int, str]]:
    """``(line_index, level, text)`` for every real (non-fenced) ATX heading."""
    out: list[tuple[int, int, str]] = []
    in_fence = False
    for i, line in enumerate(content.splitlines()):
        if _FENCE_LINE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = _HEADING.match(line)
        if m:
            out.append((i, len(m.group(1)), m.group(2).strip()))
    return out


def outline(content: str) -> list[str]:
    """The note's headings, in order, as ``"## Heading"`` strings — a cheap map
    for navigating a long note without fetching its body."""
    return [f"{'#' * lvl} {text}" for _, lvl, text in _headings(content)]


def extract_section(content: str, name: str) -> str | None:
    """Return the section under heading ``name`` (the heading line through just
    before the next heading of the same or higher level), or None if not found.
    Case-insensitive, first match wins."""
    lines = content.splitlines()
    heads = _headings(content)
    target = name.strip().lstrip("#").strip().lower()
    for idx, (i, lvl, text) in enumerate(heads):
        if text.lower() == target:
            end = len(lines)
            for j, l2, _ in heads[idx + 1:]:
                if l2 <= lvl:
                    end = j
                    break
            return "\n".join(lines[i:end]).strip() + "\n"
    return None
