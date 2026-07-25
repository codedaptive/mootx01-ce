---
title: SubstrateKernel Specification
version: 1.2.0
status: active
date: 2026-07-16
description: "Behavioral specification for SubstrateKernel: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/engineering/SUBSTRATE_PERFORMANCE_GATE.md#7-production-kernel-selection
  - docs/reference/SUBSTRATEKERNEL_INTERFACE.md
  - docs/reference/SUBSTRATETYPES_SPEC.md
  - docs/reference/SUBSTRATEML_SPEC.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/engineering/HARNESS_REFERENCE.md#6-the-four-package-substrate-split
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
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
`MetalKernel`) implement it. Selection is at runtime
via `PortableKernel.kernelForCurrentPlatform()` (Swift) /
`PortableKernel::for_current_platform()` (Rust), which picks the
fastest available backend for the current device. Every backend produces bit-identical
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
  `MetalKernel`. Each is conformance-gated against `ScalarKernel`.
- The dispatch entry point — `PortableKernel.kernelForCurrentPlatform()`
  (Swift) / `PortableKernel::for_current_platform()` (Rust).
- The `BitField` primitive — the substrate's parametric bit-field
  write/read used by every kit-level bit operation.
- The `SHA256` primitive — used by `AuditGate` for the content-ID
  hash on every audit event.
- The `HammingNN` primitive — Hamming nearest-neighbor over a
  candidate set, used by recall.
- The `FloatVecOps` primitive — IEEE-754 scalar float-vector operations
  (`l2Norm`, `l2Normalize`, `dot`, `cosine`); the canonical reference
  for embedding normalization and similarity, consumed by `SubstrateML`.

This specification does NOT define:

- API signatures — those live in `SUBSTRATEKERNEL_INTERFACE.md`.
- The value types these kernels operate on — those live in
  `SUBSTRATETYPES_SPEC.md` (`Fingerprint256`, `HyperplaneFamily`,
  etc.).
- ML algorithms over these primitives — those live in
  `SUBSTRATEML_SPEC.md`.
- The orchestration that uses these primitives (`AuditGate` calls
  `BitField` and `SHA256`; verb mechanics) — that lives in
  `SUBSTRATELIB_SPEC.md`.

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
- **K-2.** Selection is deterministic per device:
  `PortableKernel.kernelForCurrentPlatform()` /
  `PortableKernel::for_current_platform()` picks the same backend on
  every call for a given device. Backend selection may be overridden
  for testing via `PortableKernel.kernel(of:)` /
  `PortableKernel::of_kind()`.
- **K-3.** A kernel that cannot run on the current device (e.g. Metal
  on a non-GPU host) does not throw — it is filtered out of the
  selection list before dispatch.
- **K-4.** `BitField` writes preserve every bit outside the addressed
  field. A write that addresses bits `[shift, shift+width)` reads the
  prior value of every other bit and writes them through unchanged.

## § 5 — Behavioral contracts

### § 5.1 The `SubstrateKernel` protocol

Every kernel implements the protocol's surface:

- `popcount64(_ x: UInt64) -> Int`
- `hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int`
- `orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256`
- `hammingTopK(probe:candidates:k:) -> [(index:Int, distance:Int)]`
- `simhashCompute(subhashes:[UInt64], families:[HyperplaneFamily]) -> Fingerprint256`
  (Swift; Rust uses `simhash_block(input:&[u64], family:&HyperplaneFamily) -> u64`
  per block — see INTERFACE § 2 for the sanctioned idiom split)
- Batched variants (`hammingDistanceBatch`, `simhashBlockBatch`,
  `orReduceBatch`, `countFold256`, `countFoldBatch`) with default impls.
- `floatSimHashProject(vector:[Float], planes:FloatSimHashPlanes) -> Fingerprint256`
  (Swift) / `float_simhash_project(vector:&[f32], planes:&FloatSimHashPlanes) -> Fingerprint256`
  (Rust) — the dispatch home for `SubstrateML.FloatSimHash.project`
  (the float variant the embedding providers use). See § 5.4.

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

### § 5.3 SIMD / NEON / Metal kernels

Hardware-optimized backends. Selection priority (Swift, on Apple
silicon):

1. `MetalKernel` — GPU, best for batches > ~64K.
2. `NeonKernel` — ARM NEON intrinsics, best for ARM CPU-only batches.
3. `SimdKernel` — portable SIMD via the Swift Numerics layer; the
   production default on aarch64.
4. `ScalarKernel` — always available, ultimate fallback.

BnnsKernel was measured on 2026-06-06 (apple-m5-max, macOS 26.5) and
removed: slower than SimdKernel on every op, with BNNSGraph matmul
crashing on current macOS. See the measured OR-reduce selection,
the measured Hamming selection, and the measured SimHash selection
addenda for the disposal numbers.

