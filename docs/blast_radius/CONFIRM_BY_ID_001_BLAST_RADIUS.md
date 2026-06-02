# CONFIRM_BY_ID_001 — Blast Radius Report

**Mission:** id-shaped `confirm_migration_promotion_by_id` in CognitionKit
Rust + wire the Rust MCP server's confirm handler. Rust-only.
**Date:** 2026-06-02. **Filed retroactively** at Adams' post-flight
direction (Finding #1): the mission replaced the semantics of an existing
function, so a BRR was required; the diff was verified complete before
this report was written, so the report CONFIRMS coverage rather than
planning it.

## Symbols changed

| Symbol | Change | Kind |
|---|---|---|
| `run_confirm_promotion_tool` (apps/ARIA_MCP/rust/src/recipe_tools.rs) | body replaced: informational `error_result` → real dispatch through the new overload | semantics change to existing code |
| `confirm_migration_promotion_by_id` (packages/kits/CognitionKit/rust/src/migration_live.rs) | NET-NEW overload; resolves id via `EstateCoordinator::branch_handle_for`, then calls the existing `glk_promote_branch` path | additive |

## MUST_UPDATE call sites (all in diff)

1. `apps/ARIA_MCP/rust/src/recipe_tools.rs` — `run_confirm_promotion_tool`
   body + module docstring's confirm section (boundary language removed).
2. `apps/ARIA_MCP/rust/tests/dispatch_tests.rs` — the
   `confirm_migration_promotion_returns_documented_informational_error`
   test (asserted the old behavior): deleted, replaced by five wired-path
   tests.
3. `apps/ARIA_MCP/rust/README.md` — the confirm v1-boundary section and
   the tool table row (table row caught post-flight, fixed in the notes
   commit).
4. `packages/kits/CognitionKit/rust/src/lib.rs` — `pub use` export of the
   new overload.

## INTENTIONALLY_LEFT

- `confirm_migration_promotion` (report-shaped, migration_live.rs:177):
  body unchanged (fmt line-wrapping only — verified by Adams). The two
  shapes serve different callers: report-in-scope (tests, in-process) vs
  ids-in-hand (the stateless MCP two-call pattern).
- `glk_promote_branch` / `glk_discard_branch` (GLK): untouched — the
  overload calls the same primitives.
- Swift `MigrationBenchmark.confirmPromotion(winnerBranchID:...)`: the
  cross-version behavioral contract this overload mirrors; no Swift edits
  in a Rust-only mission.

## Out-of-scope edits carried in the diff (Adams-judged)

- 21 CognitionKit files: pure `cargo fmt` whitespace (WARNING — future
  missions run fmt as a separate prior chore commit).
- `formal_concepts_recipe.rs:107`: pre-existing `redundant_closure`
  clippy fix required by the `-D warnings` gate (INFO, acceptable).
