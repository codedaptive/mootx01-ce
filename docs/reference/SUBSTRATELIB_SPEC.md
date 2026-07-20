---
title: SubstrateLib Specification
version: 1.2.0
status: active
date: 2026-06-28
description: "Behavioral specification for SubstrateLib: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/SUBSTRATELIB_INTERFACE.md (the API surface this spec contracts)
  - docs/reference/SUBSTRATETYPES_SPEC.md (Layer 1: value types this package orchestrates)
  - docs/reference/SUBSTRATEKERNEL_SPEC.md (Layer 2: hot-path primitives this package composes)
  - docs/reference/SUBSTRATEML_SPEC.md (Layer 3: cold-path algorithms this package composes)
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md (§5 audit log, §9 row-state automaton, §10 the nine verbs, I-22 / I-25 / I-26 / I-30)
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

- The Merkle content-integrity hash pipeline (`MerkleHash`) per
  the node-integrity contract §16: domain-separated SHA-256 hashing for leaf content,
  interior tree nodes, and tombstones.
- The keyed-commitment API (`KeyedCommitment`) per the node-integrity contract §17:
  HMAC-SHA256 commitment for expunge provenance, plus the
  `CommitmentAuditLog` G-Set CRDT for audit trail.

This specification does NOT define:

- API signatures — those live in `SUBSTRATELIB_INTERFACE.md`.
- The value types these verbs operate on — those live in
  `SUBSTRATETYPES_SPEC.md`.
- The hot-path primitives AuditGate consumes (BitField, SHA256) —
  those live in `SUBSTRATEKERNEL_SPEC.md`.
- The cold-path algorithms verbs may call (AuditLogFold, MatrixDecay)
  — those live in `SUBSTRATEML_SPEC.md`.
- Per-verb storage I/O — that's PersistenceKit's job; verbs here
  produce audit events and write through a `StorageRow` interface
  that consumers implement.
- The kit-side verb-driver glue — that lives in
  `LOCUSKIT_SPEC.md` (and equivalent for any future verb-driver).

## § 3 — Position in the kit family

```
              SubstrateLib              ← THIS PACKAGE (orchestration)
                ↑    ↑    ↑    ↑
       SubstrateML  ↑   SubstrateKernel ↑
                ↘  ↑  ↙             IntellectusLib (telemetry floor)
              SubstrateTypes
```

**Depends on:** `SubstrateTypes`, `SubstrateKernel`, `SubstrateML`,
`IntellectusLib`.

`IntellectusLib` is a permitted lower-layer dependency: the
zero-dependency telemetry floor (no substrate imports). It sits
below SubstrateLib without inverting layering.

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
- **O-5.** AuditGate's basis vocabulary is derived from typed
  enums, not hardcoded integer arrays. The four SubstrateLib-local
  CaseIterable enums (`AuditState`, `AuditSensitivity`,
  `AuditExportability`, `AuditTrust`) are the single source of truth
  for the legal values of each adjective-axis basis slot. Adding a
  new enum case automatically extends the gate vocabulary. Cross-layer
  adjective parity vs LocusKit's adjective types is CI-enforced.

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

The four Cluster-B historical states — `decayed`, `withdrawn`,
`expired`, `superseded` — each carry a `revive` edge back to `active`
keyed on `.observe` ("re-observation revives"); this is the complete
revive surface. The automaton is stateless on `(state, verb)`, so it
admits `superseded → active` unconditionally; the lineage-conflict
domain rule (a superseded row may not revive while a living successor
holds the lineage head) is enforced by the consuming kit (LocusKit's
revive guard), not here. `accepted`, `rejected`, and `tombstoned` have
no revive edge.

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
  value must be in the slot's legal range. The basis FieldSlots'
  legal-value sets are derived from SubstrateLib-local CaseIterable
  enums (`AuditState`, `AuditSensitivity`, `AuditExportability`,
  `AuditTrust`) — no hardcoded integer arrays. Cross-layer adjective
  parity vs LocusKit's adjective types is CI-enforced.
