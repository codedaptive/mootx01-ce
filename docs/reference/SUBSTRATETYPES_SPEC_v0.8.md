---
status: draft
authors: Bob Pankratz
date: 2026-05-29
version: v0.8
package: SubstrateTypes
kind: Lib
relates_to:
  - SUBSTRATETYPES_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATEKERNEL_SPEC_v0.8.md      (sibling: hot-path bit operations over these types)
  - SUBSTRATEML_SPEC_v0.8.md          (sibling: cold-path algorithms over these types)
  - SUBSTRATELIB_SPEC_v0.8.md         (umbrella: orchestration composing this + Kernel + ML)
  - DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md (the four-package split, this is Layer 1)
  - GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md  (§2 rows, §3 fingerprints, §5 audit log, §6 matrices, §17 SimHash family, I-30 four-package invariant)
purpose: |
  SubstrateTypes is Layer 1 of the four-package substrate: the
  pure-data foundation that everything else stands on. It owns every
  value type the substrate hands across boundaries — fingerprints, the
  HLC, the audit row, the G-Set audit log, row identity, lattice
  anchors, the eight matrix carriers, the recall scoring tuple, the
  bit-tensor, the time range, and the algebra primitives (Hamming,
  SimHash, OR-reduce, FNV, bitwise) — but zero compute beyond the
  arithmetic each algebraic primitive contractually defines. No
  kernel dispatch, no hardware backends, no orchestration, no I/O,
  no storage. The companion INTERFACE document carries the bilingual
  signatures.
---

# SubstrateTypes Specification

## § 1 — What this package is

SubstrateTypes is the data foundation of the substrate. Every value
that crosses a substrate boundary — between kits, between Swift and
Rust, between peers in a federated estate, between in-memory state
and the audit log on disk — is one of the types in this package.

This package is a **Lib**: pure functions and value types with no
managed state, no actors, no lifecycle, no I/O. It gives values back
and never carries anything between calls. Compute is limited to the
arithmetic each algebraic primitive contractually defines (Hamming
distance, SimHash signing, OR-reduce, FNV hashing, bitwise rotates);
the *hot-path* implementations of those primitives — SIMD, NEON,
BNNS, Metal — live in SubstrateKernel and dispatch back through this
layer's scalar reference.

SubstrateTypes is therefore the substrate's portable surface. A peer
replica that ports SubstrateTypes correctly can deserialize an audit
event from another peer, reconstruct its row, project its state,
project its tier — without ever loading SubstrateKernel or
SubstrateML. The data is complete on its own.

## § 2 — Scope

This specification defines:

- The 256-bit fingerprint (`Fingerprint256`) and its three operations
  (XOR, sentinel zero, integer hash) per cookbook §3.
- The Hybrid Logical Clock (`HLC`) and its single-clock-per-estate
  generator (`HLCGenerator`) per cookbook §5.2, I-28.
- The audit event (`AuditEvent` in this package; the larger
  `GSetAuditLog` carries `AuditEntry`/`AuditVerb`/`AuditValue` for the
  CRDT shape — see § 5.3 below) per cookbook §5.1, I-20.
