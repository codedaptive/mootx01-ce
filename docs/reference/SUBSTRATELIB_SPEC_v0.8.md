---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateLib
kind: Lib
relates_to:
  - SUBSTRATELIB_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATETYPES_SPEC_v0.8.md     (Layer 1: value types this package orchestrates)
  - SUBSTRATEKERNEL_SPEC_v0.8.md    (Layer 2: hot-path primitives this package composes)
  - SUBSTRATEML_SPEC_v0.8.md        (Layer 3: cold-path algorithms this package composes)
  - DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md (the four-package split + amendment retaining AuditGate; this is Layer 4)
  - GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md  (§5 audit log, §9 row-state automaton, §10 the nine verbs, I-22 / I-25 / I-26 / I-30)
purpose: |
  SubstrateLib is Layer 4 of the four-package substrate: the
  orchestration control surface that composes Layers 1-3 into a
  writable substrate. It owns the nine substrate verbs (`Verbs`),
  the row-state automaton (`RowStateAutomaton`), and the single
  write-gate (`AuditGate`). Every mutation to a substrate row goes
  through this layer. The companion INTERFACE document carries the
  signatures.
---

# SubstrateLib Specification

## § 1 — What this package is

SubstrateLib is the orchestration control surface of the substrate.
It is not data (those are SubstrateTypes), not hot-path bit
operations (those are SubstrateKernel), not cold-path algorithms
(those are SubstrateML). It is the *composition* — the layer that
takes the value types, calls the kernel primitives, runs the
algorithms, and assembles them into the nine substrate verbs and
the AuditGate write path.

This package is a **Lib**: pure functions and value types with no
managed state, no actors, no I/O. It depends on every layer below
it (Types + Kernel + ML) and is depended on by every kit that runs
the substrate verbs — only one kit today, LocusKit, which is the
canonical verb-driver. Other kits read substrate types directly
from SubstrateTypes/Kernel/ML without going through this layer.

The three retained symbols — `Verbs`, `RowStateAutomaton`,
`AuditGate` — share a structural property: they compose lower
layers into a coherent control surface. None of them decomposes
cleanly into Types, Kernel, or ML; pushing them down would either
duplicate logic across kits (violating I-25) or scatter the
single-hard-port control surface (violating I-30).

## § 2 — Scope

This specification defines:

- The nine substrate verbs (`Verbs.Substrate` Swift namespace /
  `verbs` Rust module) per cookbook §10:
  capture, reanchor, mutate, withdraw, expunge, recall, propose,
  associate, learn.
- The row-state automaton (`RowStateAutomaton`) — the transition
  table, the `validate(from:on:targetingFields:)` function, the
  forbidden-combinations check, the `BitmapFields` carrier — per
  cookbook §9.
- The AuditGate write-gate (`AuditGate.admit`) — the single legal
  path to a substrate mutation, which:
  1. Validates the vocabulary (field existence, legal value, width).
  2. Validates the transition (calls `RowStateAutomaton.validate`).
  3. Validates the forbidden combinations (I-22).
  4. Read-modify-writes the FieldWrites into the prior bitmaps.
  5. Computes the content-ID hash.
  6. Emits one canonical `AuditEvent`.

This specification does NOT define:

- API signatures — those live in `SUBSTRATELIB_INTERFACE_v0.8.md`.
- The value types these verbs operate on — those live in
  `SUBSTRATETYPES_SPEC_v0.8.md`.
- The hot-path primitives AuditGate consumes (BitField, SHA256) —
  those live in `SUBSTRATEKERNEL_SPEC_v0.8.md`.
- The cold-path algorithms verbs may call (AuditLogFold, MatrixDecay)
  — those live in `SUBSTRATEML_SPEC_v0.8.md`.
- Per-verb storage I/O — that's PersistenceKit's job; verbs here
  produce audit events and write through a `StorageRow` interface
  that consumers implement.
- The kit-side verb-driver glue — that lives in
  `LOCUSKIT_SPEC_v0.8.md` (and equivalent for any future verb-driver).

## § 3 — Position in the kit family

```
              SubstrateLib              ← THIS PACKAGE (orchestration)
                ↑    ↑    ↑
       SubstrateML  ↑   SubstrateKernel
                ↘  ↑  ↙
              SubstrateTypes
```

**Depends on:** `SubstrateTypes`, `SubstrateKernel`, `SubstrateML`.

**Consumed by:** `LocusKit` (the sole verb-driver consumer; the
other kits read substrate types directly without going through the
orchestration layer). Internal tests + conformance gates also
consume.

## § 4 — Invariants

- **I-22.** `RowVerb` is closed: the nine substrate verbs per
  cookbook §10 are the only legal mutation kinds.
- **I-25.** Each algebra primitive has one canonical implementation.
  AuditGate, RowStateAutomaton, and Verbs are themselves
  one-implementation-per-port; they are the *composition* over the
  lower-layer primitives.
- **I-26.** Every row creation emits a gated genesis event (the
  capture verb produces one through AuditGate per §10.1).
- **I-30.** The substrate ships as four packages. SubstrateLib is
  Layer 4.

Orchestration-specific:

- **O-1.** Every mutation to a substrate row goes through
  `AuditGate.admit`. Direct writes to a row's bitmaps without
  passing through the gate are forbidden.
