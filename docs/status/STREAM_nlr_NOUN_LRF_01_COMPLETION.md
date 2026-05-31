# Completion Report — NOUN-LRF-01 (LearnedReference noun substrate)

- **Stream:** nlr
- **Branch:** stream/nlr-learnedref-noun-substrate
- **Base:** 816dbe2 (merge: NOUN-ASC-01)
- **HEAD:** 5c49e94
- **Mission:** docs/missions/inflight/MISSION_NOUN_LRF_01.md
- **Date:** 2026-05-30
- **Outcome:** ✅ COMPLETE — both legs green, Adams CLEARED.

## Summary

Built the `learnedReference` noun substrate — value type + operational
accessors, `learned_references` table, and store persistence — in both legs
(Swift + Rust), structurally mirroring the `Association` content+anchor noun.
No verb behaviour. The verb missions (learn / recall / mutate / withdraw /
expunge) can now target `learnedReference`.

Three commits:
- `3f13d8e` feat(locuskit): LearnedReference noun type model — Swift+Rust
- `18725f6` feat(locuskit): learned_references table schema — Swift+Rust
- `5c49e94` feat(locuskit): learned_reference store + conformance — Swift+Rust

## Decisions (source-grounded; mission Context overridden per "Read First")

The mission Context sketched a KGFact-shaped triple with a `grounding_ref`
column. Both Smythe pre-flight instances (independently) found that draft
ungrounded and the spec/cookbook authoritative. Per the mission Read First
("source is ground truth; when a doc and the code disagree, follow the code
and note the drift"):

1. **Field shape follows arch spec §7.8.2** `LearnedReference {rowID, source:
   SourceCatalogEntry, handle: String, mode: LearnMode, 3 bitmaps}`, not a
   triple. Reconciliations:
   - `source: SourceCatalogEntry` → `sourceCatalogID: String`. The
     `SourceCatalogEntry` type is spec-only / unimplemented anywhere in the
     codebase; the substrate stores a reference to the catalog entry as an
     identifier string, exactly as `KGFact` stores `sourceDrawerID` rather
     than embedding a `Drawer`.
   - `mode: LearnMode` lives in `operationalBitmap` (cookbook §2.4 bit 12),
     not as a stored struct field — consistent with every other LocusKit
     noun (operational axes are bitmap accessors). Cookbook v1.0 supersedes
     the v0.8 spec on bitmap layout (I-15 6-bit floor).
2. **No `grounding_ref` column.** No `GroundingSpec` / `groundingColumn` /
   `grounding_ref` exists anywhere in the codebase or cookbook. The grounding
   nature of `learn` is captured by `Flow.groundingDriven` (`Verb.swift`),
   which describes verb *initiation*, not a storage column.
3. **Operational bitmap = cookbook §2.4 LearnedReference layout**
   (temporal-dominant): refresh_policy (bits 0–5, scale-gapped), drift_severity
   (bits 6–11, scale-gapped), mode (bit 12), source (bits 13–18, contiguous).
4. **No schema version bump.** Declarative schema, no migration ladder —
   matches NOUN-PRO-01 / NOUN-ASC-01. Both legs stay version 1.
5. **Structural template = `Association`, not `KGFact`.** Association is the
   freshest content-bearing noun that honours the §2.7 lattice-anchor
   requirement; KGFact predates it and carries no anchor. LearnedReference is
   `Equatable, Codable, Sendable` but not `Hashable` (embedded `LatticeAnchor`
   is not `Hashable`), matching Association; the Rust port derives
   `PartialEq, Eq` but not `Hash`.

## Blast Radius

11 files (5 new, 6 edited) — see `docs/blast_radius/NOUN_LRF_01_BLAST_RADIUS.md`.
Mission predicted 6; the +5 are the store-surface mirror + Rust module/trait
wiring that Part 3 forces but the mission's file table under-listed (a
recurring store-surface scoping gap Smythe and Adams both noted for Skippy).
All edits additive; 0 deletions. No forbidden files touched.

## Smythe Pre-flight — YELLOW (two independent instances, converged)

Both instances cleared terrain as navigable and overturned the mission's draft
field design before any code was written:

- **Baseline clean** (the draft worry about a `countAssociations` breakage was
  false): Swift 441 tests / 40 suites green, Rust 390 green at mission start.
- **Blast radius**: 6 listed → 8+ real; `DrawerStore.swift` and Rust
  `lib.rs` / `drawer_store_inmemory.rs` are unavoidable additive edits.
- **Field design**: not grounded in the draft; follow spec §7.8.2 +
  cookbook §2.4; no `grounding_ref`; `mode` in the bitmap.
- **Schema version**: actually 1, not 4 — do **not** bump.

