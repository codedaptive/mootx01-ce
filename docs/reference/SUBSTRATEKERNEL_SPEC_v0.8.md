---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateKernel
kind: Lib
relates_to:
  - SUBSTRATEKERNEL_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATETYPES_SPEC_v0.8.md        (Layer 1: the value types this package operates on)
  - SUBSTRATEML_SPEC_v0.8.md           (sibling: cold-path algorithms)
  - SUBSTRATELIB_SPEC_v0.8.md          (umbrella: orchestration)
  - DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md (the four-package split, this is Layer 2)
  - GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md  (§17 SimHash + kernel dispatch, §17.6 conformance gate, I-7 / I-25 / I-30)
purpose: |
  SubstrateKernel is Layer 2 of the four-package substrate: the
  bandwidth-bound bit operations and the platform kernel dispatch
  protocol that runs the substrate's hot path. It owns the
  `SubstrateKernel` protocol with one canonical scalar reference
  (`ScalarKernel`) and platform-optimized backends (SIMD, NEON, BNNS,
  Metal), plus the bit-field write/read primitive (`BitField`), the
  SHA-256 primitive (`SHA256`), and the Hamming nearest-neighbor
  primitive (`HammingNN`). Every hardware-dispatched body must be
  bit-identical to the scalar reference on every input — that is
  invariant I-7. The companion INTERFACE document carries the
  signatures.
---

# SubstrateKernel Specification

## § 1 — What this package is

SubstrateKernel is the hot-path layer of the substrate. Any
operation that runs in the §17.6 measured fast path of the cookbook
— SimHash signing, Hamming distance over large vectors, OR-reduce,
the audit-log per-event hash, the bit-field write into a packed
bitmap — has its scalar reference here, its kernel-dispatched
implementations here, and its conformance vectors here.

This package is a **Lib**: pure functions and value types with no
managed state. The `SubstrateKernel` protocol declares the dispatch
surface; concrete kernels (`ScalarKernel`, `SimdKernel`, `NeonKernel`,
`BnnsKernel`, `MetalKernel`) implement it. Selection is at runtime
via `PortableKernel.dispatch(_:)` which picks the fastest available
backend for the current device. Every backend produces bit-identical
output to `ScalarKernel` on every input (I-7).

The dispatch surface is *separable from* the algebra primitives that
live in SubstrateTypes. SubstrateTypes provides `Hamming.distance256`
as a scalar reference function in its own right; SubstrateKernel
provides `kernel.hammingDistance256(_:_:)` as a runtime-dispatched
fast path. Both must compute the same value. This duality is
deliberate: tests and small-batch consumers call the scalar
reference directly; large-batch hot-path consumers call the
dispatched kernel.

## § 2 — Scope

This specification defines:

- The `SubstrateKernel` protocol — the dispatch surface for
  hot-path operations.
- The scalar kernel (`ScalarKernel`) — the canonical reference
  implementation, the oracle.
- The platform-optimized kernels — `SimdKernel`, `NeonKernel`,
  `BnnsKernel`, `MetalKernel`. Each is conformance-gated against
  `ScalarKernel`.
- The dispatch entry point — `PortableKernel.dispatch(_:)` (Swift)
  / kernel selection (Rust).
- The `BitField` primitive — the substrate's parametric bit-field
  write/read used by every kit-level bit operation.
- The `SHA256` primitive — used by `AuditGate` for the content-ID
  hash on every audit event.
- The `HammingNN` primitive — Hamming nearest-neighbor over a
  candidate set, used by recall.

This specification does NOT define:

- API signatures — those live in `SUBSTRATEKERNEL_INTERFACE_v0.8.md`.
- The value types these kernels operate on — those live in
  `SUBSTRATETYPES_SPEC_v0.8.md` (`Fingerprint256`, `HyperplaneFamily`,
  etc.).
- ML algorithms over these primitives — those live in
  `SUBSTRATEML_SPEC_v0.8.md`.
- The orchestration that uses these primitives (`AuditGate` calls
  `BitField` and `SHA256`; verb mechanics) — that lives in
  `SUBSTRATELIB_SPEC_v0.8.md`.

## § 3 — Position in the kit family

```
              SubstrateLib              (orchestration: verbs + automaton + AuditGate consumes Kernel)
                ↑    ↑    ↑
       SubstrateML  ↑   SubstrateKernel  ← THIS PACKAGE
                ↘  ↑  ↙
              SubstrateTypes              (Layer 1: the value types this package operates on)
```

**Depends on:** `SubstrateTypes`.

**Consumed by:** `SubstrateLib` (AuditGate calls `BitField` and
`SHA256` directly; verb mechanics dispatch through `PortableKernel`),
`EngramLib` (one site: hash-mining for the lattice tree),
`GeniusLocusKit` (one site: hot-path retrieval projection),
`LocusKit` (BitField for adjective/operational/provenance bitmap
writes through `AuditGate`).

## § 4 — Invariants

- **I-7.** Every hardware-dispatched kernel produces bit-identical
  output to `ScalarKernel` on every input. This is conformance-gated
  at every commit.
- **I-25.** Each kernel-dispatched operation has *one* canonical
  algebraic definition (in SubstrateTypes) and *one* canonical scalar
  reference (here in SubstrateKernel). Multiple hardware-dispatched
  bodies are admitted; multiple definitions are not.
- **I-30.** The substrate ships as four packages. SubstrateKernel is
  Layer 2.

