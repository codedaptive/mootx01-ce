# Mission VERB-REA-01 — Implement `reanchor` (drawer) (both legs)

## Priority: P2
## Stream: rea
## Branch from: main
## Depends on: None
## Parallel safe with: VERB-REC-01, VERB-MUT-01, VERB-WEX-01, VERB-CAP-01, VERB-LRN-01 — work parallel; merges into EstateVerbs.swift / estate_verbs.rs serialize (fan-in rec -> mut -> wex -> cap -> rea -> lrn)

---

## Context

`reanchor` is legal on exactly one noun: drawer (verify in `Acceptance.swift`).
It is a stub throwing `reanchor not yet implemented` in both legs (Swift
`EstateVerbs.swift:379`, Rust `estate_verbs.rs:419`). The GLK surface has a
`VerbError.emptyReanchor` case and `VerbSurface.swift` calls `estate.reanchor` —
verify. This mission implements the verb.

Reanchor moves a drawer to a different room and/or lattice position
(`reanchor(rowID:toRoom:toLattice:)` — verify the signature at line 379).
Semantics: at least one of toRoom/toLattice must be provided (empty reanchor ->
emptyReanchor error — verify this is the contract). The lattice anchor is required
on all noun types (cookbook section 2.7) and the move must preserve
audit/provenance. Verify how a placement change is recorded — whether it routes
through the automaton/mutateState or is a direct row update with an audit entry —
by reading the drawer store's update path and cookbook section 2.5 before
implementing.

<!-- EMBED _SHARED_PREAMBLE.md HERE AT SUBMIT (doctrine + Read First map + done-definition) -->

## Read First

Navigation map: verify each against the source file beside it before
implementing. The documentation is under active debugging: source is ground
truth; when a doc and the code disagree, follow the code and note the drift in
the completion report. Skip `docs/validation/` (substrate atomics, wrong altitude).

- Stub site: `packages/kits/LocusKit/Sources/LocusKit/EstateVerbs.swift:379` (Swift), `packages/kits/LocusKit/rust/src/estate_verbs.rs:419` (Rust).
- GLK surface: `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift` (reanchor -> estate.reanchor), `VerbError.swift` (emptyReanchor).
- Store update path: `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift` (placement update + audit) + Rust mirror.
- Lattice + provenance contract (verify in source): cookbook `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md` section 2.5 provenance, 2.7 lattice anchor required.

## Known Ambiguities

1. Placement-change recording. Whether reanchor routes through the
   automaton/mutateState or is a direct row update with an audit entry is
   unverified. Confirm in Part 1 by reading the drawer store update path; follow
   the existing pattern, do not invent the audit treatment.

## Blast Radius Scope

Symbols being changed:
- `Estate.reanchor` (`EstateVerbs.swift:379`) — semantic: stub -> real.
- Drawer store placement-update path — additive if not already present.

Expected blast radius (Skippy's estimate):
- Production code: `EstateVerbs.swift` + `estate_verbs.rs` (core); `DrawerStore.swift` + Rust (conditional, placement update).
- Tests: LocusKit Swift + Rust reanchor suite.
- Docs: none in this mission (Nagatha syncs after).

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/EstateVerbs.swift` | implement reanchor |
| `packages/kits/LocusKit/rust/src/estate_verbs.rs` | Rust mirror |
| `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift` | conditional: placement update + audit if absent |
| `packages/kits/LocusKit/rust/src/drawer_store.rs` | conditional: Rust mirror |
| `packages/kits/LocusKit/Tests/LocusKitTests/ReanchorTests.swift` | CREATE Swift conformance |
| `packages/kits/LocusKit/rust/src/reanchor_tests.rs` | CREATE Rust conformance |

## Files You MUST NOT Modify

- `docs/validation/**` — substrate atomics; out of scope.
- `LatticeAnchor` (a primitive) — if the lattice change seems to require touching it, STOP and flag.
- Bitmap layout primitives in `SubstrateLib` — use them, do not change them.

## Implementation Parts

### Part 1 — reanchor implementation, both legs
Implement the stub: validate at least one of toRoom/toLattice (empty ->
emptyReanchor); look up the row (absent -> not-found); apply the placement change
via the drawer store's update path, recording audit/provenance exactly as the
existing update pattern does (Known Ambiguity 1; verify, do not invent). Write
Swift and Rust in the same unit.

**Commit:** `feat(locuskit): implement reanchor verb (drawer) — Swift+Rust`
→ verify: `cd packages/kits/LocusKit && swift build` clean; `cargo build` clean; reanchor moves a drawer's room/lattice in test, audit recorded.

### Part 2 — Conformance suite, both legs
Tests prove, both legs: reanchor to a new room moves the drawer (recall reflects
it); reanchor to a new lattice updates the anchor; empty reanchor ->
emptyReanchor; non-existent rowID -> not-found; audit/provenance entry written;
reanchored row's bitmaps otherwise unchanged. Rust mirrors Swift case-for-case
(I-19).

**Commit:** `test(locuskit): reanchor conformance — Swift+Rust`
→ verify: `cd packages/kits/LocusKit && swift test` green; `cargo test --lib` green; zero warnings.

## Test Requirements

- Both legs build clean, zero warnings.
- Swift `swift test` green; Rust `cargo test --lib` green.
- Coverage: room move; lattice move; empty-reanchor error; not-found; audit entry; bitmap-otherwise-unchanged.
- Rust suite is a case-for-case mirror of the Swift suite.

## Test Verification Log

### Baseline (mission start)
- Pass count at mission start: NNN (record before Part 1).

### Final
- Command: `cd packages/kits/LocusKit && swift test 2>&1 | tail -20`
- Exit code: 0
- Pass count: NNN (record exact)
- Tail output (verbatim): record on completion.
- Rust: `cargo test --lib 2>&1 | tail -20`, exit 0, counts recorded.

## Verification

`reanchor` moves a drawer's room/lattice with correct audit/provenance, both legs,
honoring the empty-reanchor and not-found contracts. Both legs green; Rust mirrors
Swift.

## Success Criteria

`reanchor` is implemented for drawer in both legs, audit/provenance correct,
empty-reanchor and not-found contracts honored, conformance suite mirrored and
green. `moot_reanchor_drawer` works.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-rea
