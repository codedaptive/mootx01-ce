# COMPLETION: VERB-REA-01 — `reanchor` verb (drawer), both legs

**Status: COMPLETE**
Stream: rea · Branch: `stream/rea-reanchor-drawer`
Baseline: `816dbe2` (NOUN-ASC-01 merge) · Head: `f88c527`
Mission: `docs/missions/inflight/MISSION_VERB_REA_01.md`
Date: 2026-05-30

---

## Summary

`reanchor` is now a real verb in both legs (Swift + Rust). It moves a drawer
to a different room and/or lattice position, recording an audit/provenance
event, and honors the empty-reanchor and not-found contracts. The previously
advertised-but-stubbed `moot_reanchor_drawer` MCP tool now functions.

Semantics implemented (cookbook §2.5 provenance, §2.7 lattice anchor; §10.2
reanchor reference in `SubstrateLib/Verbs.swift`):

- **At least one of `toRoom` / `toLattice` required.** The primary empty
  guard is at the GLK boundary (`VerbSurface.swift:167` raises
  `VerbError.emptyReanchor` before dispatch). LocusKit's `Estate.reanchor`
  adds a belt-and-suspenders guard throwing `LocusKitError.invalidContent`
  (LocusKitError has no `.emptyReanchor` case — that lives on GLK's
  `VerbError`; GLK's `remap` converts a thrown LocusKitError).
- **Absent row → `drawerNotFound`.**
- **Placement change recorded via the store's gated/audited path** (Known
  Ambiguity 1, resolved by reading the store): a new `reanchorGated` mirrors
  `expungeGated` — read the row in a transaction, gate via `AuditGate.admit`,
  update the placement columns and append the audit event atomically. There
  is **no `RowVerb.reanchor` case** (RowVerb is a closed enum), so the audit
  uses `verb: .mutate` (the active→active self-loop), carrying the anchor
  delta via `priorLatticeAnchor` / `afterLatticeAnchor`. The row's three
  bitmaps are passed through **unchanged** (empty `writes`), so reanchor is a
  placement-only mutation — no bitmap state is altered.

## What Was Done

- **Part 1 — reanchor implementation, both legs** — `377422a`
  (`feat(locuskit): implement reanchor verb (drawer) — Swift+Rust`)
  - `EstateVerbs.swift:379` / `estate_verbs.rs:419`: stub → real. Empty guard
    → `invalidContent`; not-found → `drawerNotFound`; delegates to the store.
  - `DrawerStore.swift`: new `reanchorGated(...)` — transaction +
    `AuditGate.admit(verb: .mutate, priorLatticeAnchor:afterLatticeAnchor:)`
    + placement-column update (`udcCode`/facets/wikidata for lattice, `room`
    for room) + audit append, all atomic. Mirrors `expungeGated`.
  - `drawer_store.rs`: `reanchor_gated` trait default. `drawer_store_inmemory.rs`:
    concrete impl on `InMemoryDrawerStore`. `lib.rs`: `mod reanchor_tests;`.
  - Rust stub test `reanchor_stub_returns_invalid_content` (was
    `estate_verbs.rs:656`) removed and replaced with real behavior tests.
- **Part 2 — conformance suite, both legs** — `4965598`
  (`test(locuskit): reanchor conformance — Swift+Rust`)
  - `ReanchorTests.swift` (new, 13 tests) + `reanchor_tests.rs` (new, 13
    tests) — case-for-case mirror (I-19).
- **Post-flight fix** — `f88c527`
  (`test(glk): rename reanchor round-trip test to match its behavior`)
  - Adams WARNING #1: renamed `testReanchorRoundTripSurfacesNotSupported` →
    `testReanchorRoundTrip` (body unchanged) per the `testWithdrawRoundTrip`
    precedent. (The GLK `VerbSurfaceTests.swift` reanchor round-trip was
    rewritten from a stub-assertion to a real round-trip in Part 1/2.)

## Test Verification Log

### Baseline (mission start, commit 816dbe2 — Smythe-verified)
- `swift test`: exit 0, **441** passed.
- `cargo test --lib`: exit 0, **390** passed.

