---
name: mootx01-start
description: Orient a Codex task to its connected MOOT estate when the user requests MOOT startup or an availability and capability overview. Discover tools without importing, reindexing, or changing the estate.
---

# MOOTx01 start

Use the MOOT MCP connection available in this task. Discover its tools through
the host's tool inventory/search if they are deferred; do not assume a name
mentioned in a skill is callable.

1. Call `moot_estate_ping`, then `moot_estate_status`.
2. Read the relevant agent journal when continuity matters. Inspect
   `moot_estate_map` when stored structure matters.
3. If analysis is needed, use `moot_list_lenses` and, if recipe details are
   relevant, `moot_list_recipes`. These are partial catalogs, not the complete
   MCP tool inventory. Use `teachme: true` for an unfamiliar tool when supported.
4. Report connected estate identity, available capabilities relevant to this
   task, and the proposed first use. Keep live inventory separate from features
   merely documented in a repository or plugin.

This is orientation. Do not file new memories, import content, run maintenance,
install software, or create a new Codex task as a side effect. Follow a separate
user request to continue if one was supplied.

If connection fails or tools are absent, report the observed failure and work
from current context. Do not infer the binary is missing from a failed ping;
connection, daemon, permission, and configuration failures need different fixes.
Do not fall back to direct estate files or CLI data access.
