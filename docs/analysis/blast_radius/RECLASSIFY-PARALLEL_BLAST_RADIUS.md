# Blast Radius Report — RECLASSIFY-PARALLEL

**Baseline:** filtered test lanes at mission start — Swift `FdcReclassify`
7 tests pass; Rust `dispatch_tests reclassify` 8 tests pass. Both exit 0.
**Mission:** Parallelize the classify pass of `moot_reclassify_fdc` across
CPU cores; keep the audited write serial and byte-identical.

## Scope classification

This mission changes the **bodies** of two functions only. It does NOT
rename, remove, re-signature, deprecate, or alter the external semantics
of any symbol. No public API, no schema, no bitmap, no persisted field,
no wire contract changes. The classify seam (`EideticLib.lookup(recordNovel:false)`
/ `eidetic_lib::lookup_no_record`) and the write seam
(`reanchorAnchor` / `reanchor_anchor`) are CALLED exactly as before — same
arguments, same order of writes — not modified.

Per the blast-radius skill, a change to a function's internal
implementation that preserves the function's observable contract does not
trigger a caller cascade: the callers of `runReclassifyFDC` /
`run_reclassify_fdc` see byte-identical output (proven by the determinism
test). Therefore the MUST_UPDATE set is the two implementation files plus
the two test files.

## Symbol 1: `ToolDispatcher.runReclassifyFDC` (Swift) — body only
**Change class:** internal implementation (no signature/semantic change)
**Scope:** internal (func on ToolDispatcher; MCP tool `moot_reclassify_fdc`)

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | mission | MUST_UPDATE | Split classify (parallel) from ordered audited write (serial) |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/FdcReclassifyTests.swift | mission | MUST_UPDATE | Add determinism/parity test (additive) |

## Symbol 2: `run_reclassify_fdc` (Rust) — body only
**Change class:** internal implementation (no signature/semantic change)
**Scope:** module fn; MCP tool `moot_reclassify_fdc`

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/AriaMcpKit/rust/src/interface_tools.rs | mission | MUST_UPDATE | Split classify (parallel via std::thread::scope) from ordered audited write (serial) |
| packages/kits/AriaMcpKit/rust/tests/dispatch_tests.rs | mission | MUST_UPDATE | Add determinism/parity test (additive) |

## Dependency decision (Rust)
The mission suggested rayon as one option. rayon is NOT present in the
offline cargo cache, and the gate requires `cargo test --offline` and
`cargo build --locked` to keep passing on both apps. Adding rayon would
break the offline/locked builds. Therefore the Rust leg uses
`std::thread::scope` (stable since 1.63; crate rust-version is 1.75):
**zero new dependencies, zero Cargo.lock churn, no app-lock regeneration
required.** This keeps the blast radius strictly inside the two functions.

## Thread-safety finding (mission gate item #3)
The no-record classify seam is SAFE for concurrent calls on both legs.
All shared mutable state on the `recordNovel:false` path is either not
touched (the novel-token pool cache is skipped in no-record mode) or is a
lock-guarded, concurrency-invariant pure-function memo (the Q-ID closure
memo, guarded by `os_unfair_lock` in Swift / `Mutex` in Rust). Reference
artifacts (FDC bundle, word-class table snapshot, semantic ranker) are
read-only after init (`OnceLock` / lock-guarded `Arc` snapshot / immutable
`&self`). HMM taggers use local DP state only. Full detail in the
completion report. No data race is introduced; no RESCOPE_REQUIRED.

### Summary
- MUST_UPDATE: 4 files (2 impl + 2 test)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0
