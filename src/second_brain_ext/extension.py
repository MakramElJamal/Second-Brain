"""SecondBrainExtension: token-light retrieval + an opinionated tool surface.

Through the upstream extension seam this registers our tools (`search_notes`,
`get_note`, `vault_map`; write tools land in later pillars) and then **curates the
tool surface** — pruning upstream's low-level tools down to an allowlist so the
LLM sees a small, house-style set (fewer tokens, less confusion). Pruning is
reversible: upstream code is untouched, just un-advertised.

Maintains a small in-memory content index (titles/summaries/bodies, plus mtime
and status) built at startup and kept fresh via the frontmatter index's change
listener. Read tools reuse the upstream path-safety for file access.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path

from mcp.types import ToolAnnotations
from pydantic import BaseModel, Field

from obsidian_vault_mcp import config
from obsidian_vault_mcp.extensions import Extension
from obsidian_vault_mcp.vault import read_file

from . import chat, ranking, sections, templates, writing
from . import tags as tag_gov  # aliased: 'tags' is used as a tool parameter name
from .note import Note, build_all, build_note, is_excluded

logger = logging.getLogger(__name__)

READ_ONLY = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=False,
)
# create_note: additive write, not destructive. edit_note: can overwrite content.
WRITE = ToolAnnotations(
    readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False
)
EDIT = ToolAnnotations(
    readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False
)

# --- Tool curation -------------------------------------------------------
# The LLM only sees these tools. Everything else upstream registers stays in the
# code but is un-advertised (pruned via mcp.remove_tool) -- fully reversible.
OUR_TOOLS = {"search_notes", "get_note", "vault_map", "create_note", "edit_note", "archive_chat"}
# Upstream low-level tools we deliberately keep exposed.
KEEP_UPSTREAM = {"vault_search_frontmatter", "vault_move"}
# Writes now go through our house-style create_note / edit_note, so upstream's
# raw write tools (vault_write/edit/append) are pruned too.
ALLOWLIST = OUR_TOOLS | KEEP_UPSTREAM

# vault_map payload caps. recent is purely informational, so it stays small;
# tags are the governed vocabulary the model must reuse, so the cap is only a
# safety bound for a pathological vault (normal vaults sit well under it).
MAX_RECENT = 10
MAX_TAGS = 80
MAX_FOLDERS = 60  # folder-tree entries returned by vault_map


# Output-model field descriptions are re-sent to the model every turn (they live
# in each tool's outputSchema), yet the model already sees the structured values.
# So we keep a description ONLY where it steers the model's next action — the id
# to pass to get_note, the tag-governance fields, and the status enums. The rest
# are self-evident from their names and are left undescribed to save tokens.

class SearchResult(BaseModel):
    id: str = Field(description="Pass to get_note for the full note.")
    title: str
    bucket: str
    tags: list[str]
    created: str | None
    summary: str
    snippet: str
    score: float


class NoteContent(BaseModel):
    id: str
    title: str
    bucket: str
    tags: list[str]
    created: str | None
    source: str | None
    content: str


class NoteRef(BaseModel):
    id: str = Field(description="Pass to get_note.")
    title: str
    bucket: str | None = None
    status: str | None = None


class VaultMap(BaseModel):
    total_notes: int
    buckets: dict[str, int]
    folders: dict[str, int] = Field(description="Existing folder paths -> note count. File new notes INTO one of these (via create_note's `folder`) instead of making near-duplicates.")
    active_projects: list[NoteRef]
    tags: list[str] = Field(description="Approved tags — reuse these; do NOT invent tags outside this list.")
    recent: list[NoteRef]


class CreateResult(BaseModel):
    created: bool
    status: str = Field(description="created | exists | overwritten | needs_bucket")
    id: str | None = None
    path: str | None = None
    bucket: str | None = None
    folder: str | None = Field(default=None, description="Subfolder the note was filed in (None = bucket root).")
    new_folder: bool = Field(default=False, description="True if a NEW folder was created (vs filed into an existing one).")
    similar_folders: list[str] = Field(default_factory=list, description="Existing folders close to a new one — refile there to avoid duplicates.")
    tags_used: list[str] = Field(default_factory=list)
    proposed_tags: list[str] = Field(default_factory=list, description="New tags NOT applied (need approve_new_tags).")
    suggestions: list[str] = Field(default_factory=list, description="Valid buckets, when status=needs_bucket.")
    message: str = ""


class EditResult(BaseModel):
    ok: bool
    id: str
    operation: str
    proposed_tags: list[str] = Field(default_factory=list, description="New tags NOT applied (need approve_new_tags).")
    message: str = ""


class ChatArchiveResult(BaseModel):
    created: bool
    status: str = Field(description="created | continued | exists")
    id: str
    path: str | None = None
    raw_id: str | None = None
    tags_used: list[str] = Field(default_factory=list)
    proposed_tags: list[str] = Field(default_factory=list, description="New tags NOT applied (need approve_new_tags).")
    message: str = ""


class SecondBrainExtension(Extension):
    """Adds ranked, stingy retrieval tools to the upstream secure server."""

    def __init__(self) -> None:
        self._notes: dict[str, Note] = {}
        self._lock = threading.Lock()

    # -- lifecycle hooks ---------------------------------------------------

    def before_indexes_start(self, frontmatter_index) -> None:
        self._rebuild_all()
        # Mirror the upstream index's debounced .md changes into our content index.
        frontmatter_index.add_change_listener(self._on_change)

    # -- index maintenance -------------------------------------------------

    def _rebuild_all(self) -> None:
        notes = {n.id: n for n in build_all()}
        with self._lock:
            self._notes = notes
        logger.info("second_brain_ext: content index built (%d notes)", len(notes))

    def _on_change(self, abs_path: str, exists: bool) -> None:
        try:
            rel = Path(abs_path).relative_to(config.VAULT_PATH).as_posix()
        except ValueError:
            return
        if is_excluded(rel):  # ignore meta/hidden files (e.g. _claude-tags.md)
            return
        if exists:
            self._refresh(rel)
        else:
            with self._lock:
                self._notes.pop(rel, None)

    def _refresh(self, rel: str) -> None:
        """Rebuild a single note in the index immediately (after our own writes)."""
        if is_excluded(rel):
            with self._lock:
                self._notes.pop(rel, None)
            return
        note = build_note(rel)
        with self._lock:
            if note is not None:
                self._notes[rel] = note
            else:
                self._notes.pop(rel, None)

    def _buckets(self) -> set[str]:
        """Canonical PARA buckets plus any existing top-level folders in the vault."""
        existing = {n.bucket for n in self._snapshot() if n.bucket}
        return set(templates.CANONICAL_BUCKETS) | existing

    def _snapshot(self) -> list[Note]:
        with self._lock:
            return list(self._notes.values())

    def _folder_counts(self) -> dict[str, int]:
        """Every folder that holds notes -> note count (full vault-relative paths)."""
        counts: dict[str, int] = {}
        for n in self._snapshot():
            parts = n.id.split("/")
            if len(parts) > 1:
                folder = "/".join(parts[:-1])
                counts[folder] = counts.get(folder, 0) + 1
        return counts

    def _subfolders(self, bucket: str) -> set[str]:
        """Subfolder paths under ``bucket`` (relative to it), for folder governance."""
        prefix = bucket + "/"
        return {
            f[len(prefix):]
            for f in self._folder_counts()
            if f.startswith(prefix)
        }

    def _get(self, note_id: str) -> Note | None:
        with self._lock:
            return self._notes.get(note_id)

    def _vault_map(self, recent_limit: int = 10) -> "VaultMap":
        notes = self._snapshot()
        buckets: dict[str, int] = {}
        for n in notes:
            key = n.bucket or "(root)"
            buckets[key] = buckets.get(key, 0) + 1
        projects = sorted(
            (NoteRef(id=n.id, title=n.title, status=n.status)
             for n in notes if n.bucket.lower() == "projects"),
            key=lambda r: r.title.lower(),
        )
        recent = sorted(notes, key=lambda n: (n.modified or ""), reverse=True)
        keep = min(max(0, recent_limit), MAX_RECENT)  # clamp, never blow the payload
        recent_refs = [
            NoteRef(id=n.id, title=n.title, bucket=n.bucket or "(root)")
            for n in recent[:keep]
        ]
        folders = dict(sorted(self._folder_counts().items())[:MAX_FOLDERS])
        return VaultMap(
            total_notes=len(notes),
            buckets=dict(sorted(buckets.items())),
            folders=folders,
            active_projects=projects,
            tags=tag_gov.tag_vocabulary(notes)[:MAX_TAGS],
            recent=recent_refs,
        )

    # -- tools -------------------------------------------------------------

    def register_tools(self, mcp) -> None:
        ext = self

        @mcp.tool(title="Search notes", annotations=READ_ONLY)
        def search_notes(
            query: str,
            limit: int = 5,
            bucket: str | None = None,
            tags: list[str] | None = None,
            date_from: str | None = None,
            date_to: str | None = None,
        ) -> list[SearchResult]:
            """Search the user's Obsidian vault (their "second brain"). Use
            whenever the user refers to something they saved, asks what their
            notes say about a topic, or their own material would clearly help.
            Returns ranked snippets + summaries, NOT full notes — call get_note
            with a returned id if a snippet isn't enough.

            Filters: bucket (top-level folder), tags (note must have all),
            date_from / date_to (ISO dates).
            """
            hits = ranking.search(
                ext._snapshot(),
                query,
                limit=limit,
                bucket=bucket,
                tags=tags,
                date_from=date_from,
                date_to=date_to,
            )
            return [
                SearchResult(
                    id=h.note.id,
                    title=h.note.title,
                    bucket=h.note.bucket,
                    tags=h.note.tags,
                    created=h.note.created,
                    summary=h.note.summary,
                    snippet=h.snippet,
                    score=h.score,
                )
                for h in hits
            ]

        @mcp.tool(title="Get note", annotations=READ_ONLY)
        def get_note(id: str, section: str | None = None, outline: bool = False) -> NoteContent:
            """Retrieve a saved note by its id (the path returned by
            search_notes). Use after search_notes when a snippet isn't enough.

            For long notes, read cheaply: pass `outline=true` to get just the
            note's headings (a map), then pass `section` (one of those headings)
            to get back ONLY that section instead of the whole file. An unknown
            `section` errors with the list of available headings.
            """
            note = ext._get(id) or build_note(id)
            if note is None:
                raise ValueError(
                    f"No note with id '{id}'. Call search_notes first to get a valid id."
                )
            # Read fresh content through the upstream path-safe reader.
            content, _meta = read_file(id)
            if outline:
                heads = sections.outline(content)
                content = "\n".join(heads) if heads else "(this note has no headings)"
            elif section:
                extracted = sections.extract_section(content, section)
                if extracted is None:
                    heads = sections.outline(content)
                    hint = " | ".join(heads) if heads else "(this note has no headings)"
                    raise ValueError(
                        f"No section '{section}' in '{id}'. Available headings: {hint}"
                    )
                content = extracted
            return NoteContent(
                id=note.id,
                title=note.title,
                bucket=note.bucket,
                tags=note.tags,
                created=note.created,
                source=note.source,
                content=content,
            )

        @mcp.tool(title="Vault map", annotations=READ_ONLY)
        def vault_map(recent_limit: int = 10) -> VaultMap:
            """Cheap structural overview — call BEFORE creating or filing a note
            so it lands in the right place with approved tags. Returns
            buckets+counts, the existing folder tree (file new notes into one of
            these via create_note's `folder`, don't make near-duplicates), current
            projects with status, the approved tag vocabulary (do NOT invent tags
            outside it), recent notes, and the total. Titles and ids only, never
            bodies.
            """
            return ext._vault_map(recent_limit)

        @mcp.tool(title="Create note", annotations=WRITE)
        def create_note(
            title: str,
            bucket: str,
            content: str = "",
            tags: list[str] | None = None,
            source: str | None = None,
            status: str | None = None,
            folder: str | None = None,
            approve_new_tags: bool = False,
            overwrite: bool = False,
        ) -> CreateResult:
            """Create a note, filed in the right PARA bucket with house-style
            frontmatter and a type template. Call vault_map first for a valid
            `bucket` (Projects/Areas/Resources/Archives/Daily Notes), approved
            `tags`, AND the existing `folders` — pass `folder` (a path under the
            bucket, e.g. 'Historic Figures/Napoleon') to file the note in the
            right place rather than the bucket root. This tool enforces placement,
            template, tag governance, and an idempotent filename.

            Tags must be from the approved vocabulary; unknown ones are returned
            in `proposed_tags` (NOT applied) unless `approve_new_tags=true`. A
            `folder` that nearly matches an existing one snaps to it (no duplicate
            folders); a genuinely new folder is created and flagged in `new_folder`
            with close existing folders in `similar_folders`. Unknown `bucket` →
            nothing written, status='needs_bucket'. Existing title →
            status='exists' (use edit_note or overwrite=true).
            """
            canonical = templates.normalize_bucket(bucket, ext._buckets())
            if canonical is None:
                return CreateResult(
                    created=False, status="needs_bucket",
                    suggestions=sorted(ext._buckets()),
                    message=f"Unknown bucket '{bucket}'. Choose one of the suggestions and retry.",
                )
            # One-time: seed the approved-tag file from existing usage.
            tag_gov.ensure_approved_file(ext._snapshot())
            approved = tag_gov.tag_vocabulary(ext._snapshot())
            used, proposed = tag_gov.validate(tags, approved)
            if approve_new_tags and proposed:
                tag_gov.add_approved(proposed)
                used, proposed = used + proposed, []

            # Folder governance: snap a requested subfolder to an existing one
            # (case/format-insensitive) so the tree doesn't sprawl with near-dupes.
            req_folder = (folder or "").strip().strip("/")
            if req_folder.lower().startswith(canonical.lower() + "/"):
                req_folder = req_folder[len(canonical) + 1:]  # tolerate a bucket-prefixed path
            resolved_folder, new_folder, similar = templates.normalize_folder(
                req_folder, ext._subfolders(canonical)
            )

            note_type = templates.note_type_for(canonical)
            fm, body = templates.build(note_type, title, content, source, status, used)
            body = writing.apply_house_style(body)
            res = writing.create(canonical, resolved_folder, title, fm, body, overwrite=overwrite)
            if res["created"]:
                ext._refresh(res["id"])
            msg = (
                f"Created {res['id']}" if res["created"]
                else f"A note already exists at {res['id']}; use edit_note or overwrite=true."
            )
            if res["created"] and new_folder and resolved_folder:
                msg += f" (new folder '{resolved_folder}')"
                if similar:
                    msg += f"; similar existing: {', '.join(similar)}"
            return CreateResult(
                created=res["created"], status=res["status"], id=res["id"],
                path=res["path"], bucket=canonical, folder=resolved_folder,
                new_folder=bool(new_folder and res["created"]), similar_folders=similar,
                tags_used=used, proposed_tags=proposed, message=msg,
            )

        @mcp.tool(title="Edit note", annotations=EDIT)
        def edit_note(
            id: str,
            operation: str,
            content: str = "",
            section: str | None = None,
            frontmatter: dict | None = None,
            approve_new_tags: bool = False,
        ) -> EditResult:
            """Edit a note by id. operation:
            - 'append': add `content` to the end.
            - 'replace_section': replace the body under heading `section`.
            - 'set_frontmatter': merge the `frontmatter` dict (its tags are
              governed: unknown ones skipped unless approve_new_tags=true).

            Token-efficient: send only the changed slice, never the whole note.
            """
            note = ext._get(id) or build_note(id)
            if note is None:
                raise ValueError(
                    f"No note with id '{id}'. Call search_notes first to get a valid id."
                )
            op = operation.strip().lower()
            proposed: list[str] = []
            if op == "append":
                writing.append(id, writing.apply_house_style(content))
            elif op == "replace_section":
                if not section:
                    raise ValueError("replace_section requires a 'section' heading.")
                writing.replace_section(id, section, writing.apply_house_style(content))
            elif op == "set_frontmatter":
                fields = dict(frontmatter or {})
                if "tags" in fields:
                    approved = tag_gov.tag_vocabulary(ext._snapshot())
                    used, proposed = tag_gov.validate(fields.get("tags") or [], approved)
                    if approve_new_tags and proposed:
                        tag_gov.add_approved(proposed)
                        used, proposed = used + proposed, []
                    fields["tags"] = used
                writing.set_frontmatter(id, fields)
            else:
                raise ValueError(
                    "operation must be 'append', 'replace_section', or 'set_frontmatter'."
                )
            ext._refresh(id)
            return EditResult(ok=True, id=id, operation=op, proposed_tags=proposed,
                              message=f"{op} applied to {id}")

        @mcp.tool(title="Archive chat", annotations=WRITE)
        def archive_chat(
            title: str,
            summary: str,
            source: str,
            decisions: list[str] | None = None,
            open_questions: list[str] | None = None,
            key_points: list[str] | None = None,
            tags: list[str] | None = None,
            project: str | None = None,
            participants: list[str] | None = None,
            raw_transcript: str | None = None,
            approve_new_tags: bool = False,
            continue_id: str | None = None,
        ) -> ChatArchiveResult:
            """Save a distilled memory of THIS conversation so any LLM can reuse
            it later (cross-tool, cross-project memory). YOU distill it: a tight
            `summary` plus optional `decisions`, `open_questions`, `key_points`.
            `source` is the assistant (claude / chatgpt / gemini). Optionally link
            a `project` (its title) and pass `raw_transcript` to store the full
            text as a linked file (kept out of search). Keep `summary` small — do
            NOT paste the whole conversation; that's the point.

            Tags governed (unknown → proposed_tags unless approve_new_tags). Pass
            `continue_id` to append a dated update to an existing archive.
            """
            tag_gov.ensure_approved_file(ext._snapshot())
            approved = tag_gov.tag_vocabulary(ext._snapshot())
            used, proposed = tag_gov.validate(tags, approved)
            if approve_new_tags and proposed:
                tag_gov.add_approved(proposed)
                used, proposed = used + proposed, []

            # Continuation: append a dated section to an existing archive.
            if continue_id:
                rel = continue_id if continue_id.endswith(".md") else chat.distilled_rel(continue_id)
                if (ext._get(rel) or build_note(rel)) is None:
                    raise ValueError(f"No chat archive with id '{continue_id}' to continue.")
                writing.append(
                    rel,
                    writing.apply_house_style(
                        chat.build_continuation(summary, decisions, open_questions, key_points)
                    ),
                )
                ext._refresh(rel)
                return ChatArchiveResult(created=False, status="continued", id=rel,
                                         tags_used=used, proposed_tags=proposed,
                                         message=f"Appended update to {rel}")

            chat_id = chat.make_id(source, title)
            rel = chat.distilled_rel(chat_id)
            raw_saved = None
            link = None
            if raw_transcript and raw_transcript.strip():
                raw_saved = writing.write_raw(chat.raw_rel(chat_id), raw_transcript)
                link = chat.raw_link(chat_id)

            fm, body = chat.build_distilled(
                title, summary, source, decisions, open_questions, key_points,
                used, project, participants, link,
            )
            res = writing.write_at(rel, fm, writing.apply_house_style(body))
            if res["created"]:
                ext._refresh(rel)
            return ChatArchiveResult(
                created=res["created"], status=res["status"], id=rel, path=res["path"],
                raw_id=raw_saved, tags_used=used, proposed_tags=proposed,
                message=(f"Archived chat to {rel}" + (f" (+ raw {raw_saved})" if raw_saved else "")),
            )

        # Curate the tool surface: hide everything not in ALLOWLIST. Runs after
        # upstream and our tools are registered; reversible (code is untouched).
        for tool in list(mcp._tool_manager.list_tools()):
            if tool.name not in ALLOWLIST:
                try:
                    mcp.remove_tool(tool.name)
                except Exception:
                    logger.warning("second_brain_ext: could not remove tool %s", tool.name)
        logger.info(
            "second_brain_ext: tool surface curated -> %s",
            sorted(t.name for t in mcp._tool_manager.list_tools()),
        )
