# Blast Radius Report — W1_ACK

**Baseline:** swift test pass count at mission start: 536
**Mission:** Acknowledgment calling stance for changed MCP commands (Bob directive 2026-07-28)
**Stream:** stream/w1-ack

Symbols being changed:

1. `RecipeTools.dispatch` (Swift) — ACK gate added for `moot_consolidate` and `moot_recall_distilled`; `moot_recollect` stub reinstated
2. `RecipeTools.isRecipeTool` (Swift) — `moot_recollect` added back to dispatch routing
3. `RecipeTools.recallDistilledTool` (Swift) — `ack` parameter added to inputSchema
4. `recipe_tools::dispatch` (Rust) — ACK gate added for `CONSOLIDATE` and `RECALL_DISTILLED`; `RECOLLECT` stub added
5. `recipe_tools::is_recipe_tool` (Rust) — `RECOLLECT` added
6. `tool_list::recall_distilled_tool` (Rust) — `ack` parameter added to schema
7. `LongMemEvalRunner.swift` (mcp-benchmarker) — `moot_consolidate` → `moot_distill`
8. `longmemeval_runner.rs` (mcp-benchmarker Rust) — `"moot_consolidate"` → `"moot_distill"`

---

## Symbol 1: RecipeTools.dispatch (Swift)

**Change class:** semantic — ACK gate added before `runDistill` (alias arm only), before
`runRecallDistilled`, and `moot_recollect` handled as a never-execute stub
**Scope:** internal (enum type, static method)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | 428 | codegraph | MUST_UPDATE | RecipeTools.dispatch call site; comment must reflect new gate |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/RecipeToolsTests.swift | various | grep | MUST_UPDATE | New tests: notice-when-missing, execute-when-acked, wrong-token→notice, recollect-stub |

### Summary
- MUST_UPDATE: 2 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 2: RecipeTools.isRecipeTool (Swift)

**Change class:** additive — `moot_recollect` added to the routing set
**Scope:** internal

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | 393 | codegraph | INTENTIONALLY_LEFT | `isRecipeTool` called in dispatch router; behavior correct once moot_recollect is in the set |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/RecipeToolsTests.swift | various | grep | MUST_UPDATE | New tests cover the stub dispatch path |

### Summary
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 1 site (ToolDispatch.swift router — no change needed there)
- RESCOPE_REQUIRED: 0

---

## Symbol 3: RecipeTools.recallDistilledTool inputSchema (Swift)

**Change class:** additive — `ack` optional string parameter added
**Scope:** private (descriptor builder)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift | 115-127 | codegraph | MUST_UPDATE | tools() calls recallDistilledTool(); schema update flows through automatically |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/ToolProjectionTests.swift | various | grep | MUST_UPDATE | schema-exposes-param test and description-contains-token test needed |

### Summary
- MUST_UPDATE: 2 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 4–6: Rust equivalents

**Change class:** mirrors Swift — ACK gate in dispatch, RECOLLECT constant + routing, ack schema
**Scope:** pub(crate) / pub functions

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/rust/src/dispatch.rs | various | codegraph | INTENTIONALLY_LEFT | Calls recipe_tools::dispatch and is_recipe_tool; routing is unchanged |
| packages/kits/AriaMcpKit/rust/tests/dispatch_tests.rs | various | grep | MUST_UPDATE | New tests: roster pin updated, ACK gate tests, recollect stub test |

### Summary
- MUST_UPDATE: 1 site (dispatch_tests.rs)
- INTENTIONALLY_LEFT: 1 site (dispatch.rs — router unchanged)
- RESCOPE_REQUIRED: 0

---

## Symbol 7–8: mcp-benchmarker moot_consolidate callers

**Change class:** rename — `moot_consolidate` → `moot_distill` at call sites
**Scope:** apps/mcp-benchmarker/Sources and rust/src

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| apps/mcp-benchmarker/Sources/mcp-benchmarker/LongMemEvalRunner.swift | 587 | grep | MUST_UPDATE | Calls moot_consolidate; update to moot_distill |
| apps/mcp-benchmarker/rust/src/longmemeval_runner.rs | 608 | grep | MUST_UPDATE | Calls "moot_consolidate"; update to "moot_distill" |
| apps/mcp-benchmarker/rust/src/longmemeval_runner.rs | 194–196 | grep | MUST_UPDATE | Stale doc comment referencing moot_consolidate and old factoid model |
| apps/mcp-benchmarker/rust/src/longmemeval_runner.rs | 44 | grep | INTENTIONALLY_LEFT | Comment "moot_recall_distilled with distilled factoid payload" — stale description but no code impact; update comment |
| apps/mcp-benchmarker/README.md | 59 | grep | INTENTIONALLY_LEFT | Prose reference to moot_recall_distilled/moot_consolidate in a changelog comparison context; not a call site |

### Summary
- MUST_UPDATE: 3 sites (Swift call, Rust call, stale Rust doc comment)
- INTENTIONALLY_LEFT: 2 sites (README prose, Rust comment line 44 with partial truth)
- RESCOPE_REQUIRED: 0

---

## Overall Summary

- MUST_UPDATE: 9 sites across 5 files
- INTENTIONALLY_LEFT: 4 sites (all documented)
- RESCOPE_REQUIRED: 0
