---
title: SubstrateKernel Interface
version: 1.1.0
status: active
date: 2026-06-20
description: Public API surface for SubstrateKernel in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/SUBSTRATEKERNEL_SPEC.md
  - docs/reference/SUBSTRATETYPES_INTERFACE.md
---

# SubstrateKernel Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateKernel/`

- `Sources/SubstrateKernel/` — 9 files:
  - `PortableKernel.swift` — `SubstrateKernel` protocol + `ScalarKernel`
    + `KernelKind` + `PortableKernel` dispatch namespace
  - `PortableKernel-SIMD.swift` — portable SIMD backend (`SimdKernel`)
  - `PortableKernel-NEON.swift` — ARM NEON backend (`NeonKernel`)
  - `PortableKernel-Metal.swift` — Metal GPU backend (`MetalKernel`)
  - `BitField.swift` — parametric bit-field primitive
  - `SHA256.swift` — SHA-256 primitive
  - `HKDF.swift` — RFC 5869 HKDF-SHA256 (`GrantHKDF`)
  - `HammingNN.swift` — Hamming nearest-neighbor primitive
- `Tests/SubstrateKernelTests/` — unit + conformance.
- `Package.swift` — depends on `SubstrateTypes`.

**Rust:** `packages/libs/SubstrateKernel/rust/`

- `src/lib.rs` — crate root.
- `src/kernel.rs` — `SubstrateKernel` trait + `ScalarKernel` +
  `KernelKind` + `PortableKernel` dispatch.
- `src/kernel_simd.rs` — portable SIMD backend (`SimdKernel`, feature
  `simd-nightly`).
- `src/bit_field.rs`, `src/sha256.rs`, `src/hkdf.rs`, `src/hamming_nn.rs`.
- `tests/` — conformance.
- `Cargo.toml` — depends on `substrate-types`.

Naming differs by port convention (Swift `PortableKernel.kernelForCurrentPlatform()`
/ Rust `PortableKernel::for_current_platform()`; Swift `ScalarKernel()` /
Rust `ScalarKernel::new()`); the *results* are bit-for-bit identical
(SPEC § 7, I-7). NEON / Metal are Apple-platform-only backends with no
Rust counterpart; the Rust port covers aarch64 through `SimdKernel`.

## § 2 — Public types

### `SubstrateKernel` protocol

The dispatch surface. SPEC § 5.1.

**Swift:**

```swift
public protocol SubstrateKernel: Sendable {
    var kind: KernelKind { get }
    func popcount64(_ x: UInt64) -> Int
    func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int
    func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256
    func hammingTopK(probe: Fingerprint256, candidates: [Fingerprint256],
                     k: Int) -> [(index: Int, distance: Int)]
    func simhashCompute(subhashes: [UInt64],
                        families: [HyperplaneFamily]) -> Fingerprint256
    // Batched variants (default impls loop over the pair-at-a-time ops):
    func hammingDistanceBatch(probe: Fingerprint256,
                              candidates: [Fingerprint256]) -> [Int]
    func simhashBlockBatch(inputs: [[UInt64]], family: HyperplaneFamily) -> [UInt64]
    func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256]
    func countFold256(_ fingerprints: [Fingerprint256]) -> CountVector256
    func countFoldBatch(batches: [[Fingerprint256]]) -> [CountVector256]
}

public enum KernelKind: String, Sendable {
    case scalar, simd, neon, metal, avx512, avx2
}
```

**Rust:**

```rust
pub trait SubstrateKernel: Send + Sync {
    fn kind(&self) -> KernelKind { KernelKind::Scalar }   // default
    fn popcount64(&self, x: u64) -> u32;
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
    fn hamming_top_k(&self, probe: &Fingerprint256, candidates: &[Fingerprint256],
                     k: usize) -> Vec<(usize, u32)>;
    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64;
    // batched variants with default impls:
    fn hamming_distance_batch(&self, probe: &Fingerprint256, candidates: &[Fingerprint256]) -> Vec<u32>;
    fn simhash_block_batch(&self, inputs: &[Vec<u64>], family: &HyperplaneFamily) -> Vec<u64>;
    fn or_reduce_batch(&self, batches: &[Vec<Fingerprint256>]) -> Vec<Fingerprint256>;
    fn count_fold_256(&self, fingerprints: &[Fingerprint256]) -> CountVector256;
    fn count_fold_batch(&self, batches: &[Vec<Fingerprint256>]) -> Vec<CountVector256>;
}

pub enum KernelKind { Scalar, Simd, Neon, Avx512, Avx2 }   // no Bnns/Metal (Apple-only)
```