Rust version today exposes `ScalarKernel` plus portable SIMD via the
`simd-nightly` feature; NEON/Metal are Apple-specific backends
implemented in the Swift version; the Rust version targets the
non-Apple ecosystem and does not provide them.

### § 5.4 Float-input SimHash projection (dispatch promotion)

The float-input SimHash projection — `SubstrateML.FloatSimHash.project`,
which the embedding providers (FDC, distributional, named-model) call to
turn a dense float vector into a `Fingerprint256` — is a backend-selected
dispatch op of this surface, with `ScalarKernel` as the canonical oracle
(I-25). It previously ran only as a hand-written scalar loop in SubstrateML,
bypassing the dispatch; promoting it gives the float variant the same
multi-backend treatment `simhashCompute` (the bitmap-subhash variant) already has.

Backend selection follows `the measured SimHash selection`:

- **`SimdKernel` is the production backend**, via the measured
  over-hyperplanes vertical-SIMD pattern: the 256 hyperplanes are
  independent, so each lane runs *one* hyperplane's signed-sum
  accumulation in canonical (scalar-equal) order. This is parallelism
  *across* hyperplanes, never a split of a single reduction — so the output
  is **bit-identical to `ScalarKernel`** (cross-port AND cross-backend),
  preserving the engram as a stable Hamming key.
