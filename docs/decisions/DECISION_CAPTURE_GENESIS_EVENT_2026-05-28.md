---
status: decided
question: Should capturing a row emit a gated genesis event into the audit log, or should projection seed from the live drawers row?
authors: MOOTx01 maintainers
date: 2026-05-28
relates_to:
  - docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md (custody mode and lazy seal computation are what make this affordable on the hot path)
  - docs/decisions/DECISION_ROW_IDENTITY_UUID_2026-05-28.md (the gate that the genesis event passes through requires UUID identity)
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md (Appendix B, verbatim origin event for nested-triangle federation)
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md (§5.1 I-20 audit log as G-Set CRDT, §5.3 projection rules + I-26, §10.1 capture verb audit emission, §9.9 DrawerStateValidator conformance)
supersedes: none
context:
  - The audit log is the source of truth, but capture was an INSERT that wrote nothing to it, leaving a freshly-captured row with no log presence.
  - SubstrateLib AuditGate (the prior == nil branch is the capture path) and LocusKit DrawerStore.addDrawer / drawer_store_inmemory.rs add_drawer (the fifth gated write path) are the affected surfaces.
---

# Decision: Capture Emits a Gated Genesis Event

## 1. Summary

The act of capturing a row writes one sealed event into the audit log, through the same write gate every mutator passes through, with `prior = none` and `after = the captured state`. This event is the row's genesis. From it forward, every other event in the row's history folds on top, and the row's state at any HLC is recoverable from the log alone with no live-row seed.

This decision closes a semantic gap that surfaced during the read-side migration: the audit log was meant to be the source of truth, but capture was an INSERT that wrote nothing to it, so a freshly-captured row had no log presence and the projection-from-events model was incomplete from the first event onward. The fix is small in shape and large in meaning. `addDrawer` and its Rust mirror now route through `AuditGate.admit` with `prior = none`, the gate's `prior == nil` branch runs `ForbiddenCombinations.check` (which includes I-22) over the captured basis, and one sealed `AuditEvent` lands in the log carrying the genesis snapshot.

The cookbook already specified this. §5.3 names `capture_initial_state(e_1)` as the first step of `project_current_state`, meaning the first event in a row's history *is* the capture event. §10.1 names the audit emission explicitly: `before_bitmap = ∅, after_bitmap = new state, actor = caller, hlc = current HLC`. The implementation had drifted; this decision brings it back to spec.

## 2. The two options that were on the table

**(a) Capture emits a genesis event.** Capture becomes a gated write. The log is self-sufficient — every row's state at every HLC is the fold of its events, starting from the genesis event. `project_state_at(row, T)` returns `none` for `T` strictly before the genesis HLC (the row did not exist then), and the captured state for any `T` at or after the genesis HLC with no later mutations. The materialized projection (the live `drawers` row) is a cache of the fold, not the seed.

**(b) Projection seeds from the live `drawers` row.** Capture stays an INSERT. `project_state_at(row, T)` reads the live row as the base snapshot and folds only the mutation events on top of it. A captured-never-mutated row returns its current state at any `T >= filed_at` because the live row supplies it. Smaller code change. No new event type. No new write through the gate.

(a) is decided.

## 3. Why (a)

**The log is the source of truth.** The cookbook's I-20 declares the audit log a G-Set CRDT and §5.4 declares sync convergence on the projection of that G-Set. Both statements presuppose that the log carries enough information to project the current state. Under (b) the log does not carry that information for the period between capture and first mutation — the projection in that interval is recoverable only because the live row is locally readable. The first time the receiver needs to reconstruct a row it has not yet seen, the assumption breaks. Cold rebuild from log alone (§5.5 of the cookbook, the disaster-recovery path) does not work under (b); the rebuilder finds mutations on top of a row whose initial state it has no record of.