Note the SimHash port idiom: Swift's `simhashCompute(subhashes:families:)`
takes all four block subhashes and returns the composed 256-bit
fingerprint; the Rust `simhash_block(input, family)` signs a single
block (`u64`) and the caller composes the four blocks. Results are
bit-identical.

### `ScalarKernel`

The canonical reference. SPEC § 5.2.

**Swift:**

```swift
public struct ScalarKernel: SubstrateKernel {
    public init()
    public var kind: KernelKind { .scalar }
    // protocol methods implemented in pure Swift, no intrinsics
}
```

**Rust:**

```rust
pub struct ScalarKernel;
impl ScalarKernel { pub fn new() -> Self { Self } }
impl SubstrateKernel for ScalarKernel { /* pure Rust */ }
```

### `SimdKernel`, `NeonKernel`, `MetalKernel`

Hardware-optimized backends. SPEC § 5.3.

**Swift:**

```swift
public struct SimdKernel: SubstrateKernel { public init(); /* impl */ }
public struct NeonKernel: SubstrateKernel { public init(); /* impl */ }
public struct MetalKernel: SubstrateKernel { public init?(); /* impl, init? since GPU may be unavailable */ }
```

**Rust:** `SimdKernel` only (feature `simd-nightly`); NEON / Metal
are Swift-specific Apple-platform backends by design.

### `PortableKernel`

Selection / dispatch entry. SPEC § 5.3.

**Swift:**

```swift
public enum PortableKernel {
    /// Pick the fastest available kernel for the current device.
    /// Emits `substrate.kernel.backend_selected` via IntellectusLib
    /// when monitoring is enabled; no-op when disabled. (SPEC § 8)
    public static func kernelForCurrentPlatform() -> SubstrateKernel
    /// Select a specific kernel kind (testing / forced selection).
    /// Does NOT emit telemetry — conformance harness selector only.
    public static func kernel(of kind: KernelKind) -> SubstrateKernel
    /// Conformance assertion helper: two kernels agree bit-for-bit.
    public static func assertEqual(_ lhs: SubstrateKernel, _ rhs: SubstrateKernel, /* … */)
    /// Compile-time architecture tag for telemetry.
    /// "arm64" / "x86_64" / "other". (SPEC § 8.1)
    static let currentArchTag: String
}
```

**Rust** (`PortableKernel` is a namespace struct, not free functions):

```rust
impl PortableKernel {
    /// Emits `substrate.kernel.backend_selected` via the report! macro
    /// when monitoring is enabled; single atomic load when disabled. (SPEC § 8)
    pub fn for_current_platform() -> Box<dyn SubstrateKernel>;
    pub fn of_kind(kind: KernelKind) -> Box<dyn SubstrateKernel>;
    pub fn assert_equal(lhs: &dyn SubstrateKernel, rhs: &dyn SubstrateKernel, /* … */);
    /// Compile-time architecture tag for telemetry.
    /// "aarch64" / "x86_64" / "other". (SPEC § 8.1)
    pub fn current_arch_tag() -> &'static str;
}
```

### `BitField`

Parametric bit-field write/read. SPEC § 5.4.

**Swift:**

```swift
public enum BitField {
    public static func extractField(_ bitmap: Int64, shift: Int, width: Int) -> Int64
    public static func writeField(_ value: Int64, into bitmap: Int64,
                                  shift: Int, width: Int) -> Int64
    public static func maskedEquals(_ bitmap: Int64, mask: Int64, expected: Int64) -> Bool
    public static func extractFlag(_ bitmap: Int64, bit: Int) -> Bool
    public static func writeFlag(_ flag: Bool, into bitmap: Int64, bit: Int) -> Int64
    public static func popcount(_ value: Int64) -> Int
    public static func hammingDistance(_ a: Int64, _ b: Int64) -> Int
    public static func xorFold<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64
}
```

**Rust** (`src/bit_field.rs`, module free functions):