- **Crossover ~ batch ≥ 4**: below that the per-batch setup loses; at and
  above it SIMD wins (≈2–6× per the decision's measurements). A single
  capture (bs=1) stays scalar.
- **Metal/GPU is declined** for this op (the decision's Phase 2.γ-3): the
  ~70 µs Metal dispatch floor puts the crossover near ~1,186 calls and
  SimdKernel already wins below that. Revisit only at dreaming-daemon
  bulk-index scale (10K–1M per call); no Metal shader is built.

`l2Normalize` (FloatVecOps), which feeds this projection, is parallelized
the same way — across vectors, each vector's sum-of-squares serial — and is
secondary (cheap relative to the 256-hyperplane projection).

### § 5.5 BitField

`BitField.writeField(_ value:Int64, into bitmap:Int64, shift:Int, width:Int)`
writes `value` into a packed `Int64` bitmap at the given shift and
width, masking out the prior bits in that range and ORing the new
value in. The operation is one read-modify-write; the read of the
prior value is required for K-4.

`BitField.extractField(_ bitmap:Int64, shift:Int, width:Int)` reads
`width` bits from the packed bitmap starting at `shift`, right-shifted
to the low bits of the returned `Int64`.

`BitField.maskedEquals(_ bitmap:Int64, mask:Int64, expected:Int64)` is
the comparison counterpart: returns true iff `(bitmap & mask) == expected`.
The `mask` and `expected` share the same bit range (caller must
pre-shift `expected` into the field's position).

### § 5.6 SHA256

`SHA256.hash(_ bytes:[UInt8])` computes a 32-byte SHA-256 over the input.
Used primarily by `AuditGate` for the content-ID hash on every
audit event.

### § 5.7 HammingNN

`HammingNN.topK(anchor:candidates:k:blocks:)` finds the top-K
nearest fingerprints in the candidate set by Hamming distance to the
anchor. `candidates` iterates `(rowID: UUID, fingerprint: Fingerprint256)`
pairs. The result is sorted ascending by distance. Ties are broken by
`rowID.uuidString` ascending (not candidate index) — this gives
deterministic, reproducible results across runs and Swift/Rust ports.

### § 5.8 FloatVecOps

Scalar IEEE-754 float-vector operations. The canonical reference that
`SubstrateML.FloatSimHash` and any embedding-normalization consumer
must match bit for bit. No hardware intrinsics, no BLAS; the scalar
path is the conformance oracle.

`FloatVecOps.l2Norm(_ v:[Float]) -> Float` — Euclidean norm.
Accumulates `sum(x*x)` in coordinate order then takes `sqrt`. Returns
`0.0` for an empty vector.

`FloatVecOps.l2Normalize(_ v:[Float]) -> [Float]` — L2-normalise.
Returns the zero vector unchanged when the norm is zero (the honest
"no information" signal that projects to `Engram.zero` through
`FloatSimHash`). Operation sequence is fixed: sum-of-squares →
guard on zero → `invNorm = 1.0 / sqrt(normSq)` → element-wise
multiply. This exact sequence is the bit-identity contract both
ports must reproduce.

`FloatVecOps.dot(_ a:[Float], _ b:[Float]) -> Float` — dot product.
Precondition: equal lengths (panics in both debug and release builds).

`FloatVecOps.cosine(_ a:[Float], _ b:[Float]) -> Float` — cosine
similarity for L2-normalised unit vectors. For unit vectors equals
the dot product. Callers must normalise both inputs first; a debug
precondition fires when either norm deviates from 1.0 by more than
1e-5.

The Rust `float_vec_ops` module (`l2_norm`, `l2_normalize`, `dot`,
`cosine`) is byte-identical to the Swift implementation. The Rust
`l2_normalize` uses `1.0 / norm_sq.sqrt()` explicitly (not `.recip()`)
to guarantee the same bit pattern as Swift's
`1.0 / normSq.squareRoot()`.

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

## § 8 — Telemetry

### § 8.1 Metric shape

`PortableKernel.kernelForCurrentPlatform()` / `PortableKernel::for_current_platform()`
emits one metric via `IntellectusLib` at the selection site:

| Field | Value |
|-------|-------|
| `name` | `"substrate.kernel.backend_selected"` |
| `value` | `1.0` (event-counter) |
| `tags.backend` | the selected kernel kind's raw string (`"simd"`, `"scalar"`, …) |
| `tags.arch` | compile-time arch tag (`"arm64"` / `"aarch64"` / `"x86_64"` / `"other"`) |
| `ts` | caller-supplied epoch seconds (`Date().timeIntervalSince1970` in Swift; `SystemTime::now()` in Rust) |

The metric is emitted once per factory call. It is a factory-level side-effect,
not a hot-path operation: `kernelForCurrentPlatform()` is called at construction time,
not inside any per-element loop.

### § 8.2 Off-path gate

When monitoring is **off** (the default), the `Intellectus.report(_:)` autoclosure
(Swift) / `report!` macro body (Rust) is **never evaluated**. The off-path cost is a
single `Atomic<Bool>` load + branch (~1 ns, lock-free). No clock is read. No string
tags are allocated. The kernel's conformance-gated math output is therefore completely
unaffected by the telemetry addition.

### § 8.3 No runtime fallback metric

The selection path in `kernelForCurrentPlatform()` is compile-time static (a `#if arch`
predicate in Swift, a `#[cfg]` predicate in Rust). There is no runtime fallback in this
factory. A `substrate.kernel.fallback` ("fallback rate") metric is therefore **not emitted**
from SubstrateKernel in v1.0: with selection resolved at compile time, no fallback event can
occur. The fallback rate is N/A for this kit.

### § 8.4 Dependency addition

SubstrateKernel now depends on `IntellectusLib` (both `Package.swift` and `Cargo.toml`).
`IntellectusLib` is a zero-dependency leaf; adding it as a SubstrateKernel dependency does
not introduce a layering cycle. The in-repo dependency declaration is authorized by
`the package-dependency rule`, which permits a kit to declare a dependency
on another in-repo kit when a recorded decision requires it. The telemetry it enables here is
the single `substrate.kernel.backend_selected` metric described in § 8.1.

## Changelog

### 1.2.0 -- 2026-07-16
Added § 5.8 FloatVecOps behavioral spec (`l2Norm`, `l2Normalize`, `dot`,
`cosine`) and its bit-identity contract. Added `FloatVecOps` to the § 2
scope list. Corrected § 5.1 protocol method list: removed non-existent
`simhashSign` and `xor256`; added the full shipped surface including
`floatSimHashProject` (no longer "planned" — already shipped). Fixed
wrong dispatch function name `PortableKernel.dispatch(_:)` → correct
names in § 1, § 2, and K-2. Fixed duplicate § 5.4 section number: old
BitField § 5.4 → § 5.5, SHA256 § 5.5 → § 5.6, HammingNN § 5.6 → § 5.7.
Fixed § 5.5 BitField signature descriptions (wrong arg labels for
`extractField`, `maskedEquals`). Fixed § 5.6 SHA256 function name:
`SHA256.hash256(_:)` → `SHA256.hash(_:)`. Fixed § 5.7 HammingNN function
name: `HammingNN.search(query:candidates:topK:)` → `HammingNN.topK(anchor:candidates:k:blocks:)`;
corrected tie-break: rowID.uuidString ascending (not candidate index).
Fixed § 5.3 heading: removed "BNNS" (removed backend).

### 1.1.0 -- 2026-06-23
Added § 5.4: the float-input SimHash projection (`SubstrateML.FloatSimHash.project`) is promoted from a scalar-only standalone function into this backend-selected dispatch surface — `ScalarKernel` oracle, `SimdKernel` production backend via the over-hyperplanes pattern (bit-identical cross-port and cross-backend), crossover ~bs 4, Metal declined per the measured SimHash selection. Listed as a planned dispatch op in § 5.1. `l2Normalize` parallelized across vectors as the secondary feeder op.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