Verdict: YELLOW, proceed with the corrections above (all adopted).

## Adams Post-flight — BLOCKED → CLEARED

**First pass: BLOCKED.** The Rust leg did not compile (15 errors). Root cause:
`learned_reference` was never declared in `lib.rs` (Edit had silently failed
during a tool-output-delay window; the module was an orphan, so its inline
tests never ran and an interim "407 passed" claim was based on stale output).
Cascading: `T_LEARNED_REFERENCES` undefined; `learned_reference_values`
returned `Vec` instead of `BTreeMap`; phantom `opt_text`/`opt_timestamp`
helpers; `learned_reference.rs` imported non-existent `crate::bitmap_ops`
extract fns. Swift leg was clean throughout.

**Fixes applied** (folded into 5c49e94):
1. `lib.rs`: `pub mod learned_reference;` + `#[cfg(test)] mod learned_reference_tests;`.
2. `drawer_store_inmemory.rs`: `const T_LEARNED_REFERENCES`; `learned_reference_values`
   rewritten as `BTreeMap` with inline `.map(...).unwrap_or(TypedValue::Null)`.
3. `learned_reference.rs`: bit extraction via `substrate_kernel::bit_field`
   (the primitive `association_operational.rs` uses); bit-12 mode via
   `extract_field(op,12,1) != 0`.

**Re-review: CLEARED.** Adams re-ran both legs: Rust 407 passed / 0 failed,
Swift 460 / 41 suites passed. Blast radius 11/11 exact, all-additive, no
forbidden touches, no prohibited patterns. Two non-blocking INFO findings:
(1) a stale `crate::bitmap_ops` mention in a doc comment (fixed in this
report's accompanying commit); (2) Rust `RefreshPolicy`/`DriftSeverity` lack a
`PartialOrd` derive that the Swift `Comparable` ordering tests exercise — left
as-is per Rust convention (derive ordering only when load-bearing), to be added
if a verb mission needs it. Post-flight doc:
`docs/blast_radius/NOUN_LRF_01_POSTFLIGHT.md`.

## Test Verification Log

### Baseline (mission start)
- Swift: 441 tests / 40 suites, all passed.
- Rust: 390 passed; 0 failed.

### Final
- **Swift** — `cd packages/kits/LocusKit && swift test`
  - Exit code: 0
  - Result: `Test run with 460 tests in 41 suites passed`
  - Delta: +19 tests, +1 suite (`LearnedReferenceTests`). Zero build warnings.
- **Rust** — `cd packages/kits/LocusKit/rust && cargo test --lib`
  - Exit code: 0
  - Result: `test result: ok. 407 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`
  - Delta: +17 (8 inline operational in `learned_reference.rs` + 9 store
    conformance in `learned_reference_tests.rs`).
  - One **pre-existing** warning: `unused_mut` at `drawer_store_inmemory.rs:3164`
    (`let mut e1 = DiaryEntry`), an existing diary test — present at the base
    commit (line 3007), shifted down by this mission's insertions. Not
    introduced by NOUN-LRF-01 (Adams cross-checked the base).

Coverage: round-trip persist/fetch; bitmap byte-identity (3 columns, distinct
regions); content (handle + sourceCatalogID) survival; lattice-anchor required
(§2.7); source-index resolution + ordering; tombstone exclusion; table
isolation; operational-bitmap decode for all four §2.4 axes. Rust mirrors Swift
case-for-case (gate I-19) except the two documented divergences (ephemeral
in-memory store has no `idempotentReopen` counterpart — same as
association/proposal; Rust ordering enums not `PartialOrd`).

## Self-review

- **Both legs build clean, tests green** — verified by re-run, exit 0 both.
- **Conformance**: Swift and Rust value types, operational layouts, schema
  table/indices, and store round-trips are symmetric. Schema `table_count_and_order`
  and `index_names_match_swift_order` Rust conformance tests pass with
  `learned_references` inserted at the same position (8) on both legs.
- **No verb behaviour** shipped, as required.
- **Honest note on process**: the Rust wiring break in the first Part 3 commit
  was caused by writing code against stale/garbled reads during a sustained
  tool-output-delay window, and an interim green claim that did not reflect the
  real compile state. Adams caught it; it was fixed and independently re-verified
  green. The lesson (also logged by Adams): clustered Rust compile errors trace
  to a missing `lib.rs` module declaration — check the module registry first.

## Success criteria — met

LearnedReference noun substrate exists in both legs (type + table + store),
mirroring the Association content+anchor pattern. A row round-trips
byte-identically with content + provenance intact. The verb missions can now
target `learnedReference`. No verb behaviour.

## Signal

Wrote `/Users/bob/devlop/ddfactory/control/signals/.done-nlr`.