### Final (commit f88c527)
- Command: `cd packages/kits/LocusKit && swift test`
  - Exit code: **0**
  - Pass count: **454** (441 baseline + 13 ReanchorTests)
  - Tail (verbatim): `Test run with 454 tests in 41 suites passed after 0.927 seconds.`
  - `swift build` warnings: **0**
- Command: `cd packages/kits/LocusKit/rust && cargo test --lib`
  - Exit code: **0**
  - Pass count: **406** (390 baseline + 16: net of 13 reanchor_tests + 4
    estate_verbs real tests − 1 removed stub test)
  - Tail (verbatim): `test result: ok. 406 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s`
  - `cargo build` warnings: **0 new** (1 pre-existing unrelated `unused_mut`
    in `drawer_store_inmemory.rs`; see Outstanding).

Coverage achieved (both legs, case-for-case): room move (recall reflects new
room); lattice move (anchor updated); empty reanchor → `invalidContent`;
non-existent rowID → `drawerNotFound`; audit/provenance entry written
(`auditEventsForRow`/count increment); reanchored row's three bitmaps
otherwise byte-unchanged. No test asserts struct equality across a timestamp
round-trip (the date-precision pitfall that bit sibling VERB-CAP-01 — avoided).

## Smythe Pre-flight

Verdict: **YELLOW — proceed**, no RESCOPE.
(`docs/blast_radius/VERB_REA_01_PREFLIGHT.md`)
- Confirmed stub anchors exact (EstateVerbs.swift:379, estate_verbs.rs:419)
  and the Rust stub test at :656 for replacement.
- Surfaced the real blast radius = 8 files (mission table listed 6): +
  `drawer_store_inmemory.rs` (Rust store impl), + GLK `VerbSurfaceTests.swift`
  (cross-package stale test). Both MUST_UPDATE, no RESCOPE.
- Three look-before-write items (all honored): (1) no `RowVerb.reanchor` →
  use `verb: .mutate`; (2) empty guard throws `LocusKitError.invalidContent`,
  not `VerbError.emptyReanchor`; (3) mirror `expungeGated`.
- **Correction:** Smythe reported the GLK suite GREEN. It is not — see Adams
  / Discoveries. The GLK *test target* fails to compile at baseline due to a
  pre-existing, unrelated `ProposalKind` ambiguity. This did not affect the
  mission (LocusKit-scoped) but is recorded so the record is accurate.

## Adams Post-flight

Verdict: **PASS — CLEAN-WITH-FOLLOWUPS.**
(`docs/blast_radius/VERB_REA_01_POSTFLIGHT.md`)
- Blast Radius Verification: **PASS** — diff matches the BRR's file set
  exactly (12 files incl. 3 doc files; 1440 insertions, 27 deletions); no
  unaccounted files; no MUST_UPDATE missing; no prohibited patterns; all
  MUST-NOT-MODIFY files untouched (`docs/validation`, `LatticeAnchor`,
  `SubstrateLib`, GLK production `VerbSurface.swift`/`VerbError.swift`).
- Test Execution Verification: **PASS** — independently re-ran both legs
  (Method B): swift exit 0 / 454, cargo exit 0 / 406, both **MATCH** Newton's
  claim. 1 pre-existing rust warning confirmed unrelated; zero new warnings.
- Implementation correctness: all 10 checks clean (empty guard error type;
  not-found; `verb: .mutate`; prior/after anchor; bitmaps unchanged; stub
  test removed; I-19 13×13 mirror; date-pitfall avoided; GLK errors isolated
  to `StandingSignalSchedulerTests.swift`; `testReanchorEmptyRaisesGuard`
  preserved).

### Adams findings resolution

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | WARNING | `testReanchorRoundTripSurfacesNotSupported` name contradicted its (now real round-trip) body | **FIXED** — renamed to `testReanchorRoundTrip` in commit `f88c527` |
| 2 | INFO | Three not-found assertions use `throws: LocusKitError.self` (type-only) vs naming `.drawerNotFound` — pre-existing convention from `ExpungeTests.swift`, not introduced here | No action (pre-existing convention; future suite-hardening task) |