**Federation needs an origin event.** The federation decision's nested-triangle model (Appendix B) carries an incoming row's origin event verbatim into the receiver's log so the receiver can verify "the originating estate knew this thing first, at this stamped HLC, with this sealed content." Under (b) the originating estate's row is born without an event; there is nothing for the receiver to wrap and nest. Federation would have to synthesize an origin event at export time, which is exactly the case the verbatim-carry rule was designed to prevent — a synthesized event is not the origin's evidence, it is the exporter's claim about the origin.

**Owned memory deserves a logged moment of remembering.** This is the project's stance, not a technical argument. mootx01 is owned memory. The genesis of a memory — the act of capturing a thought, a fact, a conversation — is at least as load-bearing as any later mutation of it. If we log every adjective edit but not the moment the row entered existence, we are saying the edits matter to the record but the origin does not. We do not believe that.

**One audit pattern, not two.** Under (a) every write path is structurally identical: read the gate, decompose to declared `FieldWrite`s, validate the basis, append one sealed event, update the projection. Under (b) capture is the exception — the only write that touches `drawers` without touching the log. Exceptions in audit code are a class of bug we have already paid for once with the earlier mutator divergences. Closing the exception removes a future maintenance hazard.

## 4. Why not (b)

**(b) is not "smaller (a)."** (b) is a different model: live-row-seeded projection instead of log-seeded projection. The cookbook's §5.3 algorithm does not admit (b) — it starts from `capture_initial_state(e_1)`, which only exists if there is an `e_1`. Adopting (b) would require an amendment to §5.3 and a parallel amendment to §5.5 (the rebuild path) and §5.4 (sync convergence), because the live-row seed is a per-replica state that does not converge under set union.

**The compute objection that almost stopped (a) is dissolvable.** The reason (b) was tempting is that capture is the highest-volume write and adding a sealed event to every capture sounded like a hot-path tax — the seal is a SHA-256 over wire fields, and capture happens once per row but mutations happen rarely or not at all. The Clock Triangle decision (§7, custody mode) resolves this. The seal is deferrable to Dream under lazy custody: the write appends an unsealed event cheaply, sets the `dreaming_recalc_required` flag, and the dreaming pass computes the seal off the hot path. Strict custody mints the seal contemporaneously because the contemporaneity *is* the evidence; lazy custody does not need that and pays only the unsealed-event append. The hot-path cost of (a) under lazy custody is one event append (no hash), comparable to the existing `bitmap_audit` row insert it replaces.

## 5. What this changes in code, both legs

The capture path becomes the fifth gated write path, joining the four mutators (`mutateState`, `mutateAdjective`, `mutateOperational`, `mutateProvenance`).

In Swift, `DrawerStore.addDrawer` no longer issues a raw `INSERT` into `drawers`. It calls `gatedCapture(drawer)`, which decomposes the captured row's adjective, operational, and provenance basis slots into per-slot `FieldWrite`s, calls `AuditGate.admit(verb: .capture, prior: nil, writes:)`, and on admission appends one `AuditEvent` (verb = capture, before bitmaps zero, after bitmaps the captured state) and updates the projection in the same transaction. The supersession cascade follows the same path for the successor row.

In Rust, `InMemoryDrawerStore::add_drawer` calls `gated_capture(drawer)`, which mirrors the Swift decomposition exactly: same declared slots, same `RowVerb::Capture`, same `prior = None` branch, same one event. The Swift-and-Rust legs route through the same `AuditGate` shape, with the same I-22 enforcement at capture as at mutation. The cascade successor is captured by the same path.

The genesis event carries the state slot. Capture is the only gated write that legitimately writes the state field through the gate, because the gate's `prior == nil` branch is the only place where state can move from "no state" to an initial state. The state must be `active` or `pending` (state cluster A — accepting); a capture that tries to start at `contested`, `withdrawn`, or any later-cluster value is rejected by the basis automaton. Tests that previously seeded rows in those states had to be restructured to capture-then-mutate, which is how those states actually arrive in production.

`ForbiddenCombinationValidator` as a standalone pre-insert check is retired. The gate's `prior == nil` branch already runs `ForbiddenCombinations.check` over the merged basis, which catches I-22 (sensitivity=secret AND exportability=public) and any future forbidden combinations. One enforcement point, not two.