```rust
pub fn extract_field(bitmap: i64, shift: u32, width: u32) -> i64;
pub fn write_field(value: i64, into_bitmap: i64, shift: u32, width: u32) -> i64;
pub fn masked_equals(bitmap: i64, mask: i64, expected: i64) -> bool;
pub fn extract_flag(bitmap: i64, bit: u32) -> bool;
pub fn write_flag(flag: bool, into_bitmap: i64, bit: u32) -> i64;
pub fn popcount(value: i64) -> i32;
pub fn hamming_distance(a: i64, b: i64) -> i32;
pub fn xor_fold<I: IntoIterator<Item = i64>>(values: I) -> i64;
```

### `SHA256`

SHA-256 primitive. SPEC § 5.5.

**Swift:**

```swift
public enum SHA256 {
    public static func hash(_ bytes: [UInt8]) -> [UInt8]    // 32-byte digest
}
```

**Rust** (`src/sha256.rs`, module free function):

```rust
pub fn hash(bytes: &[u8]) -> [u8; 32];
```

### `GrantHKDF`

RFC 5869 HKDF-SHA256 key derivation over the in-repo SHA-256. SPEC
§ 5.5. Used for grant scope-key derivation.

**Swift:**

```swift
public enum GrantHKDF {
    public static func deriveKey(
        inputKeyMaterial: [UInt8],
        salt: String,
        info: [UInt8],
        outputByteCount: Int
    ) -> [UInt8]
}
```

**Rust** (`src/hkdf.rs`, module free functions):

```rust
pub fn derive_key(ikm: &[u8], salt: &str, info: &[u8], output_byte_count: usize) -> Vec<u8>;

/// RFC 2104 HMAC-SHA256 over the in-repo SHA-256. Building block for
/// KeyedCommitment (SubstrateLib ADR-017 §17).
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32];
```

`hmac` computes RFC 2104 HMAC-SHA256 using the in-repo SHA-256
primitive. It is the building block for the keyed-commitment API
in SubstrateLib (ADR-017 §17). The function was promoted from
package-internal to public to support this use.

**Swift** (additional on `GrantHKDF`):

```swift
public enum GrantHKDF {
    // ... deriveKey as above ...

    /// RFC 2104 HMAC-SHA256 over the in-repo SHA-256.
    public static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8]
}
```

### `HammingNN`

Hamming nearest-neighbor. SPEC § 5.6.

**Swift:**

```swift
public struct HammingNNHit: Hashable, Sendable {
    public let rowID: UUID
    public let distance: Int
    public init(rowID: UUID, distance: Int)
}

public enum HammingNN {
    // `candidates` iterates (rowID, fingerprint) pairs; `blocks`
    // defaults to all four for full-256-bit distance.
    public static func topK<S: Sequence>(
        anchor: Fingerprint256,
        candidates: S,
        k: Int,
        blocks: BlockMask = .all
    ) -> [HammingNNHit] where S.Element == (UUID, Fingerprint256)
}
```

**Rust** (`src/hamming_nn.rs`, module free function):

```rust
pub struct HammingNNHit { pub row_id: u128, pub distance: u32 }
pub fn top_k<I>(
    anchor: &Fingerprint256,
    candidates: I,
    k: usize,
    blocks: u8,
) -> Vec<HammingNNHit>
where I: IntoIterator<Item = (u128, Fingerprint256)>;
```

## § 3 — Public functions

All operations on this package are methods on the `SubstrateKernel`
protocol implementations or static functions on the primitive
namespaces (`BitField`, `SHA256`, `GrantHKDF`, `HammingNN`). No free
top-level functions outside those surfaces. (In the Rust port these
namespaces are modules of free functions: `bit_field::`, `sha256::`,
`hkdf::`, `hamming_nn::`.)

## § 4 — Errors

The package raises no errors on its public surface. Inputs that
would produce errors are rejected at the SubstrateTypes layer before
reaching a kernel call.

## § 5 — Conformance test entry points

- **Swift:** `Tests/SubstrateKernelTests/`
  - `PortableKernelTests.swift` — every backend × every operation
    × shared vectors (dispatcher, conformance, count-fold, top-K)
  - `BitFieldTests.swift` — round-trip vectors, K-4 preservation
  - `SHA256Tests.swift` — NIST FIPS 180-4 vectors
  - `HKDFTests.swift` — RFC 5869 vectors + grant scope-key vector
  - `HammingNNTests.swift` — top-K vectors, tie-breaking order