No CRITICAL findings. Hard gate (Adams PASS) satisfied before signal.

## Self-review

- Diff (12 files, 1440 insertions, 27 deletions) matches the BRR MUST_UPDATE
  list exactly. The 27 deletions are the replaced stub bodies (Swift + Rust),
  the removed Rust stub test, and the rewritten GLK test — all expected.
- No bridges, shims, TODOs, deprecations, secrets, or silenced warnings in
  the diff. No system colors / unlocalized strings (no view code).
- Blast Radius Report: `docs/blast_radius/VERB_REA_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents (steps 14–17) — evaluated

- **Simms (step 14) — NOT spawned.** Criterion = "modifies user-facing views
  or behavior." This mission ships no app/view code; the `moot_reanchor_drawer`
  MCP surface (ARIA_MCP `ToolDispatch`) was already advertised and wired —
  unchanged by this mission — and merely becomes functional. The mission
  declares "Docs: none in this mission (Nagatha syncs after)." A user-guide
  note that `moot_reanchor_drawer` is now live is a reasonable Nagatha
  post-merge follow-up; flagged here, not silently skipped.
- **Friedlander (15) / Nert (16) — N/A.** Not a UI mission (no views, no
  visual or accessibility surface).
- **Perkins (17) — N/A.** No security surface touched: no schema change
  (existing `udcCode`/`room` columns updated in place), no CloudKit sync, no
  privacy/FNode fields, no API-key/Keychain/URL-scheme/NL-prompt handling.
  The audit/provenance write uses the existing `AuditGate` machinery.
- **Nagatha docs-repo sync (18) — deferred to post-merge** per the mission's
  own statement ("Nagatha syncs after"). Per the operative goal directive,
  this completion report is written directly to `docs/status/` and the signal
  file follows; the docs-repo sync runs after merge.

## Discoveries

- **GLK test target is pre-existing-broken (not caused by this mission).**
  `GeniusLocusKit/Tests/GeniusLocusKitTests/StandingSignalSchedulerTests.swift`
  fails to compile — `ProposalKind` is ambiguous (LocusKit.ProposalKind vs
  GeniusLocusKit.ProposalKind) at ~21 sites. Verified isolated: `swift build
  --build-tests` shows errors ONLY in that file, **zero** in
  `VerbSurfaceTests.swift`. Corroborated by a 2026-05-30 MemPalace note
  (CognitionKit session) recording the same ambiguity. Consequence: the
  rewritten `testReanchorRoundTrip` could not be run to green here; it was
  verified by inspection against the compiling `testWithdrawRoundTrip` /
  `testExpungeWithConfirmationTombstonesRow` patterns (identical APIs:
  `openOneEstate`, `capture`, `recall`/`recallAllActive`, `ReanchorFrame`,
  `.udc`, `udcCode`). GLK production build (`swift build`) is clean.
  **Surfaced to Bob** — owner of the ProposalKind disambiguation, out of this
  mission's scope.
- **Sibling pattern reused.** VERB-CAP-01's R1 failure (date-precision
  struct-equality in roundtrip tests; BRR-must-be-first-commit) informed this
  stream: BRR committed first (`1f5bdc2`); no timestamp struct-equality
  assertions in the suite.

## Outstanding (out of scope — not addressed)

- **Pre-existing rust warning.** `drawer_store_inmemory.rs` `unused_mut` in
  the `diary_round_trip_and_lastn_ordering` test (documented in NOUN-PRO-01
  and NOUN-ASC-01 BRRs). Line shifted by this mission's additions; unrelated
  to reanchor. Left as-is per blast-radius discipline; zero new warnings.
- **GLK `ProposalKind` ambiguity** (see Discoveries) — blocks the GLK test
  target from compiling. A one-shot disambiguation mission (module-qualify
  `ProposalKind` in `StandingSignalSchedulerTests.swift`) would restore it.
