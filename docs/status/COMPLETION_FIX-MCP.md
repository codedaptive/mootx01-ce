---
version: v0.1
---

# COMPLETION: FIX-MCP

**Status:** COMPLETE

**Stream:** stream/fix-mcp
**Worktree:** /Users/bob/devlop/mootx01-ce-fix-mcp

## What Was Done

- **Part A: Unknown-arg hint** — `07e1778f`
  Central dispatch mechanism (Swift + Rust) now appends a hint line to any
  non-error tool result whose call carried unrecognized argument keys.
  Format: `hint: unrecognized argument(s) ignored: <sorted, comma-joined names>`.
  Also logs to stderr for daemon visibility. No hard-reject — loose clients
  continue to receive the tool result.
  - Swift: `ToolDispatcher.appendUnknownArgsHint` + `ToolProjection.acceptedArgKeys(for:)`
  - Rust: `inject_unknown_args_hint` in dispatch.rs + `accepted_arg_keys` in tool_list.rs
  - Tests: `UnknownArgHintTests.swift` (5 tests) + `unknown_arg_hint_tests.rs` (5 tests)

- **Part B: moot_recall_distilled query echo removal** — `f6e54046`
  Default header changes from "found N distilled factoid(s) for: {query}" to
  "found N distilled factoid(s)". Opt-in via `echo_query:true` restores old format.
  Saves ~120+ chars per call. echo_query is DECODED (proven by test — any unrecognized
  arg would trigger Part A's hint, which is checked and must be absent).
  - Swift: RecipeTools.runRecallDistilled + recallDistilledTool() schema
  - Rust: recipe_tools.rs run_recall_distilled_tool + tool_list.rs recall_distilled_tool
  - Conformance vectors: updated 2 payload_text fields in token_efficiency_vectors.json
  - Tests: RecipeToolsTests.swift (2 tests) + unknown_arg_hint_tests.rs (3 tests)

## Test Verification Log

- `swift build` (AriaMcpKit): exit 0
- `swift test` (AriaMcpKit): exit 0, **522 tests** (baseline 515, delta +7)
- `cargo build` (AriaMcpKit/rust): exit 0
- `cargo test` (AriaMcpKit/rust): exit 0, **462 tests** (baseline 454, delta +8)
- `cargo test` (mcp-benchmarker/rust): exit 0, **143 tests** (unchanged)
- `swift test` (mcp-benchmarker): exit 0, **232 tests** (unchanged)

## Discoveries

- `booleanSchema` in ToolProjection is `static func` (internal access, not private) —
  accessible as `ToolProjection.booleanSchema(...)` from RecipeTools. The comment in
  RecipeTools.swift at line 1373-1375 saying "ToolProjection's schema helpers are private"
  was incorrect; left as-is (scope of fix was the compile error, not the comment).
- `optionalBool` is a `ToolDispatcher` instance method — not accessible in the static
  RecipeTools context. Used the manual bool extraction pattern (matching `include_held`)
  instead. This is consistent with how all other bool args are decoded in RecipeTools.
- Rust echo_query header test: the Rust bare test estate returns `isError:true` for
  `moot_recall_distilled` (missing distillation lane) — pre-existing behavior difference
  from Swift (which catches the error and returns "found 0" success). Rust tests check
  `accepted_arg_keys` directly and verify the hint is absent on error results.
- Echo-pattern sweep: only 2 query-echo sites in Swift (both in runRecallDistilled),
  2 in Rust — no other tools echo queries. Sweep complete.

## Outstanding

- Nothing outside mission scope.
