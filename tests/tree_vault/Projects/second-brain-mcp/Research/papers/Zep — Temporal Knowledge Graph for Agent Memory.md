---
tags: [research/papers, agent-memory, knowledge-graph]
created: 2026-06-28
---


# Zep — Temporal Knowledge Graph for Agent Memory

## Relevance to Second Brain MCP
Episodes are turned into entities and edges with bi-temporal validity: every fact
records when it became true and when it was invalidated, instead of being
overwritten. Retrieval fuses cosine, BM25 and breadth-first graph search, then
reranks.