- Basis validation: after merging the writes into the prior, the
  resulting state must satisfy the row-state automaton
  (`RowStateAutomaton.validate`).
- I-22 check: the merged fields must not violate any forbidden
  combination (via `ForbiddenCombinations.check`).

These three checks together guarantee that an admitted audit event
encodes a legal substrate state. Consumers that *only* mutate
through `AuditGate.admit` cannot produce a corrupt substrate row
no matter what they do.

### § 5.4 MerkleHash pipeline (the node-integrity contract §16)

`MerkleHash` computes domain-separated SHA-256 hashes for the Merkle
content-integrity tree. Three functions:

- **`leaf`**: hashes a drawer's content and embedding vectors with domain
  tag 0x00 (LEAF). The canonical byte encoding (v2) is: domain tag (1 byte) +
  drawer UUID (16 bytes big-endian) + content length (8 bytes u64 BE) +
  content bytes + vector count (4 bytes u32 BE) + sorted vectors. Vectors
  are sorted by (modelID, vectorIndex) ascending; each vector is encoded as:
  model_id UTF-8 length (4 bytes u32 BE) + model_id bytes +
  vector_index (4 bytes u32 BE) + float count (4 bytes u32 BE) +
  IEEE-754 LE floats. The v2 encoding writes vector identity (model_id +
  vector_index) into the preimage before the float payload so that
  substituting a vector from a different model or slot changes the leaf hash.
  Cross-port conformance pin (SHA-256, drawer=12345678-1234-1234-1234-123456789abc,
  content="hello", one vector model-a/idx=0/[1.0f,2.0f]):
  cb18e8a5dcff4eb955f731bf75c078b9390a175ff225cc67a1ff0f1d3fa192dc.
- **`interior`**: hashes a set of child (UUID, ContentHash) pairs with
  domain tag 0x01 (INTERIOR). Children are sorted by UUID big-endian
  bytes before hashing, making the result order-independent. An empty
  child set returns `MerkleRoot.empty`.
- **`tombstone`**: hashes a drawer UUID with domain tag 0x02 (TOMBSTONE).

Invariants:
- **Deterministic**: same inputs produce the same hash across calls and
  across Swift/Rust ports (bit-identical).
- **Domain-separated**: leaf, interior, and tombstone hashes for the same
  UUID are always distinct due to the domain tag prefix.
- **Vector order-independent**: the hash is invariant to the input order
  of vectors (canonical sort before hashing).
- **Vector identity-bound (v2)**: replacing a vector's model_id or
  vector_index while keeping the same floats always changes the leaf hash.
  This binding closes the vector substitution gap in keyed commitments.

The `canonicalLeafBytes` helper is shared with `KeyedCommitment` (§5.5)
— one encoding, two uses.

### § 5.5 KeyedCommitment API (the node-integrity contract §17)

`KeyedCommitment.commit` computes an HMAC-SHA256 over the canonical leaf
bytes (the same encoding `MerkleHash.leaf` uses) but with the COMMITMENT
domain tag 0x03 instead of LEAF 0x00. The HMAC key is an estate-held
secret; the key version is preserved alongside the HMAC output in
`KeyedCommitmentValue`.

Invariants:
- **Deterministic**: same key + key version + drawer + content + vectors
  produce the same HMAC across calls and across ports.
- **Domain-separated from leaf hash**: a commitment is always distinct
  from the corresponding leaf hash (different domain tag + HMAC vs SHA-256).
- **Key-dependent**: different keys produce different commitments.
- **Key version preserved**: the `keyVersion` field is carried through
  unchanged, enabling key rotation without commitment recomputation.

`KeyedCommitmentAuditEntry` is an immutable audit record carrying the
drawer ID, the commitment value, the tombstone HLC, and a reason string.
Its `id` field is a deterministic 32-byte SHA-256 over the entry's
identifying fields, ensuring two replicas producing the same logical
entry produce identical IDs.

