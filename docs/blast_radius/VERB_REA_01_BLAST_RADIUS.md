# Blast Radius Report — VERB-REA-01 (`reanchor` verb, drawer)

Mission: `docs/missions/inflight/MISSION_VERB_REA_01.md`
Stream: rea · Branch: `stream/rea-reanchor-drawer`
Baseline commit: `816dbe2` (NOUN-ASC-01 merge) · Head: (this report = first commit)
Tier: **cap (existing-symbol semantics change)** — three stubs become real
(`Estate.reanchor` Swift + Rust, plus a placement-update store path that is
additive). One cross-package test changes meaning.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **YELLOW** (`docs/blast_radius/VERB_REA_01_PREFLIGHT.md`).
Three look-before-write items, zero CRITICAL blockers, no RESCOPE.

Baseline test counts (Smythe-verified, this branch @ `816dbe2`):
- Swift `swift test`: **441 passed, 0 failed**.
- Rust `cargo test --lib`: **390 passed, 0 failed**.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table listed 6 files. The real, in-scope blast radius is **8**.
The two extra files are forced, additive corrections (not scope creep) with
direct sibling precedent (the `withdraw` verb implementation, WEX). Both are
classified MUST_UPDATE; documented here so the diff is fully accounted for.

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Sources/LocusKit/EstateVerbs.swift` | yes | implement `reanchor` stub @379 | MUST_UPDATE |
| `rust/src/estate_verbs.rs` | yes | Rust mirror @419; replace stub test `reanchor_stub_returns_invalid_content` @656 | MUST_UPDATE |
| `Sources/LocusKit/DrawerStore.swift` | yes (conditional) | add `reanchorGated` placement-update + audit path | MUST_UPDATE |
| `rust/src/drawer_store.rs` | yes (conditional) | add `reanchor_gated` trait default | MUST_UPDATE |
| `rust/src/drawer_store_inmemory.rs` | **no** | implement `reanchor_gated` on the in-memory store | MUST_UPDATE — Rust impl of the store method; the trait default is non-functional without it (same pattern as `expunge_gated`) |
| `Tests/LocusKitTests/ReanchorTests.swift` | yes (CREATE) | Swift conformance suite | MUST_UPDATE (new) |
| `rust/src/reanchor_tests.rs` | yes (CREATE) | Rust conformance suite (+ `lib.rs` module registration if required to compile) | MUST_UPDATE (new) |
| `GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift` | **no** | rewrite `testReanchorRoundTripSurfacesNotSupported` → real round-trip | MUST_UPDATE — cross-package; see below |

If `rust/src/lib.rs` needs a `mod reanchor_tests;` registration for the new
Rust test file to compile, that one-line module declaration is in scope
(required for the new file to build, same as NOUN-ASC-01 precedent).

## Symbols changed (semantics)

- **`Estate.reanchor(rowID:toRoom:toLattice:)`** (Swift `EstateVerbs.swift:379`,
  Rust `estate_verbs.rs:419`): stub throwing `invalidContent("reanchor not yet
  implemented")` → real implementation. Contract: empty input (neither toRoom
  nor toLattice) → `LocusKitError.invalidContent`; absent row → `drawerNotFound`;
  otherwise apply the placement change via the store and record an audit event.
- **`DrawerStore.reanchorGated` / `reanchor_gated`**: net-new store method
  (additive). No existing store method changes semantics.
- **`testReanchorRoundTripSurfacesNotSupported`** (GLK VerbSurfaceTests.swift:169):
  meaning changes — the stub it asserted against is now implemented.

## Cross-package MUST_UPDATE — GLK VerbSurfaceTests (justified)

`GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift:169`
`testReanchorRoundTripSurfacesNotSupported` asserts that a reanchor with a
target remaps to `VerbError.notSupportedByEstate("reanchor")`. That assertion
is true ONLY while `Estate.reanchor` is a stub. Once implemented, reanchor
succeeds, so the test must become a real round-trip (capture → reanchor →
recall → assert anchor/room moved). The GLK suite is currently GREEN; leaving
this test unmodified would be a regression THIS mission introduces.

**Precedent:** when `withdraw` was implemented, its equivalent GLK stub test
became `testWithdrawRoundTrip` (`VerbSurfaceTests.swift:111`). Identical
surgery here. `testReanchorEmptyRaisesGuard` (line 156) is unaffected —
the GLK boundary still raises `VerbError.emptyReanchor` before dispatch — and
is kept as-is.

This is the honest blast radius of correctly implementing the verb, per Bob's
2026-04-23 "right the first time" mandate — not optional scope creep.

## Look-before-write constraints (from Smythe pre-flight)

1. **No `RowVerb.reanchor` case.** `RowVerb` (SubstrateTypes/RowState.swift) is
   a closed enum with no `.reanchor`. The audit event uses `verb: .mutate`
   (active→active self-loop), carrying the anchor delta via
   `priorLatticeAnchor` / `afterLatticeAnchor`. Do NOT conflate with
   SubstrateLib's reference `appendAudit(verb: "reanchor", …)`, which writes a
   different (flat) audit log.
2. **Empty-reanchor error type.** `LocusKitError` has no `.emptyReanchor`
   (that case lives on GLK's `VerbError`). The LocusKit inner guard throws
   `LocusKitError.invalidContent("reanchor requires toRoom or toLattice")`;
   GLK's `remap` converts a thrown LocusKitError. The primary empty guard is
   GLK's boundary check; LocusKit's is belt-and-suspenders (mirrors `expunge`).
3. **Store pattern.** Mirror `expungeGated` (`DrawerStore.swift:587`): read row
   in a transaction, gate via `AuditGate.admit`, update the placement columns
   (`udcCode` and friends for lattice; `room` for room) in the same
   transaction, append the audit event atomically.

## Files NOT modified (per mission's MUST NOT list)

- `docs/validation/**` — substrate atomics; untouched.
- `LatticeAnchor` (a primitive) — used, not changed. The reanchor swaps a
  drawer's anchor *value*; it does not alter the `LatticeAnchor` type. (If it
  had required touching the type, the mission says STOP and flag — it does not.)
- `SubstrateLib` bitmap layout primitives — used (BitField / bit_field), not
  changed. `SubstrateLib/Verbs.swift:170` reanchor read as the reference
  before/after audit pattern only; not edited.
- GLK production code (`VerbSurface.swift`, `VerbError.swift`) — already wired
  to call `estate.reanchor` and to raise `emptyReanchor`; verified, not edited.

## Pre-existing issue surfaced (out of scope)

`rust/src/drawer_store_inmemory.rs` carries a pre-existing `unused_mut`
warning in the `diary_round_trip_and_lastn_ordering` test (documented in the
NOUN-ASC-01 BRR). Unrelated to reanchor; left as-is. This stream must add
**zero** new warnings.

## Test verification (filled at completion)

- `swift test`: exit 0, NNN passed (441 baseline + new). To be recorded.
- `cargo test --lib`: exit 0, NNN passed (390 baseline + new). To be recorded.
