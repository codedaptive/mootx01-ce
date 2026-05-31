# COMPLETION: VERB-CAP-01 — standalone `capture` for tunnel (both legs)

**Status: COMPLETE — both legs green, Adams PASS.**
Stream: cap · Branch: `stream/cap-capture-tunnel`
Baseline: `816dbe2` · Head: `5ef0042` (+ docs commit)
Mission: `docs/missions/inflight/MISSION_VERB_CAP_01.md`
Date: 2026-05-30

---

## Summary

`capture` now supports the `tunnel` noun via a standalone path, in both legs.
`capture` is legal on exactly two nouns — drawer and tunnel
(`AriaLexiconLib/Acceptance.swift`: `case .tunnel: return [.capture, .mutate,
.withdraw, .expunge, .recall]`). Drawer capture already worked; until this
mission a tunnel was only ever born as a side effect of the drawer supersession
cascade. This mission adds the standalone tunnel-capture path.

The standalone path is **byte-identical** to the tunnel the cascade writes
(`DrawerStore.addDrawerWithCascade` / Rust `add_drawer_with_cascade`): it builds
a `Tunnel` with the same all-zero bitmap defaults and files it through the
bare-insert `addTunnel` / `add_tunnel`. One tunnel shape, two entry points.

`moot_capture_tunnel` (the ARIA/MCP verb) is now backed by real substrate.

## Key design decision — genesis event (resolved by source-is-ground-truth)

