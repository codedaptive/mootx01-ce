---
title: EngramLib Specification
version: 1.0.1
status: active
date: 2026-07-16
description: "Behavioral specification for EngramLib: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/ENGRAMLIB_INTERFACE.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
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

- API signatures — those live in `ENGRAMLIB_INTERFACE.md`.
- The fingerprint representation, kernel dispatch, or the bit-for-bit
  reference obligation — those are SubstrateLib's (`SUBSTRATELIB_SPEC.md`).
- Where engrams are stored or how vectors are indexed — see
  `VECTORKIT_SPEC.md` and `PERSISTENCEKIT_SPEC.md`.

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
thread-safe. In the Swift port the kernel is resolved once at module
load time and shared as a stateless `Sendable` value
(`_engramLibCachedKernel`); in the Rust port the static functions
construct a fresh kernel per call via `PortableKernel::for_current_platform()`.
Both strategies are correct because the kernel is stateless — every
static call is thread-safe and produces the same result regardless of
which reuse strategy the port uses.

**I-3 (Session equivalence):** a `Session` produces results identical
to the static methods for every operation; it differs only in holding a
kernel instance for reuse. `Session` is `Sendable`.

**I-4 (delegation):** compute delegates to SubstrateLib kernels for
all non-trivial operations (distance, batch distance, top-K nearest,
OR-reduce over a set). The pairwise-union overloads (`union(_:_:)` in
Swift, `union_pair` in Rust) operate directly on the substrate
`Fingerprint256` block representation without a kernel dispatch call —
the operation is a bitwise OR of four 64-bit words and is trivially
correct without a kernel intermediary. For everything else, EngramLib
introduces no independent math and therefore inherits SubstrateLib's
scalar-reference and cross-port parity guarantees
(`SUBSTRATELIB_SPEC.md`, I-7).

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

**C-4 (cross-port):** the Swift and Rust ports agree on distance,
nearest, within, and union for every shared test vector (inherits
`SUBSTRATELIB_SPEC.md`, I-7).

## Changelog

### 1.0.1 -- 2026-07-16
Corrected I-2: the Swift static API caches the kernel at module scope
(a stateless `Sendable` value resolved once at load); the Rust static
functions construct a fresh kernel per call. The previous text
incorrectly claimed every static call obtains and discards its own
kernel. Corrected I-4: pairwise-union overloads (`union(_:_:)` Swift /
`union_pair` Rust) operate directly on the `Fingerprint256` block
representation without a kernel dispatch call; qualified the
"all compute delegates to kernels" claim accordingly.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
