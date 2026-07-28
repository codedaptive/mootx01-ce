# Blast Radius Report — FIX-MCP

**Baseline:** swift test pass count at mission start: 515
**Mission:** MCP surface hygiene — unknown-arg hint + recall_distilled query echo removal
**Stream:** stream/fix-mcp
**codegraph status:** not indexed; grep-only blast radius

## Symbols being changed

### Symbol 1: RecipeTools.runRecallDistilled
**Change class:** semantic (response header format change; new optional echo_query arg)
**Scope:** private

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift | 1109, 1119 | grep | MUST_UPDATE | Primary site — header format change |
| packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift | 376–403 | grep | MUST_UPDATE | recallDistilledTool() schema — add echo_query property |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/RecipeToolsTests.swift | 736 | grep | MUST_UPDATE | Asserts old "for:" format — must update to new format |
| packages/kits/AriaMcpKit/rust/src/recipe_tools.rs | 1179, 1184 | grep | MUST_UPDATE | Rust twin — same header change |
| packages/kits/AriaMcpKit/rust/src/tool_list.rs | 878–891 | grep | MUST_UPDATE | Rust tool schema — add echo_query property |
| apps/mcp-benchmarker/conformance/token_efficiency_vectors.json | 151, 165 | grep | MUST_UPDATE | payload_text fields carry old "for: beverage preference" — update for accuracy |

### Symbol 2: ToolDispatcher.dispatch (unknown-arg hint — central mechanism)
**Change class:** additive (new post-dispatch hint check; no existing behavior changed)
**Scope:** public

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | 378–444 | grep | MUST_UPDATE | dispatch function — add appendUnknownArgsHint call |
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolProjection.swift | end | grep | MUST_UPDATE | Add acceptedArgKeys(for:) function |
| packages/kits/AriaMcpKit/rust/src/dispatch.rs | 160–178 | grep | MUST_UPDATE | dispatch_tool_with_vault_ledger_and_flag — add inject_unknown_args_hint call |
| packages/kits/AriaMcpKit/rust/src/tool_list.rs | end | grep | MUST_UPDATE | Add accepted_arg_keys functions |

## New files (additive, no blast radius)

| File | Classification | Notes |
|---|---|---|
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/UnknownArgHintTests.swift | ADDITIVE | New test suite for Part A |

## Summary

- MUST_UPDATE: 11 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

## Test baselines

- Swift AriaMcpKit: 515 tests passing
- Rust AriaMcpKit: 454 tests passing (1 ignored)
- Rust mcp-benchmarker: 143 tests passing