`CommitmentAuditLog` is a grow-only set (G-Set CRDT) keyed by content
hash. Add is idempotent; merge is set union. Two replicas converge
regardless of message order.

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

- **MerkleHash vectors:** leaf, interior, and tombstone hashes are
  deterministic and bit-identical across Swift and Rust ports for the
  same inputs. Vector sort-order independence is verified by passing
  the same vectors in different orders and asserting identical hashes.
- **KeyedCommitment vectors:** HMAC commitments are deterministic
  and bit-identical across ports. Domain separation from leaf hash
  is verified (different domain tag + HMAC vs SHA-256).
- **CommitmentAuditLog vectors:** deterministic content-ID for
  identical entry fields across ports. Idempotent add, set-union
  merge, tombstone-HLC ordering all verified.

The vectors live in `tests/` directories of both legs.

## § 8 — Self-report telemetry

SubstrateLib emits telemetry via `IntellectusLib`. The telemetry is
**off by default** — when monitoring is disabled (the default), every
`report!` / `Intellectus.report(_:)` call is a single atomic load
plus branch (~1 ns). No `StatSample` is constructed, no lock is
acquired, no allocation occurs on the off-path.

### Emit sites

| Metric name | Emitted at | Tags |
|---|---|---|
| `substratelib.verb.capture_count` | After successful `capture` | `noun_type` (NounType ordinal string) |
| `substratelib.verb.reanchor_count` | After successful `reanchor` | — |
| `substratelib.verb.mutate_count` | After successful `mutate` | `mutation_kind` (verb token) |
| `substratelib.verb.withdraw_count` | After successful `withdraw` | — |
| `substratelib.verb.expunge_count` | After successful `expunge` | — |
| `substratelib.verb.recall_count` | After `recall` returns | `result_count` (row count string) |
| `substratelib.audit_gate.admit_count` | After successful `AuditGate.admit` | `noun_type` |
| `substratelib.audit_gate.reject_count` | After rejected `AuditGate.admit` | `violation` (gate violation name) |
| `substratelib.write_gate.admitted_count` | Same as audit admit | `verb` |
| `substratelib.write_gate.rejected_count` | Same as audit reject | `verb`, `reason` |

### Determinism invariant

Timestamps are caller-supplied (`ts: Double` Swift / `ts: f64` Rust
— epoch seconds). SubstrateLib never reads a clock. The caller
stamps once at the verb boundary and passes the value through.

This is mandatory: SubstrateLib is the determinism floor. Any clock
read inside the substrate would break federation determinism and
the scalar/Metal/BLAS conformance guarantee.

### Test isolation

Tests that install a telemetry sink must not corrupt parallel test
runs. The strategy is a timestamp-filtered sink: each test picks a
unique sentinel `Double` / `f64` and passes it as `ts:` to the verb
call. The sink records only samples whose `ts` exactly equals the
sentinel. Non-telemetry calls use `ts: 0.0`, which every
timestamp-filtered sink discards.

## Changelog

### 1.2.0 -- 2026-06-28
Security fix: §5.4 leaf encoding upgraded to v2. vector_index type corrected
to u32 BE (was incorrectly specified as i32 BE). v2 per-vector layout binds
model_id and vector_index into the preimage before the float payload, closing
the vector substitution gap in keyed commitments (WS2-F4). Cross-port
conformance pin added. New invariant: vector identity-bound. Added withdraw
verb matrix update to §2 invariants (WS2-F5).

### 1.1.0 -- 2026-06-20
Added §5.4 MerkleHash pipeline (the node-integrity contract §16) and §5.5 KeyedCommitment API
(the node-integrity contract §17) behavioral contracts. Extended §2 scope and §7 conformance
requirements to cover MerkleHash, KeyedCommitment, and CommitmentAuditLog.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