- The G-Set audit log (`GSetAuditLog`) — the CRDT shape, not its fold
  (fold lives in SubstrateML's `AuditLogFold`).
- Row identity (`RowId` = UUID), the substrate row (`Row`), the
  packed-bitmap row carrier (`RowBitmaps`, `BitVector216`).
- Row lifecycle data types (`RowState`, `RowVerb`, `RowStateError`).
  The *automaton* over these — the transition table, validate, the
  forbidden-combinations check — lives in SubstrateLib's
  `RowStateAutomaton`; only the enumerations and error type live here.
- The eight noun categories (`NounType`).
- Lattice anchors (`LatticeAnchor`) per cookbook §2.7, I-16.
- The eight matrix carriers (`MatrixF`, `MatrixC`, `MatrixO`,
  `MatrixT`) per cookbook §6, plus their composite keys
  (`CooccurrenceKey`, `CausalityKey`).
- The recall scoring tuple (`RecallScore`, `DistanceBreakdown`,
  `RecallResult`, `RowProjection`).
- The 3-D bit tensor (`ThreeDBitTensor`) per cookbook §6.7.
- The closed-interval time range (`TimeRange`) and HLC-range helpers.
- The count-vector (`CountVector256`) used for fingerprint
  aggregation per cookbook §6.6.
- The block mask (`BlockMask`) for per-block fingerprint slicing.
- The hyperplane family (`Hyperplane`, `HyperplaneFamily`) used to
  generate stable SimHash projections per cookbook §17.
- The algebra primitives over `Fingerprint256` and integers:
  `Hamming`, `SimHash`, `ORReduce`, `BitwiseArithmetic`, `FNV`. These
  carry the scalar arithmetic; the hardware-dispatched fast paths
  live in SubstrateKernel.

This specification does NOT define:

- API signatures — those live in `SUBSTRATETYPES_INTERFACE_v0.8.md`.
- Hardware-dispatched fast paths for the algebra primitives — those
  live in `SUBSTRATEKERNEL_SPEC_v0.8.md`.
- ML algorithms over these types (Bradley-Terry, NMF, FFT,
  Eigenvalue Centrality, the audit-log fold, the matrix decay model,
  feature extractors) — those live in `SUBSTRATEML_SPEC_v0.8.md`.
- Orchestration over these types (the nine verbs, the row-state
  automaton, the AuditGate write-gate) — those live in
  `SUBSTRATELIB_SPEC_v0.8.md`.
- Persistence schema for these types — that lives in
  `PERSISTENCEKIT_SPEC_v0.8.md`.

## § 3 — Position in the kit family

SubstrateTypes sits at the bottom of the substrate dependency graph.
Nothing else in the substrate depends on a package outside the
four-substrate family, and SubstrateTypes itself depends on nothing
in the family — it is the foundation.

```
              SubstrateLib            (orchestration: verbs + automaton + AuditGate)
                ↑    ↑    ↑
       SubstrateML  ↑   SubstrateKernel    (ML algos / hot-path bit ops)
                ↘  ↑  ↙
              SubstrateTypes           ← THIS PACKAGE
```

**Depends on:** nothing in the four-package family. Standard library
only (Swift: `Foundation`; Rust: `std`, `serde` for the wire format).

**Consumed by:** SubstrateKernel, SubstrateML, SubstrateLib, every
storage-using kit (PersistenceKit, LocusKit, VectorKit, CorpusKit,
EngramLib, ConvergenceKit, QueueKit, GeniusLocusKit, NeuronKit).

## § 4 — Invariants

The invariants below are restatements of the cookbook's I-1 through
I-30 as they pertain to types this package owns. The cookbook is the
canonical source; this section is a navigation aid.

- **I-1.** Every `Row` carries an immutable `RowId` (UUID, per I-29).
- **I-2.** `RowBitmaps` is a 216-bit packed structure (adjective 72 +
  operational 72 + provenance 72) per cookbook §2.1.
- **I-3.** `BitVector216` is the wire representation of a single
  `RowBitmaps` row; the in-memory representation per port may differ
  but must be bit-identical when serialized.
- **I-5.** `HLC` is totally ordered within an estate; equality requires
  all three fields (`physical`, `logical`, `nodeID`) to match.
- **I-7.** `Fingerprint256` operations are bit-identical across all
  ports — Swift, Rust, future Go and Python. The scalar reference
  in this package is the oracle; the kernel-dispatched fast paths in
  SubstrateKernel must match it on every input.
- **I-16.** `LatticeAnchor` is opaque to the substrate; storage-layer
  validation lives in EngramLib.
- **I-20.** `GSetAuditLog` is a G-Set CRDT; entries are append-only,
  never updated, never deleted.
- **I-22.** `RowVerb` enumeration is closed: the nine substrate verbs
  per cookbook §10 are the only legal mutation kinds. New mutation
  semantics require a cookbook amendment, not a kit-side extension.
- **I-25.** Each algebra primitive (Hamming, SimHash, OR-reduce, FNV)
  has one canonical implementation, one hard port. Multiple
  hardware-dispatched bodies are admitted; multiple algebraic
  definitions are not.
- **I-28.** `HLCGenerator` is single-instance per estate. Two
  generators feeding the same estate's audit log violate the
  total-ordering guarantee.
- **I-29.** `RowId` is a UUID. The genesis row-creation event
  generates it; subsequent events reference it.
- **I-30.** The substrate ships as four packages. SubstrateTypes is
  Layer 1.

## § 5 — Behavioral contracts

### § 5.1 Fingerprint256

`Fingerprint256` is a 256-bit value type with three contractually
defined operations:

- **XOR** (`a ^ b`): bitwise. Order-independent. The G-Set CRDT
  composes audit events through fingerprint XOR.
- **Sentinel zero** (`isZero`): the all-bits-zero fingerprint is
  reserved for "absent" and never produced by hashing real content.
  Hashes that produce `0x00…00` re-hash with a salt byte until
  non-zero.
- **Integer hash** (`Hashable`): the substrate's `Hashable` conformance
  produces stable hash values across ports.

### § 5.2 HLC

The Hybrid Logical Clock is a triple `(physical, logical, nodeID)`:

- `physical`: milliseconds since Unix epoch.
- `logical`: monotonic counter, incremented on every tick within the
  same physical millisecond.
- `nodeID`: stable per-estate identifier, breaks ties between
  concurrent events from different peers.

`HLC` is totally ordered via lexicographic compare; comparison across
estates is undefined.

`HLCGenerator` advances the HLC. `send(now:)` produces a new HLC
strictly greater than every prior one this generator has produced.
`receive(_:now:)` advances the generator past an externally observed
HLC, then produces a new HLC strictly greater than both.

### § 5.3 GSetAuditLog and AuditEvent

The G-Set audit log is the grow-only CRDT that carries every state
transition in the substrate. The fundamental unit is the
**`AuditEntry`** — a 1-row write into a row's audit history — with
fields `(rowId, hlc, verb, prior, after, eventId)`. The
**`AuditEvent`** (in this package, separate file) is the larger
structured record carrying the full event payload including row
projection, lattice anchor at the time of the event, and any
provenance frame. The audit log composes `AuditEntry`s; consumers
fold the log to project row state.

The CRDT shape is: union of two `GSetAuditLog`s is union of their
entry sets. Duplicate entries (same content, same HLC) are
merge-idempotent.

Folding the audit log into projected row state is **not** owned by
this package — it lives in `SubstrateML.AuditLogFold`. This package
owns the data shape; the fold (which is non-trivial) is an algorithm
and lives one layer up.

### § 5.4 RowState, RowVerb, RowStateError

`RowState` enumerates the legal row states; `RowVerb` enumerates the
nine legal mutation verbs (capture, reanchor, mutate, withdraw,
expunge, recall, propose, associate, learn — cookbook §10).
`RowStateError` is the error type the row-state automaton (in
SubstrateLib) raises on an illegal transition.

Only the *enumerations* live here. The transition table, the
`validate(from:on:targetingFields:)` function, and the forbidden-
combinations check (cookbook §9.5 / I-22) live in
`SubstrateLib.RowStateAutomaton`.

### § 5.5 Lattice anchors

`LatticeAnchor` carries a UDC code plus an optional Wikidata Q-ID.
The substrate treats anchors as opaque values — equality, ordering,
and serialization are defined, but UDC validation (legal code
syntax, prefix existence) is the responsibility of EngramLib at the
storage layer. Substrate consumers receive an anchor and pass it
through.

### § 5.6 Matrices

The four matrix carriers — `MatrixF` (feature), `MatrixC`
(cooccurrence), `MatrixO` (cooccurrence keyed pairs), `MatrixT`
(temporal causality) — are *value types*. They carry the contents
and the key schema; the *operations* over them (decay model, NMF
factorization, eigenvalue centrality) live in SubstrateML. A matrix
is movable between kits as a value; a matrix decayed-over-time is a
new matrix.

### § 5.7 Algebra primitives (scalar reference)

`Hamming`, `SimHash`, `ORReduce`, `BitwiseArithmetic`, `FNV` each
provide a **scalar reference implementation** of their operation.
The reference is the canonical oracle: hardware-dispatched
implementations in SubstrateKernel must produce identical output on
every input.

The reference implementations are bit-identical across ports per
I-7 and gated by conformance vectors (cookbook §17.6, M8).

## § 6 — Error model (conceptual)

Errors raised by SubstrateTypes are limited to:

- `Fingerprint256Error`: input length mismatch on construction.
- `HLCError`: invalid wire format on deserialize (`invalidWireLength`)
  — the 16-byte wire buffer was the wrong length. Per cookbook §5.2
  the HLC triple is `(physicalTime: Int64, logicalCount: Int32,
  nodeID: Int32)`; the logical counter increments monotonically and
  carries no separate overflow error.
- `RowStateError`: re-raised by `RowStateAutomaton` in SubstrateLib;
  the enumeration lives here.

No I/O errors, no allocation errors beyond what the standard library
raises, no concurrency errors (the package has no concurrent state).

## § 7 — Conformance requirements

Per I-7 and the conformance gate (cookbook §17.6, M8), this package
ships shared conformance vectors that the Swift and Rust ports must
both pass:

- **Fingerprint256 vectors:** XOR identity, XOR commutativity, XOR
  associativity, integer-hash stability, hash domain (all-zero
  reserved).
- **HLC vectors:** total ordering, generator monotonicity, receive
  step.
- **Algebra vectors:** Hamming distance over fixed pairs, SimHash
  signing of fixed inputs against a fixed hyperplane family,
  OR-reduce over fixed bit-arrays, FNV hashing over fixed strings,
  bitwise rotations.
- **Audit log vectors:** G-Set merge idempotence, dedup on identical
  entries.

The vectors live in `tests/` directories of both legs and are
run by CI on every commit. A diff in any vector — between Swift and
Rust output for the same input, or between either port and the
shared expectation — fails the conformance gate.
