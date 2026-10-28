"""Keyword + metadata + knowledge-tree ranking over an in-memory list of Notes.

Three layers, all deterministic and model-free:

1. **BM25F lexical score.** Each query term is weighted by how rare it is in the
   vault (IDF), so "dichroic" counts for far more than "2026" or "October", and by
   the best field it appears in (title > tags > folder path > summary > body). Term
   frequency saturates, and body counts are length-normalized, so a long note that
   mentions a word in passing many times cannot outrank a short note *about* it.

2. **The folder path is a field.** A note inherits its ancestors' words, e.g.
   ``.../competitor analysis/zep/Zep - Business Overview.md`` matches
   "competitor". This is the vault's own version of "contextual retrieval": the
   context a chunk lacks is already written down in where it was filed.

3. **Knowledge-tree hub promotion.** The vault is a tree (bucket -> folder ->
   note), and index / map / synthesis notes are its internal nodes: human-written
   summaries of a subtree, the same role RAPTOR's generated summary nodes play. A
   hub's score is lifted by how well its *subtree* matches the query, so a broad
   question ("what did I do in August") surfaces the month index rather than one
   arbitrary day, while a specific question still lands on the leaf, because one
   strong leaf among weak siblings barely moves the hub. Words like "overview" or
   "everything" are read as a request for that higher level instead of being
   matched literally (which otherwise favors every "Business Overview" note).
"""

from __future__ import annotations

import functools
import heapq
import math
import re
import threading
from collections import Counter
from dataclasses import dataclass

from .note import Note

# Letter runs and digit runs, split apart, so "19-23October" yields 19, 23,
# october and "Run2" yields run, 2 (\w+ glued them into "23october", "run2").
_TOKEN = re.compile(r"[^\W\d_]+|\d+", re.UNICODE)

FIELD_WEIGHTS = {
    "title": 5.0,
    "tags": 3.0,
    "path": 2.0,
    "summary": 1.5,
    "source": 1.0,
    "body": 1.0,
}
_K1 = 1.2  # BM25 term-frequency saturation
# Two query terms that sit next to each other in the query AND in the title
# ("10 August", "Dichroic Filter") are a phrase match, worth this share of the
# pair's IDF. It separates "10 August" in a title from a "10-16August" folder.
PHRASE_WEIGHT = 0.5
_B_BODY = 0.75  # body length normalization (short fields are not normalized)

STOPWORDS = frozenset(
    """
    a an and are as at be been but by can could did do does for from had has have
    he her him his how i if in into is it its me my no nor not of on or our out so
    than that the their them then there these they this to was we were what when
    where which who whom why will with would you your yours
    about above after again all also am any because before being below between both
    each few more most other over same some such only very
    note notes say says said tell find search show me please give get want know
    work worked happen happened went thing things
    """.split()
)

# Words that ask for the *level* of an answer rather than naming its content.
# They switch on stronger hub promotion and are dropped from the matched terms.
BROAD_CUES = frozenset(
    "overview overviews everything summary summarize summarise recap whole entire".split()
)
# Words that also ask for a higher level but are real content too ("Week
# Worklog"), so they switch on hub promotion while still being matched.
LEVEL_CUES = frozenset("all week weekly month monthly".split())

# A hub is lifted by HUB_LIFT x (mean of its best HUB_TOP_K descendant scores);
# a query carrying a broad or level cue uses the larger HUB_LIFT_BROAD.
HUB_LIFT = 0.1
HUB_LIFT_BROAD = 0.9
HUB_TOP_K = 3
# A note that is not named like an index still counts as a hub when it links to at
# least this many notes filed in subfolders beneath it (e.g. a synthesis note
# sitting above zep/, mem0/, letta/). Same-folder "Related" links do not count, so
# ordinary leaves that cross-link their siblings are not mistaken for hubs.
HUB_MIN_DOWNLINKS = 3

_HUB_NAMES = frozenset({"index", "readme", "moc", "map", "home", "toc", "contents"})
_HUB_SUFFIXES = (" index", " moc", " map")
_ORDINAL_PREFIX = re.compile(r"^\d+\s*-\s*")
_WIKILINK = re.compile(r"\[\[([^\[\]|#]+)")
# [[target|alias]] -> alias, [[target]] -> "". A hub's link list repeats its
# children's titles; scoring those words as the hub's own content would count the
# subtree twice (once here, once in the hub lift), so hubs are indexed without them.
_LINK_TEXT = re.compile(r"\[\[[^\[\]|]*(?:\|([^\[\]]*))?\]\]")
_VOWEL = re.compile(r"[aeiouy]")

SNIPPET_RADIUS = 90  # chars of context each side of the match; tight by design


@dataclass
class Hit:
    note: Note
    score: float  # normalized 0..1, relative to the top hit in this result set
    snippet: str


