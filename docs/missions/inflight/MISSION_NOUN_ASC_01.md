# Mission NOUN-ASC-01 — Association noun substrate (type + table + store, both legs)

## Priority: P1
## Stream: nas
## Branch from: main
## Depends on: None
## Parallel safe with: NOUN-PRO-01, NOUN-LRF-01 — distinct net-new files; only shared edit is LocusKitSchema.swift (serialize schema edits npr -> nas -> nlr)

---

## Context

The `association` noun is in the Acceptance matrix (`AriaLexiconLib/Acceptance.swift`
— association accepts mutate, expunge, recall; note it accepts no capture and no
withdraw) but has no substrate: no type, no table, no store. Verify:
`find packages/kits/LocusKit/Sources/LocusKit -iname '*Association*'` returns
nothing. This mission builds the Association noun substrate so the verb missions
can later operate on it. No verb behavior here.

An association is a graph-edge-shaped noun that links rows, closer in shape to
Tunnel than to a content row. Read `Tunnel.swift`, `TunnelOperational.swift`, and
the `tunnels` table (`LocusKitSchema.swift` around line 203) as the structural
template: source/target references, operational bitmap, lattice anchor. Verify
the association's exact fields and operational bitmap layout against cookbook
section 2.4 and the LocusKit spec, and confirm the Tunnel pattern in source
before mirroring. Associations are on the graph side of the content-vs-graph
distinction (cookbook section 9.5.1); confirm in source what that implies for
the adjective bitmap.

<!-- EMBED _SHARED_PREAMBLE.md HERE AT SUBMIT (doctrine + Read First map + done-definition) -->

## Read First

Navigation map: verify each against the source file beside it before
implementing. The documentation is under active debugging: source is ground
truth; when a doc and the code disagree, follow the code and note the drift in
the completion report. Skip `docs/validation/` (substrate atomics, wrong altitude).

- Type template: `packages/kits/LocusKit/Sources/LocusKit/Tunnel.swift`, `TunnelOperational.swift`. Rust template `packages/kits/LocusKit/rust/src/` (tunnel equivalent).
- Schema template: `packages/kits/LocusKit/Sources/LocusKit/LocusKitSchema.swift` (tunnels table, around line 203) + Rust schema mirror.
- Store template: the tunnel persist/fetch methods in the store files.
- Bitmap/layout contract (verify in source): cookbook `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md` section 2.1 row layout, 2.4 operational bitmap, 2.7 lattice anchor required, 9.5.1 content-vs-graph distinction.
- Acceptance matrix: `packages/libs/AriaLexiconLib/Sources/AriaLexiconLib/{Acceptance.swift, Noun.swift}`.

## Blast Radius Scope

All-new files except one. The Association type, operational accessor, store
methods, and tests are net-new. The single edit to existing code is the schema
registration.

Symbols being changed:
- `LocusKitSchema` (`LocusKitSchema.swift`) — additive: register the `associations` table alongside `tunnels`. No change to existing table declarations.

Expected blast radius (Skippy's estimate):
- Production code: new `Association.swift`, `AssociationOperational.swift`, `association.rs`; one additive edit to `LocusKitSchema.swift` + Rust schema mirror.
- Tests: new Association Swift + Rust suites.
- Docs: none in this mission (Nagatha syncs after).

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/Association.swift` | CREATE type model (mirror Tunnel.swift) |
| `packages/kits/LocusKit/Sources/LocusKit/AssociationOperational.swift` | CREATE operational-bitmap accessor (mirror TunnelOperational.swift) |
| `packages/kits/LocusKit/Sources/LocusKit/LocusKitSchema.swift` | register the associations table (additive; mirror tunnels) |
| `packages/kits/LocusKit/rust/src/association.rs` | CREATE Rust type model |
| `packages/kits/LocusKit/Tests/LocusKitTests/AssociationTests.swift` | CREATE Swift conformance |
| `packages/kits/LocusKit/rust/src/association_tests.rs` | CREATE Rust conformance |

## Files You MUST NOT Modify

- `docs/validation/**` — substrate atomics; out of scope.
- Existing noun types (`Tunnel.swift`, `KGFact.swift`, etc.) — templates to read, not edit.
- Bitmap layout primitives in `SubstrateLib` — use them, do not change them.
- The `tunnels` table declaration — read as template; do not alter.

## Implementation Parts

### Part 1 — Association type model, both legs
Define `Association` mirroring the Tunnel edge pattern: identity, source/target
references, lattice anchor (verify required per cookbook 2.7), three bitmaps
(adjective/operational/provenance, Int64). Operational bitmap layout from cookbook
2.4 — verify in source/spec; do not invent. Write Swift `Association.swift` and
Rust `association.rs` in the same unit.

**Commit:** `feat(locuskit): Association noun type model — Swift+Rust`
→ verify: `cd packages/kits/LocusKit && swift build` clean; `cargo build` clean.

### Part 2 — associations schema table, both legs
Register the table mirroring `tunnels`: bitmap columns, source/target, lattice
anchor, indices for edge lookup. Mirror in the Rust schema. Verify column types
against the tunnels declaration before writing.

**Commit:** `feat(locuskit): associations table schema — Swift+Rust`
→ verify: both build clean; schema creation succeeds in an in-memory store test.

### Part 3 — Store surface + conformance tests, both legs
Add store read/write for associations mirroring how tunnel rows persist. Tests
prove, both legs: round-trip persist/fetch; bitmaps byte-identical; source/target
resolve; edge indices work. Rust suite mirrors Swift case-for-case (gate I-19).

**Commit:** `feat(locuskit): association store + conformance — Swift+Rust`
→ verify: `cd packages/kits/LocusKit && swift test` green; `cargo test --lib` green; zero warnings.

## Test Requirements

- Both legs build clean, zero warnings.
- Swift `swift test` green; Rust `cargo test --lib` green.
- Coverage: round-trip persist/fetch; bitmap byte-identity; source/target resolution; edge index lookup.
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

The Association noun has type, associations table, store persistence in both legs,
mirroring the Tunnel edge pattern. Round-trips byte-identically. No verb behavior.
No shared store-interface change. Both legs green; Rust mirrors Swift.

## Success Criteria

Association noun substrate exists in both legs (type + table + store), mirroring
Tunnel. An Association row round-trips byte-identically. The verb missions
(recall/mutate/expunge) can now target association. No verb behavior here.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-nas