The mission text says tunnel capture should "mirror drawer capture's gated
genesis event." **Source contradicts that premise:** the supersession cascade
emits **no** genesis `AuditEvent` for the tunnel it files — it does a bare
`rowStore.insert` (`DrawerStore.swift:264–268`; `drawer_store_inmemory.rs:374–390`),
and `addTunnel` does the same. The mission's overriding, repeated requirement is
**byte-identity with what the cascade produces** ("one tunnel shape, two entry
points; do not create a second divergent tunnel-creation path"). Emitting a
tunnel genesis event would make standalone capture DIVERGE from the cascade in
the audit log — exactly the divergence the mission forbids. So standalone
capture matches the cascade: bare insert, no tunnel genesis event. Per the
mission's "Read First" rule (source is ground truth; note the drift), this is
the noted drift. Smythe and Adams both concurred (Smythe "option b"; Adams
verified the byte-identity claim holds).

## Lattice anchoring

"Same lattice anchoring" is satisfied trivially: the `tunnels` table has NO
lattice-anchor columns (`LocusKitSchema.swift:205–228`); the endpoint drawers
carry the anchors, not the tunnel row. `TunnelCaptureFrame` therefore has no
anchor slot.

## What Was Done

- **BRR** — `cd8bf31` — `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` (first
  commit of the stream, per execution order step 6.5).
- **Part 1 — frame + estate dispatch, both legs** — `0229777`
  - `Frames.swift` / `frames.rs`: new `TunnelCaptureFrame` (source/target
    wing+room + optional drawer ids, `label`, `kind: TunnelKind` default
    `.references`, `addedBy`). No content/lattice/embedding/bitmap slots —
    standalone capture zero-inits the bitmaps, matching the cascade.
  - `EstateVerbs.swift`: `func capture(_ frame: TunnelCaptureFrame) async throws
    -> Tunnel` (overload of the drawer `capture`). Validates both endpoints'
    wing/room + label + addedBy non-empty, builds a `Tunnel` (UUID id, `Date()`
    stamped once at the boundary, all-zero bitmaps), files via `store.addTunnel`.
    Added internal test peeks `_peekTunnel` / `_tunnelsFrom` / `_tunnelsTo`
    (mirroring `_peekDrawer`).
  - `estate_verbs.rs`: `pub fn capture_tunnel(&self, frame: TunnelCaptureFrame,
    now: i64) -> Result<Tunnel, LocusKitError>` (Rust can't overload). Mirrors
    Swift case-for-case.
- **Part 2 — conformance suites, both legs** — `5ef0042`
  - `CaptureTunnelTests.swift` (+14) and `capture_tunnel_tests.rs` (+14),
    case-for-case mirror (I-19), registered via `lib.rs`.

## Test Verification Log

### Baseline (mission start, commit 816dbe2)
- `swift test`: exit 0, **441** passed.
- `cargo test --lib`: exit 0, **390** passed.

### Final (head 5ef0042) — independently re-run by Adams (Method B)
- Command: `cd packages/kits/LocusKit && swift test`
  - Exit code: **0**
  - Pass count: **455** (441 + 14)
  - Tail: `Test run with 455 tests in 41 suites passed`
  - `swift build --build-tests` warnings: **0**
- Command: `cd packages/kits/LocusKit/rust && cargo test --lib`
  - Exit code: **0**
  - Pass count: **404** (390 + 14)
  - Tail: `test result: ok. 404 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`
  - Warnings: 0 new.

Coverage (both legs, mirrored): capture round-trip; all-zero bitmaps;
**standalone-vs-cascade byte-identity** (captures two drawers sharing a lineage
to fire the cascade, then compares every tunnel field but `id`/`filedAt`);
source/target endpoint resolution (drawer ids + room-level nil); recallability
via the `tunnelsFrom`/`tunnelsTo` edge indices; kind default + round-trip;
invalid-edge rejection (each empty field).

## Smythe Pre-flight

Verdict: **YELLOW — terrain substantially clear; proceed.**
- All six mission files verified; `capture` was drawer-only with no tunnel
  branch. `Acceptance.swift` lives in **AriaLexiconLib** (not LocusKit — the
  mission's "LocusKit" path is doc drift); `capture` is legal on `tunnel`.
- Known Ambiguity 1 → **GREEN, reuse is clean**: cascade and `addTunnel` both
  bare-insert with all-zero bitmaps → standalone via `addTunnel` is
  byte-identical; no cascade modification needed.
- Genesis → cascade emits no tunnel genesis event → option (b) (adopted).
- Known Ambiguity 2 → new additive `TunnelCaptureFrame` (adopted).
- `NounType.tunnel` exists in SubstrateTypes; the gate treats nounType as
  informational, so tunnel capture through the bare insert is structurally fine.

## Adams Post-flight

- **Round 1: NOT-PASS** — two CRITICAL findings (Adams caught a real bug):
  1. `swift test` actually exited 1: `captureRoundTrips` used `#expect(loaded ==
     captured)`, which failed because `Date()` sub-second precision is truncated
     by the SQLite ISO8601 round-trip (`filedAt` diverged). **FIX:** field-by-field
     assertions + tolerant `filedAt` check (`abs(diff) < 1.0`), matching the
     existing `EstateVerbTests` pattern; production `Date()` semantics unchanged
     (drawer capture has the same property). Rust passed throughout because it
     uses integer epoch-seconds.
  2. Missing BRR. **FIX:** wrote and committed `VERB_CAP_01_BLAST_RADIUS.md`
     (first commit).
  - WARNING (Rust `capture_tunnel` ~55 lines): retained, accepted as non-blocking
    — six 3-line guards mirror the Swift validation style; extracting a
    `validate()` adds surface for no behavioral gain.
  - INFO (mission file absent on disk): see Discoveries (worktree teardown).
- **Round 2: PASS.** Both CRITICAL findings closed and independently verified
  (swift 455/exit 0, cargo 404/exit 0). Scope additive (8 files, zero deletions);
  MUST-NOT-MODIFY files untouched; no prohibited patterns; Swift↔Rust parity
  case-for-case; byte-identity-to-cascade claim verified against the cascade
  construction. Report: `docs/blast_radius/VERB_CAP_01_POSTFLIGHT.md`.

## Self-review

- Diff (8 files, additive, **0 deletions**) matches the BRR exactly. No existing
  symbol semantics changed. `capture(_:TunnelCaptureFrame)` is a new overload and
  `capture_tunnel` a new method — no pre-existing callers to go stale.
- No bridges, shims, TODOs, deprecations, or silenced warnings.
- MUST-NOT-MODIFY honored: `Tunnel.swift` / tunnels table, the cascade path,
  SubstrateLib primitives, `docs/validation/**` — all untouched (the cascade
  symbol appears only in new doc comments and the BRR).

## Discoveries

- **Doc/source drift on tunnel genesis events** — the mission's "mirror drawer
  genesis" premise is false against source; byte-identity with the cascade
  (no tunnel genesis event) is the correct, mission-aligned behavior.
- **`Acceptance.swift` is in AriaLexiconLib, not LocusKit** — mission "Read
  First" path is stale.
- **Process incident (recorded for the fleet):** earlier in this run an errant
  premature `.stuck-cap` signal was written to the dispatch signals dir; the
  wormhole daemon consumed it and tore down the worktree AND deleted the branch
  mid-mission. The work was reconstructed from the session transcript onto a
  rebuilt worktree at `816dbe2`. Lesson: never write a `.stuck` signal until
  genuinely blocked — the daemon acts on it immediately and irreversibly.

## Final State

- Build: clean both legs, zero warnings.
- Tests: swift 455 / cargo 404, both exit 0.
- Adams: PASS. Ready for merge.