- **O-2.** `AuditGate.admit` is deterministic: same inputs (prior
  state, verb, writes, HLC, vocabulary) produce the same output
  (audit event, content-ID hash). Determinism is a federation
  invariant — peers replaying the same operations produce
  bit-identical events.
- **O-3.** `RowStateAutomaton.validate(from:on:targetingFields:)`
  is total: every (prior state, verb) pair returns either a legal
  next state or a `RowStateError`. There are no silent
  acceptances and no panics.
- **O-4.** AuditGate's vocabulary validation is conservative: a
  write to an undeclared field is rejected; a write of a value
  outside the declared range is rejected; a write that mutates a
  bit outside the declared field width is rejected. Corruption
  is unrepresentable through the gate.

## § 5 — Behavioral contracts

### § 5.1 The nine substrate verbs

`Verbs.Substrate` is a namespace; each verb is a static function
that:

1. Validates preconditions (row exists for non-capture verbs;
   capture has no row).
2. Computes the new row state via the row-state automaton.
3. Builds the FieldWrites that encode the mutation.
4. Calls `AuditGate.admit` to produce the canonical audit event.
5. Returns the audit event for the consumer to append to the log.

The verbs are *pure*: they do not perform I/O, do not update any
persistent state, do not log. The consumer (LocusKit) appends the
returned audit event to its own audit log inside a transaction
that also updates the materialized projection (the live `drawers`
table, etc.).

Per-verb semantics live in cookbook §10. The verbs in
SubstrateLib are the canonical implementations; kit-side variants
(e.g. NeuronKit's `Tournament/BradleyTerry.swift` which is kit-local
batch MLE) are not substrate verbs.

### § 5.2 RowStateAutomaton

The row-state automaton is a closed transition table from
`(RowState, RowVerb)` to either `RowState` (the legal next state)
or `RowStateError.illegalTransition`. The table is the canonical
encoding of cookbook §9.3.

`validate(from:on:targetingFields:)` is the entry point. It:

1. Looks up the transition in the table.
2. If the verb is `.capture`, requires `from == nil` and a written
   state of `.active` or `.pending`.
3. If the verb is anything else, requires `from` to be a non-nil
   prior state and returns the table's next state.
4. Checks forbidden combinations on the merged fields via
   `ForbiddenCombinations.check(state:fields:)` (I-22).

`BitmapFields` is the input carrier: `(adjective, operational,
provenance)` as `UInt64` triples. The automaton inspects the merged
bitmap to evaluate forbidden combinations.

### § 5.3 AuditGate

`AuditGate.admit` is the single legal mutation path. It takes:

- The estate UUID, row ID, noun type, verb.
- The prior bitmap fields and prior lattice anchor.
- The vocabulary's frozen union (basis + the instance's declared
  fields).
- The HLC, the actor identifier.
- A list of `FieldWrite`s — each `(slot, value)` describing what
  to write where.

It produces a `Result<AuditEvent, AuditGateError>`. The success
case carries the canonical event; the failure case enumerates the
rejection reason (vocabulary violation, basis violation,
state-inconsistent-with-verb, content-ID collision).

The "corruption is unrepresentable" guarantee:

- Vocabulary validation: every FieldWrite's slot must be declared
  in the vocabulary; the value must fit the slot's width; the
  value must be in the slot's legal range.
- Basis validation: after merging the writes into the prior, the
  resulting state must satisfy the row-state automaton
  (`RowStateAutomaton.validate`).
- I-22 check: the merged fields must not violate any forbidden
  combination (via `ForbiddenCombinations.check`).

These three checks together guarantee that an admitted audit event
encodes a legal substrate state. Consumers that *only* mutate
through `AuditGate.admit` cannot produce a corrupt substrate row
no matter what they do.

## § 6 — Error model (conceptual)

The package raises:

- `AuditGateError.vocabularyViolation(slot:reason:)` — a FieldWrite's
  slot is not declared, value is out-of-range, or value exceeds
  width.
- `AuditGateError.basisViolation(RowStateError)` — the
  RowStateAutomaton refused the transition.
- `AuditGateError.stateInconsistentWithVerb(verb:)` — the verb
  argument and the written state do not match (e.g. capture with
  a non-initial written state, or mutate without a state
  transition).
- `RowStateError.illegalTransition(RowState, RowVerb)` — the
  (state, verb) pair is absent from the transition table.
- `RowStateError.forbiddenCombination(state:, fields:)` — the
  merged bitmap violates I-22.

`Substrate.Error` is the surface error type for verb-driver callers
(LocusKit); it wraps the gate-level errors with verb-context.

## § 7 — Conformance requirements

Per I-7 (cross-port bit-identity) and ML-5 (federation determinism),
this package ships conformance vectors:

- **AuditGate vectors:** identical events emitted for identical
  inputs across Swift and Rust ports. Includes content-ID hash
  identity.
- **RowStateAutomaton vectors:** every (state, verb) pair returns
  the same next state (or the same error) across ports.
- **ForbiddenCombinations vectors:** every forbidden combination
  identified by cookbook §9.5 is rejected; every legal combination
  is accepted; this matches across ports.
- **Verb vectors:** each of the nine verbs, given a fixture audit
  event sequence, produces an identical event across ports.

The vectors live in `tests/` directories of both legs.
