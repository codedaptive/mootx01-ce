---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: SubstrateLib
kind: Lib
relates_to:
  - SUBSTRATELIB_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (§ kernel dispatch, fingerprint math, audit CRDT, conformance gate)
purpose: |
  SubstrateLib is the math bedrock of the substrate: the numerical
  primitives every other package depends on. It owns the 256-bit
  fingerprint type, Hamming/SimHash similarity, OR-reduce, the
  Hybrid Logical Clock, the grow-only audit-log CRDT, and the
  platform kernel dispatch (scalar / SIMD / NEON / BNNS / Metal /
  AVX) under one protocol. It has no storage, no state, and no I/O —
  pure functions only. The scalar kernel is the canonical reference
  that every other backend, and the Rust port, must match bit for
  bit. The companion INTERFACE document carries the signatures.
---

# SubstrateLib Specification

## § 1 — What this package is

SubstrateLib is the foundation layer: all numerical primitives the
substrate is built on, with nothing above them. It provides the
universal hash unit (`Fingerprint256`), the similarity and reduction
operations over it (Hamming distance, SimHash, OR-reduce, count-fold),
deterministic time (`HLC`, the Hybrid Logical Clock), the append-only
audit CRDT (`GSetAuditLog`), the row/verb value model the persistence
layer mirrors, and a family of ranking / matrix / graph / information-
theory algorithms used by the reasoning layers. Every compute path is
exposed through **kernel dispatch**: a `SubstrateKernel` protocol with
a scalar reference implementation and platform-optimized backends
(SIMD, NEON, BNNS, Metal, AVX) selected at runtime.

This package is a **Lib**: pure functions and value types with no
managed state, no actors, and no lifecycle. It gives values back and
manages nothing.

## § 2 — Scope

This specification defines:

- The 256-bit fingerprint type and its bit/block/wire contract.
- The similarity and reduction operations: Hamming distance,
  SimHash, OR-reduce, count-fold, top-k nearest-neighbour.
- Kernel dispatch: the `SubstrateKernel` protocol, the set of
  backends, and the bit-for-bit reference obligation.
- Deterministic time: the Hybrid Logical Clock and its total order.
- The grow-only audit-log CRDT and its merge semantics.
- The row/verb value model (`Row`, `NounType`, `RowState`, `RowVerb`,
  `LatticeAnchor`) shared with the persistence and substrate layers.
- The ranking, matrix, graph, information-theory, and feature-
  extraction algorithm families.
- The Swift ⇄ Rust conformance obligation.

This specification does NOT define:

- API signatures — those live in `SUBSTRATELIB_INTERFACE_v0.8.md`.
- Storage, persistence, or schema — see `PERSISTENCEKIT_SPEC_v0.8.md`.
- Typed memory encoding over fingerprints — see `ENGRAMLIB_SPEC_v0.8.md`.
- Estate/verb *semantics* — see `LOCUSKIT_SPEC_v0.8.md` and
  `GENIUSLOCUSKIT_SPEC_v0.8.md`. SubstrateLib carries the value model
  the substrate uses; it does not execute verbs.

## § 3 — Position in the kit family

```
SubstrateLib  ← (no dependencies)
      ▲
      │  depended on by
      ├── EngramLib        (typed 256-bit memory encoding)
      ├── PersistenceKit   (storage backends)
      ├── ConvergenceKit   (sync backends)
      ├── QueueKit         (job queue)
      ├── VectorKit, CorpusKit, LocusKit, GeniusLocusKit, NeuronKit
      └── (transitively) every kit that needs math
```

**Depends on:** nothing (Metal is a system framework used for the GPU
backend; it is not a package dependency).

**Consumed by:** every package that needs fingerprint math, time,
audit, or kernel dispatch.

## § 4 — Invariants

**I-1 (scalar kernel is the reference):** `ScalarKernel` is the
canonical implementation of every kernel operation. Every other
backend — SIMD, NEON, BNNS, Metal, AVX2/AVX512 — and the Rust port
MUST produce bit-for-bit identical results to it on every input.

**I-2 (fingerprint shape):** `Fingerprint256` is exactly 256 bits,
stored as four `UInt64` blocks. Its wire form is exactly 32 bytes;
any other length is rejected (`Fingerprint256Error.invalidWireLength`).

