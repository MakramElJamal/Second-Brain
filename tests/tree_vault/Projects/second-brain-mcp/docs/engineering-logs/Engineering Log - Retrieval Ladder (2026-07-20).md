---
tags: [projects, second-brain-mcp, engineering-log]
created: 2026-07-20
---


# Engineering Log - Retrieval Ladder (2026-07-20)

Designed the retrieval ladder: exact title match first, then lexical, then
semantic, then a wikilink graph hop. Each rung only runs if the cheaper one did not
answer, which keeps the average call token-light.