- **Rust:** `tests/kernel_conformance.rs`, plus per-module
  `#[cfg(test)] mod tests` blocks.

## § 6 — Examples

```swift
import SubstrateTypes
import SubstrateKernel

// Dispatch the best available kernel for the device.
let kernel = PortableKernel.kernelForCurrentPlatform()
let a = Fingerprint256(block0: 0x1, block1: 0, block2: 0, block3: 0)
let b = Fingerprint256(block0: 0xff, block1: 0, block2: 0, block3: 0)
let d = kernel.hammingDistance256(a, b)

// Force-select the scalar reference (testing).
let scalar = PortableKernel.kernel(of: .scalar)
let dScalar = scalar.hammingDistance256(a, b)
assert(d == dScalar, "I-7 conformance: every backend matches scalar")

// BitField operation: write the state field (bits 0-5) of a
// drawer's adjective bitmap.
let priorAdj: Int64 = 0x0000_0000_0000_0040  // bit 6 set
let nextAdj = BitField.writeField(33, into: priorAdj, shift: 0, width: 6)
let stateField = BitField.extractField(nextAdj, shift: 0, width: 6)
assert(stateField == 33)

// SHA-256 over an audit-event payload (32-byte digest).
let payload = Array("capture|<rowId>|<hlc>".utf8)
let id = SHA256.hash(payload)

// Hamming nearest neighbor over a (rowID, fingerprint) candidate set.
let q = Fingerprint256.zero
let candidates: [(UUID, Fingerprint256)] = [(UUID(), a), (UUID(), b), (UUID(), q)]
let hits = HammingNN.topK(anchor: q, candidates: candidates, k: 2)
// hits[0] is the exact self-match (distance == 0)
```

```rust
use substrate_types::Fingerprint256;
use substrate_kernel::{PortableKernel, bit_field, sha256};

let kernel = PortableKernel::for_current_platform();
let a = Fingerprint256::new(0x1, 0, 0, 0);
let b = Fingerprint256::new(0xff, 0, 0, 0);
let d = kernel.hamming_distance_256(&a, &b);

let prior_adj: i64 = 0x0000_0000_0000_0040;
let next_adj = bit_field::write_field(33, prior_adj, 0, 6);
let state_field = bit_field::extract_field(next_adj, 0, 6);
assert_eq!(state_field, 33);

let id = sha256::hash(b"capture|<rowId>|<hlc>");
```

## Swift/Rust Concordance

Map of the package's TOP-LEVEL public surface in both ports, with the
defining `file:line` cited for each symbol. One row per public concept.

