# Attribution

This project is a fork of and builds directly upon **obsidian-web-mcp** by
Jim Prosser, used under the MIT License.

- Upstream: https://github.com/jimprosser/obsidian-web-mcp
- Upstream license: MIT — original copyright (`Copyright (c) 2026 Contributors`)
  is retained in [LICENSE](LICENSE) alongside this fork's copyright.

The entire secure server substrate — Streamable HTTP transport, OAuth 2.0 +
PKCE login gate, bearer authentication, path-traversal/atomic-write safety,
audit logging, rate limiting, DNS-rebinding protection, and the extension seam —
comes from the upstream project and remains under its copyright.

## What this fork adds

The `second_brain_ext` package adds a token-light retrieval + opinionated write
layer on top of the upstream server via its public extension seam (no fork of
upstream core code). It registers a curated set of tools — `search_notes`,
`get_note` (with section/outline reads), `vault_map`, `create_note`, `edit_note`,
`archive_chat` — and prunes the upstream surface to an allowlist. See
[docs_v1.0.md](docs_v1.0.md) for the full design.

Core upstream modules under `src/obsidian_vault_mcp/` are unmodified, so upstream
security fixes can be merged cleanly.
