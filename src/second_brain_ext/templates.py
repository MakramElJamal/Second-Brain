"""PARA bucket routing + per-type note templates (the vault's house style).

The model decides *what* (intent, title, content, bucket); these helpers decide
*structure* (which folder, which frontmatter, which scaffold) so every note —
written by any LLM — comes out consistent.
"""

from __future__ import annotations

import datetime
import re

# Canonical PARA folder names, keyed by lowercased aliases.
CANONICAL = {
    "projects": "Projects",
    "project": "Projects",
    "areas": "Areas",
    "area": "Areas",
    "resources": "Resources",
    "resource": "Resources",
    "archives": "Archives",
    "archive": "Archives",
    "daily notes": "Daily Notes",
    "daily": "Daily Notes",
}
TYPE_FOR = {
    "Projects": "project",
    "Areas": "area",
    "Resources": "resource",
    "Archives": "archive",
    "Daily Notes": "daily",
}
CANONICAL_BUCKETS = ["Projects", "Areas", "Resources", "Archives", "Daily Notes"]

_SCAFFOLD = {
    "project": "> [!abstract] Goal\n> \n\n## Tasks\n- \n\n## Notes\n",
    "resource": "> [!abstract] Summary\n> \n\n## Notes\n",
    "area": "## Notes\n",
}


def normalize_bucket(bucket: str | None, known: set[str] = frozenset()) -> str | None:
    """Map a user/model bucket string to a canonical folder, or None if unknown."""
    if not bucket:
        return None
    b = bucket.strip().strip("/")
    low = b.lower()
    if low in CANONICAL:
        return CANONICAL[low]
    for k in known:  # existing top-level folders in the vault
        if k.lower() == low:
            return k
    return None


def note_type_for(bucket: str) -> str:
    return TYPE_FOR.get(bucket, "generic")


def _fold(s: str) -> str:
    """Normalize a folder path for matching: lowercase, collapse separators."""
    return re.sub(r"[^a-z0-9/]+", "", s.lower())


def normalize_folder(
    folder: str | None, existing: set[str]
) -> tuple[str | None, bool, list[str]]:
    """Resolve a requested subfolder against the bucket's existing tree, to stop
    near-duplicate folders ("Books" vs "books", "Historic Figures" vs
    "historic-figures") from fragmenting the vault.

    ``existing`` is the set of subfolder paths already under the bucket (relative
    to it). Returns ``(resolved_subfolder, is_new, similar)``:
    - an exact or normalized match snaps to the existing folder (``is_new`` False);
    - otherwise the folder is new (``is_new`` True) and ``similar`` lists close
      existing folders so the caller can confirm placement instead of sprawling.
    """
    if not folder or not folder.strip().strip("/"):
        return None, False, []
    want = folder.strip().strip("/")
    nwant = _fold(want)
    for e in existing:
        if e.lower() == want.lower() or _fold(e) == nwant:
            return e, False, []  # snapped to an existing folder
    similar = sorted(
        e for e in existing if nwant and (nwant in _fold(e) or _fold(e) in nwant)
    )
    return want, True, similar[:5]


def _strip_leading_h1(content: str) -> str:
    lines = content.lstrip().splitlines()
    if lines and lines[0].startswith("# "):
        return "\n".join(lines[1:]).lstrip()
    return content


def build(
    note_type: str,
    title: str,
    content: str,
    source: str | None,
    status: str | None,
    tags: list[str],
) -> tuple[dict, str]:
    """Return (frontmatter dict, body markdown) for a new note."""
    fm: dict = {"tags": tags or [], "created": datetime.date.today().isoformat()}
    if source:
        fm["source"] = source
    if note_type == "project":
        fm["status"] = status or "active"

    if content and content.strip():
        main = _strip_leading_h1(content).strip()
    else:
        main = _SCAFFOLD.get(note_type, "")
    body = f"# {title}\n\n{main}".rstrip() + "\n"
    return fm, body