@functools.lru_cache(maxsize=200_000)  # vocabularies are small; tokens repeat
def _fold(tok: str) -> str:
    """Lowercase, drop leading zeros, fold plurals and -ed/-ing (a tiny stemmer)."""
    tok = tok.lower()
    if tok.isdigit():
        return tok.lstrip("0") or "0"
    if len(tok) > 4 and tok.endswith("ies"):
        return tok[:-3] + "y"
    if len(tok) > 3 and tok.endswith("s") and not tok.endswith(("ss", "us", "is")):
        return tok[:-1]
    for suffix in ("ing", "ed"):
        if len(tok) > len(suffix) + 3 and tok.endswith(suffix):
            base = tok[: -len(suffix)]
            if _VOWEL.search(base):  # "string" must not become "str"
                if len(base) > 2 and base[-1] == base[-2] and base[-1] not in "aeiouls":
                    base = base[:-1]  # tripped -> tripp -> trip
                return base
    return tok


def tokenize(text: str) -> list[str]:
    return [_fold(t) for t in _TOKEN.findall((text or "").lower())]


def _counts(text: str) -> Counter:
    """Folded term counts. Counts raw tokens first so each distinct one folds once."""
    out: Counter = Counter()
    for tok, c in Counter(_TOKEN.findall((text or "").lower())).items():
        out[_fold(tok)] += c
    return out


def _query_tokens(query: str) -> list[str]:
    return [t.lower() for t in _TOKEN.findall(query or "")]


def _content_terms(query: str) -> list[str]:
    tokens = _query_tokens(query)
    meaningful = [t for t in tokens if t not in STOPWORDS and t not in BROAD_CUES]
    return [_fold(t) for t in (meaningful or tokens)]


def query_terms(query: str) -> set[str]:
    return set(_content_terms(query))


def is_broad(query: str) -> bool:
    return any(t in BROAD_CUES or t in LEVEL_CUES for t in _query_tokens(query))


# -- index -------------------------------------------------------------------


def _folder(note_id: str) -> str:
    return note_id.rsplit("/", 1)[0] if "/" in note_id else ""


def _stem(note_id: str) -> str:
    name = note_id.rsplit("/", 1)[-1]
    return name[:-3] if name.endswith(".md") else name


def _named_like_hub(note_id: str) -> bool:
    stem = _ORDINAL_PREFIX.sub("", _stem(note_id).lower()).strip()
    folder = _folder(note_id)
    if folder and stem == folder.rsplit("/", 1)[-1].lower():
        return True  # folder note: Projects/x/x.md
    return (
        stem in _HUB_NAMES
        or stem.endswith(_HUB_SUFFIXES)
        or stem.startswith("index ")
    )


@dataclass
class _Analysis:
    """One note's tokenized fields; reused until that Note object is replaced."""

    fields: dict[str, Counter]
    title_pairs: set[tuple[str, str]]
    body_len: int
    vocab: frozenset[str]


def _analyze(n: Note, is_hub: bool) -> _Analysis:
    body = _LINK_TEXT.sub(lambda m: m.group(1) or "", n.body) if is_hub else n.body
    f = {
        "title": _counts(n.title),
        "tags": _counts(n.tags_text),
        "path": _counts(_folder(n.id)),
        "summary": _counts(n.summary),
        "source": _counts(n.source or ""),
        "body": _counts(body),
    }
    title = tokenize(n.title)
    return _Analysis(
        fields=f,
        title_pairs=set(zip(title, title[1:])),
        body_len=sum(f["body"].values()),
        vocab=frozenset().union(*(c.keys() for c in f.values())),
    )


# id(Note) -> (note, analyzed-as-hub, analysis). Keyed by object identity: the
# extension replaces a Note object when its file changes, so after a write only
# that one note is re-tokenized.
_analyses: dict[int, tuple[Note, bool, _Analysis]] = {}


def _analysis_for(n: Note, is_hub: bool) -> _Analysis:
    hit = _analyses.get(id(n))
    if hit is not None and hit[0] is n and hit[1] == is_hub:
        return hit[2]
    a = _analyze(n, is_hub)
    _analyses[id(n)] = (n, is_hub, a)
    return a