Naming idiom across the table: Swift `CamelCase` methods / Rust
`snake_case`; Swift namespaced `enum`/`struct` of static functions
vs Rust free functions in a `mod` (e.g. Swift `BitField.extractField`
/ Rust `bit_field::extract_field`). These are intentional port-idiom
differences; the two ports remain behaviorally equivalent.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Port |
|---|---|---|---|---|---|---|
| Kernel dispatch contract | `SubstrateKernel` protocol — `PortableKernel.swift:49` | `SubstrateKernel` trait — `rust/src/kernel.rs:14` | public / `pub` | Swift `protocol: Sendable` / Rust `trait: Send + Sync`; Swift `Int` returns, Rust `u32`; Swift `simhashCompute(subhashes:families:) -> Fingerprint256` (4-block) / Rust `simhash_block(input,family) -> u64` (single block, caller composes 4) — sanctioned idiom split | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference bit-for-bit" — `PortableKernelTests.swift:270` / Rust per-module `#[cfg(test)] mod tests` in `kernel.rs` | Both ports |
| Kernel kind tag | `KernelKind` enum — `PortableKernel.swift:231` | `KernelKind` enum — `rust/src/kernel.rs:182` | public / `pub` | Swift `String`-raw cases `scalar/simd/neon/metal/avx512/avx2`; Rust cases `Scalar/Simd/Neon/Avx512/Avx2` (no `Metal` — Apple-only backend with no Rust kernel). Case-name idiom lowercase vs CamelCase. Rust adds `parse`/`as_str` string round-trip; Swift uses raw value | `PortableKernelDispatcherTests` "of_kind(.scalar)…" / "for_current_platform picks SIMD on arm64" — `PortableKernelTests.swift:108,125` | Both ports |
| Scalar reference kernel | `ScalarKernel` struct — `PortableKernel.swift:166` | `ScalarKernel` struct — `rust/src/kernel.rs:108` | public / `pub` | Swift `init()` / Rust `new()` + `Default`. The canonical oracle both ports gate against | `PortableKernelConformanceTests` (scalar is the oracle) — `PortableKernelTests.swift:270`; Rust conformance `#[cfg(test)]` in `kernel.rs` | Both ports |
| Portable SIMD kernel | `SimdKernel` struct — `PortableKernel-SIMD.swift:39` | `SimdKernel` struct — `rust/src/kernel_simd.rs:44` | public / `pub` | Swift `import simd` (always built) / Rust gated behind `simd-nightly` Cargo feature (`#![cfg(feature = "simd-nightly")]`); both compile to NEON on aarch64. Behavior byte-identical to scalar | `PortableKernelCountFoldTests` "SIMD count-fold matches scalar…" / `PortableKernelDispatcherTests` "of_kind(.simd)…" — `PortableKernelTests.swift:176,113` | Both ports |
| Kernel selection / dispatch entry | `PortableKernel` enum (namespace) — `PortableKernel.swift:241` | `PortableKernel` struct (namespace) — `rust/src/kernel.rs:224` | public / `pub` | Swift `enum` of `static func`s: `kernelForCurrentPlatform()`, `kernel(of:)`; Rust `struct` with assoc fns `for_current_platform() -> Box<dyn …>`, `of_kind(KernelKind) -> Box<dyn …>`. Swift returns `SubstrateKernel` existential / Rust `Box<dyn SubstrateKernel>` — sanctioned port idiom | `PortableKernelDispatcherTests` "for_current_platform picks SIMD on arm64, scalar elsewhere" — `PortableKernelTests.swift:125` | Both ports |
| Parametric bit-field primitive | `BitField` enum (namespace) — `BitField.swift:45` | `bit_field` module — `rust/src/bit_field.rs` (free fns: `extract_field:54`, `write_field:77`, `masked_equals:120`, `extract_flag:131`, `write_flag:142`, `popcount:158`, `hamming_distance:165`, `xor_fold:175`) | public / `pub` | Swift namespaced `static func` (`extractField`/`writeField`/`maskedEquals`/`extractFlag`/`writeFlag`/`popcount`/`hammingDistance`/`xorFold`) vs Rust free fns in a `mod`; Swift `Int`/`Int64` & labeled args, Rust `i64`/`u32` & positional — sanctioned idiom. `writeField(_ value:into:…)` arg-order matches Rust `write_field(value, into_bitmap, …)`. Note: the Rust counterpart is a module of free fns, not a `pub` type, so the concept is anchored on the Swift `BitField` enum | `BitFieldTests` round-trip/extract/write vectors — `BitFieldTests.swift:22` (15 `@Test`s) / Rust `#[cfg(test)] mod tests` in `bit_field.rs:183` (cookbook §2.3 layout round-trip) | Both ports |
| SHA-256 primitive | `SHA256` enum (namespace) — `SHA256.swift:26` | `sha256` module — `rust/src/sha256.rs` (free fn `hash:17`) | public / `pub` | Swift `SHA256.hash(_ bytes:[UInt8]) -> [UInt8]` (32) / Rust `sha256::hash(&[u8]) -> [u8; 32]`. FIPS 180-4, dependency-free, byte-identical. Swift namespaced enum vs Rust module of free fns — sanctioned idiom; concept anchored on Swift `SHA256` enum | `SHA256Tests` NIST vectors (empty / "abc" / 56-byte / 1M 'a' / 32-byte length) — `SHA256Tests.swift:17` / Rust NIST `#[cfg(test)] mod tests` in `sha256.rs:104` | Both ports |
| HKDF-SHA256 key derivation | `GrantHKDF` enum (namespace) — `HKDF.swift:37` | `hkdf` module — `rust/src/hkdf.rs` (free fn `derive_key:34`) | public / `pub` | Swift `GrantHKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:) -> [UInt8]` / Rust `hkdf::derive_key(ikm,salt,info,output_byte_count) -> Vec<u8>`. RFC 5869 over the in-repo SHA-256, byte-identical Apple Silicon ↔ Linux (grant scope-key derivation). Swift namespaced enum vs Rust module — sanctioned idiom; concept anchored on Swift `GrantHKDF` enum | Cross-port grant-domain vector: Rust `hkdf.rs::grant_hkdf_scope_key_vector` (`rust/src/hkdf.rs:207`, asserts `fd2331…`) ↔ Swift `HKDFTests` `grantDomainScopeKeyVector` — `HKDFTests.swift:16`; both gated on RFC 5869 A.1/A.3 vectors | Both ports |
| Hamming-NN top-K search | `HammingNN` enum (namespace) — `HammingNN.swift:51` | `hamming_nn` module — `rust/src/hamming_nn.rs` (free fn `top_k:67`) | public / `pub` | Swift `HammingNN.topK(anchor:candidates:k:blocks:) -> [HammingNNHit]` / Rust `hamming_nn::top_k(anchor,candidates,k,blocks) -> Vec<HammingNNHit>`. Swift `blocks: BlockMask` / Rust `blocks: u8` bitmask — same block semantics, type idiom. Concept anchored on Swift `HammingNN` enum | `HammingNNTests` "top-1 finds the exact self-match" / "top-K sorted ascending" — `HammingNNTests.swift:20`; `HammingNNTopKTieBreakTests:14` / Rust `top_one_finds_self`, `top_k_returns_sorted_ascending` in `hamming_nn.rs:132` | Both ports |
| Hamming-NN hit record | `HammingNNHit` struct — `HammingNN.swift:32` | `HammingNNHit` struct — `rust/src/hamming_nn.rs:37` | public / `pub` | Swift `rowID: UUID` + `distance: Int` (`Hashable, Sendable`) / Rust `row_id: u128` + `distance: u32` (`Ord`/`PartialOrd` for heap+sort). UUID ↔ u128 and Int ↔ u32 are sanctioned port idioms; tie-break is rowID/row_id ascending in both (UUID string order and u128 order agree on conformance IDs) | `HammingNNTopKTieBreakTests` "equal-distance hits return in rowID-ascending order" — `HammingNNTopKTieBreakTests.swift:22` / Rust `top_k_returns_sorted_ascending` — `hamming_nn.rs:153` | Both ports |
| NEON kernel backend | `NeonKernel` struct — `PortableKernel-NEON.swift:39` | none — `import simd` Apple-Silicon NEON lane (no `pub` Rust kernel; Rust covers aarch64 via `SimdKernel` under `simd-nightly`) | public / — | Rust: none — Apple-Silicon `import simd` platform binding; the Rust port's aarch64 NEON path is `SimdKernel`, not a distinct `NeonKernel`. No separate cross-port contract type | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference" — `PortableKernelTests.swift:270` (Swift-only host) | Apple-only |
| Metal GPU kernel backend | `MetalKernel` struct — `PortableKernel-Metal.swift:109` | none — Apple `Metal` framework (`#if canImport(Metal)`, `init?` since GPU may be unavailable) | public / — | Rust: none — Apple platform binding (Metal is an Apple-only GPU system framework; the Rust port uses scalar + portable SIMD) | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference" — `PortableKernelTests.swift:270` (Swift-only host) | Apple-only |

### Concordance notes

- **Apple-platform backends.** `MetalKernel` and `NeonKernel`
  (`import simd` Apple-Silicon lane) are Apple platform bindings with no
  distinct Rust kernel type — the Rust port covers aarch64 through
  `SimdKernel` under the `simd-nightly` feature plus the scalar fallback.
  They carry "Apple-only" rows in the table above. There is no
  `BnnsKernel`: measurement showed BNNS slower than `SimdKernel` on every
  op, and its BNNSGraph matmul path crashes on macOS 26.5.

## Changelog

### 1.1.0 -- 2026-06-20
Added `GrantHKDF.hmac` (RFC 2104 HMAC-SHA256) to the public API surface.
Promoted from package-internal to support the keyed-commitment API in
SubstrateLib (ADR-017 §17).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