Kernel-specific:

- **K-1.** Dispatch is non-allocating on the hot path. A kernel call
  on an N-fingerprint batch performs O(1) allocations regardless of N.
- **K-2.** Selection is deterministic per device: `PortableKernel.
  dispatch(_:)` picks the same backend on every call for a given
  device. Backend selection may be overridden for testing.
- **K-3.** A kernel that cannot run on the current device (e.g. Metal
  on a non-GPU host) does not throw — it is filtered out of the
  selection list before dispatch.
- **K-4.** `BitField` writes preserve every bit outside the addressed
  field. A write that addresses bits `[shift, shift+width)` reads the
  prior value of every other bit and writes them through unchanged.

## § 5 — Behavioral contracts

### § 5.1 The `SubstrateKernel` protocol

Every kernel implements the protocol's surface:

- `hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int`
- `simhashSign(_ input: SimHashInput, _ family: HyperplaneFamily) -> Fingerprint256`
- `orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256`
- `xor256(_ a: Fingerprint256, _ b: Fingerprint256) -> Fingerprint256`

Implementations vary in their dispatch strategy (loop unrolling,
SIMD width, GPU offload) but every implementation produces the same
result on the same input. This is the I-7 conformance contract.

### § 5.2 ScalarKernel: the canonical reference

`ScalarKernel` is implemented in pure Swift / pure Rust with no
hardware-specific intrinsics, no allocation beyond what's strictly
necessary, no parallelism. It is the *oracle*: every other backend
is conformance-gated against it.

Scalar implementations may not be the fastest, but they are the
clearest. When debugging a kernel discrepancy, scalar is the
reference for what the answer *is*; the dispatched backend is the
suspect.

### § 5.3 SIMD / NEON / BNNS / Metal kernels

Hardware-optimized backends. Selection priority (Swift, on Apple
silicon):

1. `MetalKernel` — GPU, best for batches > ~64K.
2. `BnnsKernel` — Apple's BNNS framework, best for medium batches.
3. `NeonKernel` — ARM NEON intrinsics, best for ARM CPU-only batches.
4. `SimdKernel` — portable SIMD via the Swift Numerics layer, fallback.
5. `ScalarKernel` — always available, fallback.

Rust port today exposes `ScalarKernel` plus portable SIMD via the
`simd-nightly` feature; NEON/BNNS/Metal Apple-specific backends are
Swift-only by design.

### § 5.4 BitField

`BitField.writeField(into:value:shift:width:)` writes `value`
into a packed `Int64` bitmap at the given shift and width, masking
out the prior bits in that range and ORing the new value in. The
operation is one read-modify-write; the read of the prior value is
required for K-4.

`BitField.extractField(from:shift:width:)` reads `width` bits from
the packed bitmap starting at `shift`, right-shifted to the low bits
of the returned `Int64`.

`BitField.maskedEquals(a:b:shift:width:)` is the comparison
counterpart: returns true iff the `[shift, shift+width)` bits of `a`
and `b` are equal.

### § 5.5 SHA256

`SHA256.hash256(_:)` computes a 32-byte SHA-256 over the input.
Used primarily by `AuditGate` for the content-ID hash on every
audit event.

### § 5.6 HammingNN

`HammingNN.search(query:candidates:topK:)` finds the top-K
fingerprints in the candidate set by Hamming distance to the query.
The result is sorted ascending by distance. Ties broken by
candidate index.

## § 6 — Error model (conceptual)

`SubstrateKernel` does not raise errors on its public surface. Inputs
that would produce errors are rejected at the SubstrateTypes layer
(e.g. `Fingerprint256(bytes:)` throws on a wrong-sized byte input)
before reaching a kernel. Kernel-internal allocation failures
(unlikely; the hot path is non-allocating per K-1) bubble up as the
host language's standard allocation-failure behavior.

## § 7 — Conformance requirements

Every kernel that ships against the `SubstrateKernel` protocol is
gated by:

- **Hot-path vector match (I-7):** every operation, on every input
  in the shared conformance vector set, produces bit-identical
  output across all selected backends.
- **`BitField` round-trip vectors:** writeField then extractField
  returns the original value; bits outside the field range are
  preserved per K-4.
- **`SHA256` vectors:** RFC 6234 test vectors, plus substrate-specific
  vectors that exercise the audit-event content-ID hash path.
- **`HammingNN` vectors:** top-K results match the scalar reference
  on every candidate set, including tie-breaking order.

The conformance vectors live in `tests/` directories of both legs.

## § 8 — Out of scope

- Float-input SimHash (`FloatSimHash`) — lives in SubstrateML.
- Audit-log fold — lives in SubstrateML.
- Verb mechanics — live in SubstrateLib.
- Row-state automaton — lives in SubstrateLib.
- AuditGate write gate — lives in SubstrateLib (it *calls* this
  package's `BitField` and `SHA256` but is itself orchestration, not
  hot-path).
- Storage I/O — lives in PersistenceKit.

## § 9 — Open questions

- **Rust NEON support.** Today Rust uses portable SIMD only; ARM-
  specific NEON is Swift-only. Whether to add a Rust NEON kernel via
  `std::arch::aarch64` intrinsics is deferred until a Rust-host
  performance pinch point appears.
- **Metal kernel test budget.** Metal kernel conformance is gated in
  CI but the gate is slower than other backends. Whether to
  optionally tier the gate (full pass nightly, smoke pass per-commit)
  is open.