class _Index:
    """Per-vault statistics, rebuilt only when the snapshot's notes change."""

    def __init__(self, notes: list[Note]):
        self.notes = notes
        self.hubs = self._find_hubs()
        analyses = [_analysis_for(n, i in self.hubs) for i, n in enumerate(notes)]
        live = {id(n) for n in notes}
        for key in [k for k in _analyses if k not in live]:
            del _analyses[key]  # deleted or replaced notes
        self.fields = [a.fields for a in analyses]
        self.title_pairs = [a.title_pairs for a in analyses]
        self.body_lens = [a.body_len for a in analyses]
        df: Counter = Counter()
        for a in analyses:
            df.update(a.vocab)
        self.df = df
        self.n = len(notes)
        self.avg_body = (sum(self.body_lens) / self.n) if self.n else 0.0
        # hub position -> positions of the leaf notes filed beneath it
        self.hub_leaves: dict[int, list[int]] = {
            i: [
                j for j, n in enumerate(notes)
                if j not in self.hubs and n.id.startswith(folder + "/")
            ]
            for i, folder in self.hubs.items()
        }

    def _find_hubs(self) -> dict[int, str]:
        """note position -> the folder it summarizes."""
        by_stem: dict[str, list[str]] = {}
        for n in self.notes:
            by_stem.setdefault(_stem(n.id).lower(), []).append(n.id)
        hubs: dict[int, str] = {}
        for i, n in enumerate(self.notes):
            folder = _folder(n.id)
            if not folder:
                continue  # a root note would govern the whole vault; skip
            if _named_like_hub(n.id):
                hubs[i] = folder
                continue
            prefix = folder + "/"
            below = set()
            for raw in _WIKILINK.findall(n.body):
                target = raw.strip().rsplit("/", 1)[-1].lower()
                for tid in by_stem.get(target, ()):
                    if tid.startswith(prefix) and _folder(tid) != folder:
                        below.add(tid)
            if len(below) >= HUB_MIN_DOWNLINKS:
                hubs[i] = folder
        return hubs

    def idf(self, term: str) -> float:
        d = self.df.get(term, 0)
        return math.log(1 + (self.n - d + 0.5) / (d + 0.5))

    def lexical(
        self, i: int, terms: set[str], idf: dict[str, float], pairs: list[tuple[str, str]]
    ) -> float:
        f = self.fields[i]
        body_len = self.body_lens[i]
        body_norm = 1 - _B_BODY + _B_BODY * (body_len / self.avg_body if self.avg_body else 1)
        score = 0.0
        for term in terms:
            tf = 0.0
            for name, weight in FIELD_WEIGHTS.items():
                c = f[name].get(term, 0)
                if c:
                    tf += weight * (c / body_norm if name == "body" else c)
            if tf:
                score += idf[term] * tf * (_K1 + 1) / (tf + _K1)
        for a, b in pairs:
            if (a, b) in self.title_pairs[i]:
                score += PHRASE_WEIGHT * (idf[a] + idf[b])
        return score


_cache: _Index | None = None
_cache_lock = threading.Lock()  # tool calls may run on worker threads


def _index_for(notes: list[Note]) -> _Index:
    """Reuse the last index while the snapshot holds the same Note objects."""
    global _cache
    with _cache_lock:
        c = _cache
        if c is not None and len(c.notes) == len(notes) and all(
            a is b for a, b in zip(c.notes, notes)
        ):
            return c
        _cache = _Index(list(notes))
        return _cache


# -- search ------------------------------------------------------------------


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


def _hub_lift(index: _Index, raw: list[float], broad: bool) -> list[float]:
    """Lift each matching hub by the mean of its best leaf-descendant scores.

    Only leaves count as evidence. If sub-hubs counted, a month index would ride
    the score of the week index beneath it and outrank the week that actually
    answers "the first week of August".
    """
    lift = HUB_LIFT_BROAD if broad else HUB_LIFT
    out = list(raw)
    for i, leaves in index.hub_leaves.items():
        if raw[i] <= 0:
            continue  # a hub must match the query itself to be promoted
        below = heapq.nlargest(HUB_TOP_K, (raw[j] for j in leaves))
        if below:
            out[i] += lift * sum(below) / HUB_TOP_K
    return out


def search(
    notes,
    query: str,
    limit: int = 5,
    bucket=None,
    tags=None,
    date_from=None,
    date_to=None,
) -> list[Hit]:
    ordered = _content_terms(query)
    terms = set(ordered)
    if not terms or not notes:
        return []

    index = _index_for(notes)
    idf = {t: index.idf(t) for t in terms}
    pairs = list(zip(ordered, ordered[1:]))
    raw = [index.lexical(i, terms, idf, pairs) for i in range(index.n)]
    final = _hub_lift(index, raw, is_broad(query))

    scored = [
        (s, n)
        for s, n in zip(final, index.notes)
        if s > 0 and _passes_filters(n, bucket, tags, date_from, date_to)
    ]
    scored.sort(key=lambda pair: (-pair[0], pair[1].id))
    top = scored[: max(0, limit)]
    if not top:
        return []

    # Snippets look for the words as typed too: a folded term ("study") is not a
    # substring of what is on the page ("studies").
    snippet_terms = terms | {t for t in _query_tokens(query) if t not in STOPWORDS}
    max_score = top[0][0]
    return [
        Hit(
            note=note,
            score=round(s / max_score, 3),
            snippet=make_snippet(note.body, snippet_terms),
        )
        for s, note in top
    ]