**I-3 (determinism):** every operation is a pure function of its
inputs. Wall-clock time enters only as an explicit parameter (e.g.
`HLCGenerator.send(now:)`); no member reads the system clock or any
ambient state internally.

**I-4 (no state, no I/O):** SubstrateLib holds no mutable global
state and performs no storage or network I/O. Feature extractors read
caller-supplied sample values, not live system APIs.

**I-5 (HLC total order):** `HLC` is `Comparable` and defines a total
order over `(physicalTime, logicalCount, nodeID)`; the packed `UInt64`
form round-trips losslessly.

**I-6 (audit log is a G-Set CRDT):** `GSetAuditLog` is a grow-only set
keyed by each entry's content hash. Merge is idempotent, commutative,
and associative; entries are never removed or mutated in place.

**I-7 (cross-port parity):** the Swift and Rust ports are
conformance-gated against shared test vectors. Neither port leads;
both must agree before either ships.

## § 5 — Behavioral contracts

**B-1 (dispatch transparency):** `PortableKernel.kernelForCurrentPlatform()`
selects a platform-optimal backend whose results equal `ScalarKernel`'s
(I-1). Callers may pin a backend with `PortableKernel.kernel(of:)`.

**B-2 (Hamming):** `Hamming.distance` is symmetric and ranges 0…256;
`similarity` is `1 − distance/256`.

**B-3 (OR-reduce):** `orReduce256` is associative and commutative with
identity `Fingerprint256.zero`.

**B-4 (HLC monotonicity):** `HLCGenerator.send(now:)` and
`receive(remote:now:)` return clocks strictly greater than any
previously issued or observed clock from the same generator.

**B-5 (audit convergence):** merging any two `GSetAuditLog` values
yields the union of their entries; repeated or reordered merges
converge to the same value (I-6).

**B-6 (top-k determinism):** `hammingTopK` returns results in a
deterministic order for equal distances (stable by input index), so
Swift and Rust agree on ties.

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery posture |
|---|---|---|
| `Fingerprint256Error` | malformed wire bytes (length ≠ 32) | surface; the caller supplied invalid bytes |
| `RowStateError` | an illegal row-state transition | surface; the verb/transition is not permitted by the state automaton |
| `SubstrateError` | invariant violations in pairing / handshake / general substrate math preconditions | surface; indicates a programming or protocol error, not a transient fault |

All categories are programmer/protocol errors, not retryable faults —
SubstrateLib does no I/O, so there are no transient failures.

## § 7 — Conformance requirements

**C-1 (kernel parity):** for every backend `k`, and for `hammingDistance256`,
`orReduce256`, `simhashCompute`, `hammingTopK`, `countFold256`, and their
batch variants, `k`'s output equals `ScalarKernel`'s on every shared test
vector (I-1).

**C-2 (fingerprint round-trip):** `Fingerprint256(wireBytes:).wireBytes`
is the identity on valid 32-byte input; a non-32-byte input throws
`Fingerprint256Error.invalidWireLength` (I-2).

**C-3 (HLC):** the packed form round-trips (`HLC(packed:).packed`), the
total order holds, and `send`/`receive` are monotonic (I-5, B-4).

**C-4 (audit CRDT):** `GSetAuditLog` merge is idempotent, commutative,
and associative on every shared test vector (I-6, B-5).

**C-5 (row-state automaton):** `RowStateAutomaton` permits exactly the
`(state, verb) → state` transitions the architecture spec defines;
disallowed transitions raise `RowStateError`.

**C-6 (cross-port, I-7):** the Swift and Rust ports produce identical
results for C-1…C-5 against the shared `glref` test vectors. A
divergence fails the conformance gate before either port ships.

## § 8 — Out of scope

- Typed `Engram` API over fingerprints → `ENGRAMLIB_SPEC_v0.8.md`.
- Persisting rows / audit logs → `PERSISTENCEKIT_SPEC_v0.8.md`.
- Vector embeddings and ANN search → `VECTORKIT_SPEC_v0.8.md`.
- The ARIA vocabulary the row/verb model serves →
  `ARIALEXICONLIB_SPEC_v0.8.md`.

## § 9 — Open questions

- AVX2/AVX512 backends are declared in `KernelKind` for the Linux
  x86_64 target; their conformance-vector coverage tracks the Rust
  port's platform matrix.

---

*End of SubstrateLib Specification v0.8.*
