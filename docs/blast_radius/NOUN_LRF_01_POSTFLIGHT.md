# Adams Post-flight — NOUN-LRF-01

- **Mission:** LearnedReference noun substrate (type + table + store, both legs)
- **Branch:** stream/nlr-learnedref-noun-substrate
- **HEAD reviewed:** 5c49e94
- **Verdict:** CLEARED (after one BLOCKED → fix cycle)
- **Date:** 2026-05-30

## First pass — BLOCKED

Rust leg did not compile (15 errors). Root cause: `learned_reference` never
declared in `lib.rs` (orphan module — an Edit silently failed during a
tool-output-delay window), cascading to: `T_LEARNED_REFERENCES` undefined;
`learned_reference_values` returned `Vec` instead of `BTreeMap`; phantom
`opt_text`/`opt_timestamp` helpers; `learned_reference.rs` imported
non-existent `crate::bitmap_ops` extract fns. An interim "407 passed" claim
was based on stale output and was false at that commit. Swift leg clean.

## Fixes (folded into 5c49e94)

1. `lib.rs`: `pub mod learned_reference;` + `#[cfg(test)] mod learned_reference_tests;`
2. `drawer_store_inmemory.rs`: `const T_LEARNED_REFERENCES`; `learned_reference_values`
   → `BTreeMap` via `m.insert()` + inline `.map(...).unwrap_or(TypedValue::Null)`
3. `learned_reference.rs`: `use substrate_kernel::bit_field;` + `bit_field::extract_field(..)`;
   bit-12 mode via `extract_field(op,12,1) != 0`

## Re-review — CLEARED

- **Rust** (re-run): `cargo test --lib` → exit 0, **407 passed; 0 failed**.
- **Swift** (re-run): `swift test` → exit 0, **460 tests in 41 suites passed**, zero build warnings.
- **Blast radius**: 11/11 exact, 1,566 insertions / 0 deletions — all additive.
- **Forbidden files**: none touched (docs/validation, existing noun types,
  kg_facts/associations declarations, SubstrateLib all clean).
- **Prohibited patterns**: none (no bridges, shims, legacy markers, orphan deprecations).
- **Conformance (I-19)**: Swift↔Rust case-for-case; two documented divergences
  (ephemeral in-memory store → no `idempotentReopen` counterpart; Rust ordering
  enums not `PartialOrd`).
- **Pre-existing warning**: `unused_mut` at `drawer_store_inmemory.rs:3164` —
  existing diary test, present at base (line 3007), not introduced here.

## Findings

- INFO #1: stale `crate::bitmap_ops` mention in a `learned_reference.rs` doc
  comment (import itself was correct) — **fixed** in the docs/cleanup commit.
- INFO #2: Rust `RefreshPolicy`/`DriftSeverity` lack `PartialOrd`; Swift
  `Comparable` ordering tests have no Rust counterpart. Left as-is per Rust
  convention; add if a verb mission makes ordering load-bearing.

No CRITICAL, no WARNING. **Ship it.**
