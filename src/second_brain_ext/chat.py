"""Chat archive: distilled note (searchable) + linked raw transcript.

The LLM that had the conversation distills it at save time (summary, decisions,
open questions, key points). We store that compact note in `Chat Archive/` so any
client can retrieve it cheaply via search_notes. The optional full transcript is
written to `Chat Archive/raw/_<id>.md` — the leading underscore keeps it OUT of
the search index (token-light) while still readable by id via get_note.
"""

from __future__ import annotations

import datetime

from . import writing

CHAT_FOLDER = "Chat Archive"
RAW_SUBFOLDER = "raw"


def make_id(source: str, title: str) -> str:
    d = datetime.date.today().strftime("%Y%m%d")
    return f"{d}-{writing.slug(source)}-{writing.slug(title)}"


def distilled_rel(chat_id: str) -> str:
    return f"{CHAT_FOLDER}/{chat_id}.md"


def raw_rel(chat_id: str) -> str:
    # leading underscore => excluded from the content index/search
    return f"{CHAT_FOLDER}/{RAW_SUBFOLDER}/_{chat_id}.md"


def raw_link(chat_id: str) -> str:
    # relative to the distilled note's folder (Chat Archive/)
    return f"{RAW_SUBFOLDER}/_{chat_id}.md"


def build_distilled(
    title: str,
    summary: str,
    source: str,
    decisions=None,
    open_questions=None,
    key_points=None,
    tags=None,
    project: str | None = None,
    participants=None,
    raw_link_path: str | None = None,
) -> tuple[dict, str]:
    fm: dict = {
        "tags": tags or [],
        "created": datetime.date.today().isoformat(),
        "source": source,
        "type": "chat",
    }
    if participants:
        fm["participants"] = participants
    if project:
        fm["project"] = f"[[{project}]]"
    if summary:
        fm["summary"] = summary
    if raw_link_path:
        fm["raw"] = raw_link_path

    lines = [f"# {title}", ""]
    if summary:
        lines.append("> [!abstract] Summary")
        lines += [f"> {ln}" for ln in summary.splitlines()]
        lines.append("")
    if decisions:
        lines += ["## Key decisions", *[f"- {d}" for d in decisions], ""]
    if open_questions:
        lines += ["## Open questions", *[f"- {q}" for q in open_questions], ""]
    if key_points:
        lines += ["## Key points", *[f"- {k}" for k in key_points], ""]
    if project:
        lines += [f"Related: [[{project}]]", ""]
    if raw_link_path:
        lines += [f"[Full transcript]({raw_link_path})", ""]
    body = "\n".join(lines).rstrip() + "\n"
    return fm, body


def build_continuation(
    summary: str, decisions=None, open_questions=None, key_points=None
) -> str:
    """A dated section appended to an existing archive when continuing a thread."""
    d = datetime.date.today().isoformat()
    lines = [f"## Update {d}", ""]
    if summary:
        lines += [summary, ""]
    if decisions:
        lines += ["**Decisions**", *[f"- {x}" for x in decisions], ""]
    if open_questions:
        lines += ["**Open questions**", *[f"- {x}" for x in open_questions], ""]
    if key_points:
        lines += ["**Key points**", *[f"- {x}" for x in key_points], ""]
    return "\n".join(lines).rstrip() + "\n"
