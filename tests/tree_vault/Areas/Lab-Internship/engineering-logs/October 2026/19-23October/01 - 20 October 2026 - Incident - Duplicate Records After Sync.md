---
tags: [lab-internship, incident, software]
created: 2026-10-20
---


# 01 - 20 October 2026 - Incident - Duplicate Records After Sync

After the shared hub synced, 31 measurement records appeared twice with new ids.
Root cause: the merge step keyed on file name instead of the stable record id.
Fixed in v0.4.11 by merging on id and offering a restore of the earlier ids.

## Related
- [[00 - Index|19-23 October]]
