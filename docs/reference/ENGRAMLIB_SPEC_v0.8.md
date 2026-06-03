---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: EngramLib
kind: Lib
relates_to:
  - ENGRAMLIB_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATELIB_SPEC_v0.8.md  (the fingerprint math this package wraps)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (engram encoding, similarity retrieval)
purpose: |
  EngramLib is the typed 256-bit memory-encoding API over SubstrateLib.
  It names the substrate's hash unit `Engram` and exposes the
  product-facing similarity, nearest-neighbour, threshold-filter, and
  union operations over engrams — hiding kernel selection and dispatch
  entirely. It is stateless and thread-safe; a `Session` handle offers
  kernel reuse for hot loops without changing results. The companion
  INTERFACE document carries the signatures.
---

# EngramLib Specification

## § 1 — What this package is

EngramLib is the thin, product-facing typed layer over SubstrateLib's
fingerprint math. It defines `Engram` (today a typealias for
`Fingerprint256`) as the stable public name for a unit of encoded
memory, and exposes the four operations product code actually performs
on engrams: distance, nearest-neighbour (`findNearest`), threshold
filtering (`findWithin`), and union (OR-reduce). It selects the optimal
SubstrateLib kernel internally and never exposes kernel types or
dispatcher decisions to callers.

This package is a **Lib**: stateless, pure encoding math over
SubstrateLib, with no managed state. The optional `Session` value type
holds a kernel instance for reuse but is itself `Sendable` and produces
results identical to the static API.

## § 2 — Scope

This specification defines:

- The `Engram` type name and its stability contract.
- Distance and batch-distance over engrams.
- k-nearest-neighbour and single-nearest retrieval, with ordering.
- Threshold-bounded filtering (`findWithin`).
- Union (OR-reduce) aggregation.
- The `Match` result type and its ordering.
- The `Session` reuse handle and its result-equivalence to the
  static API.

This specification does NOT define:

- API signatures — those live in `ENGRAMLIB_INTERFACE_v0.8.md`.
- The fingerprint representation, kernel dispatch, or the bit-for-bit
  reference obligation — those are SubstrateLib's (`SUBSTRATELIB_SPEC_v0.8.md`).
- Where engrams are stored or how vectors are indexed — see
  `VECTORKIT_SPEC_v0.8.md` and `PERSISTENCEKIT_SPEC_v0.8.md`.

## § 3 — Position in the kit family

```
SubstrateLib
   ▲
EngramLib   ← depends on SubstrateLib
   ▲
   ├── VectorKit   (engram distance in ANN ranking)
   └── (reasoning layers needing typed similarity)
```

**Depends on:** SubstrateLib.

**Consumed by:** VectorKit and any layer that needs typed engram
similarity without touching kernels directly.

## § 4 — Invariants

**I-1 (Engram stability):** `Engram` is the stable public name for the
encoded-memory unit. Its underlying representation is `Fingerprint256`
today and may widen in a future substrate version; callers treat the
engram opaquely and construct it through the provided initializers, not
by reaching into blocks.

**I-2 (statelessness):** the static API holds no mutable state and is
thread-safe; every static call obtains and discards its own kernel.

**I-3 (Session equivalence):** a `Session` produces results identical
to the static methods for every operation; it differs only in holding a
kernel instance for reuse. `Session` is `Sendable`.

**I-4 (delegation):** all compute delegates to SubstrateLib kernels;
EngramLib introduces no independent math and therefore inherits
SubstrateLib's scalar-reference and cross-leg parity guarantees.

## § 5 — Behavioral contracts

**B-1 (distance range):** `distance` is Hamming distance, 0…256;
identical engrams → 0, bit-inverses → 256.

**B-2 (batch indexing):** `distances(probe:candidates:)` returns an
array with the same count and indexing as `candidates`; empty input →
empty output.

**B-3 (nearest ordering):** `findNearest(…k:)` returns
`min(k, candidates.count)` matches sorted by distance ascending, ties
broken by candidate index ascending; `k <= 0` or empty input → empty.

**B-4 (within bound):** `findWithin(…maxDistance:)` returns every match
with `distance <= maxDistance` (inclusive), same ordering as B-3;
negative bound or empty input → empty.

**B-5 (union identity):** `union([])` is the zero engram; `union` is
the bitwise OR across inputs (associative, commutative).

**B-6 (Match equality/order):** two `Match` values are equal iff both
`index` and `distance` agree; `Match` is `Comparable` by (distance,
index).

## § 6 — Error model (conceptual)

Not applicable. EngramLib exposes no failable operations — out-of-range
or empty inputs return empty/`nil`/zero results (B-2…B-5) rather than
throwing. Malformed wire bytes are caught upstream by
`SubstrateLib.Fingerprint256Error` when an engram is decoded.

## § 7 — Conformance requirements

**C-1:** `findNearest` and `findWithin` ordering (distance asc, then
index asc) holds for every input, including ties (B-3, B-4).

**C-2:** `Session` results equal the static-API results for distance,
distances, findNearest, findWithin, and union on every shared test
vector (I-3).

**C-3:** `union([])` == zero engram; `distances(probe:[])` == `[]`;
`findNearest(…, in: [])` == `[]` / `nil` (B-2, B-3, B-5).

**C-4 (cross-leg):** the Swift and Rust versions agree on distance,
nearest, within, and union for every shared test vector (inherits
SubstrateLib I-7).