`auditTrail(rowID:)` now returns `[AuditEvent]` snapshots in HLC order, starting with the genesis event. The earlier `[AuditRow]` delta shape (prior/new pairs over `bitmap_audit`) is retired with the table. `bitmapState(rowID:asOf: HLC)` folds the row's events via `AuditLogFold.projectStateAt`; it returns `none` for an HLC strictly before the genesis event and the projected state for any later HLC. The wall-clock `auditTrail(since:until:)` form is dropped per the Clock Triangle decision (§11) — wall-clock is not a fold axis.

## 6. Tests, fixtures, and what the new model surfaces

The migration to (a) was structurally easy and semantically revealing. Two real classes of bug came out of the test suite that the old model had been hiding.

Tests that captured rows in non-genesis states stopped working. `DrawerStoreTests` had a fixture that called `addDrawer` with `adjectiveBitmap` set to a contested-state pattern; the gate correctly refused it. The fix was not to weaken the gate but to restructure the test to capture-active then `mutateState(.contested, via: .contest)`. Similar restructuring landed in `LineageTests`.

Tests that carried stale illegal bitmap fixtures from a previous vocabulary stopped working. `0x1042` packed `sensitivity = 1` and `exportability = 1` (both illegal under the current enumerations); `0x1412` packed `capture_channel = 18` (also illegal). These had been silently accepted by the old whole-column `INSERT` path. The gate's field-level enumeration check rejected them at capture, with a clear error message naming the violating field. The fixtures were updated to legal values; no semantic change was needed.

Tests that used adjective or operational bitmaps as opaque bit-pattern discriminators (`BundleMaterializer`, `ContainerFingerprintStore`) had their fixtures shifted to position 24+, above the declared basis slots, where the gate does not validate enum membership. The fingerprint math is identical under the shift; the gate is satisfied because the patterns no longer land in slots with declared legal values.

Test event-count assertions shifted by one. `events.count == N` became `N + 1` because the genesis event is now `events[0]`. `events.first` referring to the mutation became `events.last`. Indexed assertions on `events[0]` and `events[1]` referring to mutations became `events[1]` and `events[2]`. The "rejected mutation appended no event" assertion changed from `count == 0` to `count == 1` because the genesis capture remains in the log even when a follow-on mutation is rejected.

These are migration artifacts, not design surprises. They are recorded here so a future engineer reading the test history understands what changed and why.

## 7. Status

Decided 2026-05-28, implemented same session.

Built and verified, both legs:

- Swift `DrawerStore.addDrawer` routes through `AuditGate.admit` with `prior = nil`. `gatedCapture` helper decomposes all declared slots of all three basis columns into `FieldWrite`s. Cascade successor uses the same path. Build clean, full kit test suite green except for known pre-existing environment failures (the vectors-directory environment case).
- Rust `InMemoryDrawerStore::add_drawer` routes through the gate equivalently. `gated_capture` mirrors the Swift decomposition. `cargo test --lib` 341 passing, zero failing.
- `auditTrail` returns `[AuditEvent]` snapshots in HLC order, starting with the genesis event.
- `bitmapState.asOf: HLC` folds via `AuditLogFold.projectStateAt`; returns `none` before the genesis HLC.
- `auditTrail(since:until:)` wall-clock window form retired.
- `bitmap_audit` and `provenance_audit` tables, triggers, `AuditRow` / `BitmapColumn` / `AuditActor` types, and `BitmapAuditPair` retired. The audit log is the sole source of truth, foldable from genesis.
- `ForbiddenCombinationValidator` standalone retired. I-22 enforced in the gate at every entry, capture included.

What this decision does *not* specify and is not yet built: the seal-bit lifecycle on the genesis event (adjective bit 27) under lazy custody, and the dreaming pass that flips it from 0 to 1 after computing the seal off the hot path. That work belongs to the Clock Triangle decision and lands when the dreaming pass is wired.
