"""Keyword + metadata ranking over an in-memory list of Notes.

Coverage-dominated and stopword-filtered: each distinct query term contributes
once, weighted by the best field it appears in (title/tags > summary > body),
plus a small capped frequency bonus. Counting a term once stops long notes from
winning on incidental repeated common words, so a note matching more query terms
reliably ranks above one that just repeats a single term.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

from .note import Note

_TOKEN = re.compile(r"\w+", re.UNICODE)

FIELD_WEIGHTS = {
    "title": 3.0,
    "tags": 3.0,
    "summary": 2.0,
    "source": 1.0,
    "body": 1.0,
}

STOPWORDS = frozenset(
    """
    a an and are as at be been but by can could did do does for from had has have
    he her him his how i if in into is it its me my no nor not of on or our out so
    than that the their them then there these they this to was we were what when
    where which who whom why will with would you your yours
    about above after again all also am any because before being below between both
    each few more most other over same some such only very
    note notes say says said tell find search show me please give get want know
    """.split()
)

SNIPPET_RADIUS = 90  # chars of context each side of the match; tight by design
_TF_CAP = 5
_TF_WEIGHT = 0.1


@dataclass
class Hit:
    note: Note
    score: float  # normalized 0..1, relative to the top hit in this result set
    snippet: str


def tokenize(text: str) -> list[str]:
    return [t.lower() for t in _TOKEN.findall(text or "")]


def query_terms(query: str) -> set[str]:
    tokens = tokenize(query)
    meaningful = {t for t in tokens if t not in STOPWORDS}
    return meaningful or set(tokens)


def _score(note: Note, terms: set[str]) -> float:
    if not terms:
        return 0.0
    field_counts = {
        "title": Counter(tokenize(note.title)),
        "tags": Counter(tokenize(note.tags_text)),
        "summary": Counter(tokenize(note.summary)),
        "source": Counter(tokenize(note.source or "")),
        "body": Counter(tokenize(note.body)),
    }
    coverage = 0.0
    capped_occurrences = 0
    for term in terms:
        best_weight = 0.0
        occ = 0
        for name, counts in field_counts.items():
            c = counts.get(term, 0)
            if c:
                best_weight = max(best_weight, FIELD_WEIGHTS[name])
                occ += c
        if best_weight:
            coverage += best_weight
            capped_occurrences += min(occ, _TF_CAP)
    return coverage + _TF_WEIGHT * capped_occurrences


def _passes_filters(note: Note, bucket, tags, date_from, date_to) -> bool:
    if bucket and note.bucket.lower() != bucket.lower():
        return False
    if tags:
        have = {t.lower() for t in note.tags}
        if not all(t.lower() in have for t in tags):
            return False
    if date_from and (note.created is None or note.created < date_from):
        return False
    if date_to and (note.created is None or note.created > date_to):
        return False
    return True


def make_snippet(body: str, terms: set[str], radius: int = SNIPPET_RADIUS) -> str:
    if not body:
        return ""
    lowered = body.lower()
    pos = -1
    for tok in terms:
        i = lowered.find(tok)
        if i != -1 and (pos == -1 or i < pos):
            pos = i
    if pos == -1:
        start, end = 0, min(len(body), radius * 2)
    else:
        start = max(0, pos - radius)
        end = min(len(body), pos + radius)
    prefix = "…" if start > 0 else ""
    suffix = "…" if end < len(body) else ""
    return prefix + re.sub(r"\s+", " ", body[start:end]).strip() + suffix


def search(
    notes,
    query: str,
    limit: int = 5,
    bucket=None,
    tags=None,
    date_from=None,
    date_to=None,
) -> list[Hit]:
    terms = query_terms(query)
    if not terms:
        return []

    scored: list[tuple[float, Note]] = []
    for note in notes:
        if not _passes_filters(note, bucket, tags, date_from, date_to):
            continue
        s = _score(note, terms)
        if s > 0:
            scored.append((s, note))

    scored.sort(key=lambda pair: (-pair[0], pair[1].id))
    top = scored[: max(0, limit)]
    if not top:
        return []

    max_score = top[0][0]
    return [
        Hit(
            note=note,
            score=round(s / max_score, 3),
            snippet=make_snippet(note.body, terms),
        )
        for s, note in top
    ]
