---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateKernel
languages: [swift, rust]
relates_to:
  - SUBSTRATEKERNEL_SPEC_v0.8.md  (the contract this interface implements)
  - SUBSTRATETYPES_INTERFACE_v0.8.md  (Layer 1 types this package consumes)
purpose: |
  Public API surface of SubstrateKernel in both ports. Eight Swift
  files publish the `SubstrateKernel` protocol, four concrete kernel
  backends, the `PortableKernel` dispatch namespace, and three
  primitives (`BitField`, `SHA256`, `HammingNN`). The Rust mirror
  exposes the same shapes with Rust-idiomatic names; today only the
  scalar kernel and portable SIMD ship in Rust (NEON / BNNS / Metal
  are Swift-specific).
---

# SubstrateKernel Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateKernel/`

- `Sources/SubstrateKernel/` — 8 files:
  - `PortableKernel.swift` — protocol + `ScalarKernel` + dispatch
  - `PortableKernel-SIMD.swift` — portable SIMD backend
  - `PortableKernel-NEON.swift` — ARM NEON backend
  - `PortableKernel-BNNS.swift` — Apple BNNS framework backend
  - `PortableKernel-Metal.swift` — Metal GPU backend
  - `BitField.swift` — parametric bit-field primitive
  - `SHA256.swift` — SHA-256 primitive
  - `HammingNN.swift` — Hamming nearest-neighbor primitive
- `Tests/SubstrateKernelTests/` — unit + conformance.
- `Package.swift` — depends on `SubstrateTypes`.

**Rust:** `packages/libs/SubstrateKernel/rust/`

- `src/lib.rs` — crate root.
- `src/kernel.rs` — `SubstrateKernel` trait + `ScalarKernel`.
- `src/kernel_simd.rs` — portable SIMD backend (feature
  `simd-nightly`).
- `src/bit_field.rs`, `src/sha256.rs`, `src/hamming_nn.rs`.
- `tests/` — conformance.
- `Cargo.toml` — depends on `substrate-types`.

Naming differs by port convention (Swift `PortableKernel.dispatch()` /
Rust `select_kernel()`; Swift `ScalarKernel()` / Rust `ScalarKernel`);
the *results* are bit-for-bit identical (SPEC § 7, I-7).

## § 2 — Public types

### `SubstrateKernel` protocol

The dispatch surface. SPEC § 5.1.

**Swift:**

```swift
public protocol SubstrateKernel: Sendable {
    var kind: KernelKind { get }
    func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int
    func simhashSign(input: SimHashInput, family: HyperplaneFamily) -> Fingerprint256
    func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256
    func xor256(_ a: Fingerprint256, _ b: Fingerprint256) -> Fingerprint256
}

public enum KernelKind: String, Sendable {
    case scalar, simd, neon, bnns, metal
}
```

**Rust:**

```rust
pub trait SubstrateKernel: Send + Sync {
    fn kind(&self) -> KernelKind;
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;
    fn simhash_sign(&self, input: &SimHashInput, family: &HyperplaneFamily) -> Fingerprint256;
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
    fn xor_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> Fingerprint256;
}

pub enum KernelKind { Scalar, Simd, Neon, Bnns, Metal }
```

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

### `SimdKernel`, `NeonKernel`, `BnnsKernel`, `MetalKernel`

Hardware-optimized backends. SPEC § 5.3.

**Swift:**

```swift
public struct SimdKernel: SubstrateKernel { public init(); /* impl */ }
public struct NeonKernel: SubstrateKernel { public init(); /* impl */ }
public struct BnnsKernel: SubstrateKernel { public init(); /* impl */ }
public struct MetalKernel: SubstrateKernel { public init?(); /* impl, init? since GPU may be unavailable */ }
```

**Rust:** `SimdKernel` only (feature `simd-nightly`); NEON / BNNS /
Metal Swift-specific by design.

### `PortableKernel`

Selection / dispatch entry. SPEC § 5.3.

**Swift:**

```swift
public enum PortableKernel {
    /// Pick the fastest available kernel for the current device.
    public static func dispatch() -> any SubstrateKernel
    /// Force selection of a specific kernel (testing).
    public static func dispatch(force: KernelKind) -> any SubstrateKernel
    /// List backends available on the current device.
    public static var available: [KernelKind] { get }
}
```

**Rust:**

```rust
pub fn select_kernel() -> Box<dyn SubstrateKernel>;
pub fn select_kernel_kind(kind: KernelKind) -> Option<Box<dyn SubstrateKernel>>;
pub fn available_kernels() -> Vec<KernelKind>;
```

### `BitField`

Parametric bit-field write/read. SPEC § 5.4.

**Swift:**

```swift
public enum BitField {
    public static func writeField(
        into bitmap: Int64,
        value: Int64,
        shift: Int,
        width: Int
    ) -> Int64
    public static func extractField(
        _ bitmap: Int64,
        shift: Int,
        width: Int
    ) -> Int64
    public static func maskedEquals(
        _ a: Int64,
        _ b: Int64,
        shift: Int,
        width: Int
    ) -> Bool
}
```

**Rust:**

```rust
pub fn write_field(bitmap: i64, value: i64, shift: u32, width: u32) -> i64;
pub fn extract_field(bitmap: i64, shift: u32, width: u32) -> i64;
pub fn masked_equals(a: i64, b: i64, shift: u32, width: u32) -> bool;
```

### `SHA256`

SHA-256 primitive. SPEC § 5.5.

**Swift:**

```swift
public enum SHA256 {
    public static func hash256(_ data: Data) -> [UInt8]          // 32 bytes
    public static func hash256(_ bytes: [UInt8]) -> [UInt8]
    public static func hash256AsFingerprint(_ data: Data) -> Fingerprint256
}
```

**Rust:**

```rust
pub fn sha256(data: &[u8]) -> [u8; 32];
pub fn sha256_as_fingerprint(data: &[u8]) -> Fingerprint256;
```

### `HammingNN`

Hamming nearest-neighbor. SPEC § 5.6.

**Swift:**

```swift
public struct HammingNNHit: Hashable, Sendable {
    public let index: Int
    public let distance: Int
}

public enum HammingNN {
    public static func search(
        query: Fingerprint256,
        candidates: [Fingerprint256],
        topK: Int
    ) -> [HammingNNHit]
}
```

**Rust:**

```rust
pub struct HammingNNHit { pub index: usize, pub distance: u32 }
pub fn hamming_nn_search(
    query: &Fingerprint256,
    candidates: &[Fingerprint256],
    top_k: usize,
) -> Vec<HammingNNHit>;
```

## § 3 — Public functions

All operations on this package are methods on the `SubstrateKernel`
protocol implementations or static functions on the primitive
namespaces (`BitField`, `SHA256`, `HammingNN`). No free top-level
functions outside those surfaces.

## § 4 — Errors

The package raises no errors on its public surface. Inputs that
would produce errors are rejected at the SubstrateTypes layer before
reaching a kernel call.

## § 5 — Conformance test entry points

- **Swift:** `Tests/SubstrateKernelTests/`
  - `KernelConformanceTests.swift` — every backend × every operation
    × shared vectors
  - `BitFieldTests.swift` — round-trip vectors, K-4 preservation
  - `SHA256Tests.swift` — RFC 6234 + substrate-specific vectors
  - `HammingNNTests.swift` — top-K vectors, tie-breaking order
- **Rust:** `tests/kernel_conformance.rs`, plus per-module
  `#[cfg(test)] mod tests` blocks.

## § 6 — Examples

```swift
import SubstrateTypes
import SubstrateKernel

// Dispatch the best available kernel for the device.
let kernel = PortableKernel.dispatch()
let a = Fingerprint256(words: (0x1, 0, 0, 0))
let b = Fingerprint256(words: (0xff, 0, 0, 0))
let d = kernel.hammingDistance256(a, b)

// Force-select the scalar reference (testing).
let scalar = PortableKernel.dispatch(force: .scalar)
let dScalar = scalar.hammingDistance256(a, b)
assert(d == dScalar, "I-7 conformance: every backend matches scalar")

// BitField operation: write the state field (bits 0-5) of a
// drawer's adjective bitmap.
let priorAdj: Int64 = 0x0000_0000_0000_0040  // bit 6 set
let nextAdj = BitField.writeField(into: priorAdj, value: 33, shift: 0, width: 6)
let stateField = BitField.extractField(nextAdj, shift: 0, width: 6)
assert(stateField == 33)

// SHA-256 over an audit-event payload.
let payload = Data("capture|<rowId>|<hlc>".utf8)
let id = SHA256.hash256AsFingerprint(payload)

// Hamming nearest neighbor over a candidate set.
let query = Fingerprint256(words: (0, 0, 0, 0))
let candidates = [a, b, query]
let hits = HammingNN.search(query: query, candidates: candidates, topK: 2)
// hits[0].index == 2 (the query itself), hits[0].distance == 0
```

```rust
use substrate_types::Fingerprint256;
use substrate_kernel::{select_kernel, bit_field, sha256, hamming_nn};

let kernel = select_kernel();
let a = Fingerprint256::from_words((0x1, 0, 0, 0));
let b = Fingerprint256::from_words((0xff, 0, 0, 0));
let d = kernel.hamming_distance_256(&a, &b);

let prior_adj: i64 = 0x0000_0000_0000_0040;
let next_adj = bit_field::write_field(prior_adj, 33, 0, 6);
let state_field = bit_field::extract_field(next_adj, 0, 6);
assert_eq!(state_field, 33);

let id = sha256::sha256_as_fingerprint(b"capture|<rowId>|<hlc>");
```

## Swift/Rust Concordance

Read-anchored map of the package's TOP-LEVEL public surface in both
ports. Every Swift symbol and Rust symbol below was confirmed in
source at the cited `file:line`. One row per public concept.

Naming idiom across the table: Swift `CamelCase` methods / Rust
`snake_case`; Swift namespaced `enum`/`struct` of static functions
vs Rust free functions in a `mod` (e.g. Swift `BitField.extractField`
/ Rust `bit_field::extract_field`). These are sanctioned port-idiom
differences, not drift.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Kernel dispatch contract | `SubstrateKernel` protocol — `PortableKernel.swift:49` | `SubstrateKernel` trait — `rust/src/kernel.rs:14` | public / `pub` | Swift `protocol: Sendable` / Rust `trait: Send + Sync`; Swift `Int` returns, Rust `u32`; Swift `simhashCompute(subhashes:families:) -> Fingerprint256` (4-block) / Rust `simhash_block(input,family) -> u64` (single block, caller composes 4) — sanctioned idiom split | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference bit-for-bit" — `PortableKernelTests.swift:270` / Rust per-module `#[cfg(test)] mod tests` in `kernel.rs` | Confirmed |
| Kernel kind tag | `KernelKind` enum — `PortableKernel.swift:231` | `KernelKind` enum — `rust/src/kernel.rs:182` | public / `pub` | Swift `String`-raw cases `scalar/simd/neon/bnns/metal/avx512/avx2`; Rust cases `Scalar/Simd/Neon/Avx512/Avx2` (no `Bnns`/`Metal` — those are Apple-only backends with no Rust kernel). Case-name idiom lowercase vs CamelCase. Rust adds `parse`/`as_str` string round-trip; Swift uses raw value | `PortableKernelDispatcherTests` "of_kind(.scalar)…" / "for_current_platform picks SIMD on arm64" — `PortableKernelTests.swift:108,125` | Confirmed |
| Scalar reference kernel | `ScalarKernel` struct — `PortableKernel.swift:166` | `ScalarKernel` struct — `rust/src/kernel.rs:108` | public / `pub` | Swift `init()` / Rust `new()` + `Default`. The canonical oracle both ports gate against | `PortableKernelConformanceTests` (scalar is the oracle) — `PortableKernelTests.swift:270`; Rust conformance `#[cfg(test)]` in `kernel.rs` | Confirmed |
| Portable SIMD kernel | `SimdKernel` struct — `PortableKernel-SIMD.swift:39` | `SimdKernel` struct — `rust/src/kernel_simd.rs:44` | public / `pub` | Swift `import simd` (always built) / Rust gated behind `simd-nightly` Cargo feature (`#![cfg(feature = "simd-nightly")]`); both compile to NEON on aarch64. Behavior byte-identical to scalar | `PortableKernelCountFoldTests` "SIMD count-fold matches scalar…" / `PortableKernelDispatcherTests` "of_kind(.simd)…" — `PortableKernelTests.swift:176,113` | Confirmed |
| Kernel selection / dispatch entry | `PortableKernel` enum (namespace) — `PortableKernel.swift:241` | `PortableKernel` struct (namespace) — `rust/src/kernel.rs:224` | public / `pub` | Swift `enum` of `static func`s: `kernelForCurrentPlatform()`, `kernel(of:)`; Rust `struct` with assoc fns `for_current_platform() -> Box<dyn …>`, `of_kind(KernelKind) -> Box<dyn …>`. Swift returns `SubstrateKernel` existential / Rust `Box<dyn SubstrateKernel>` — sanctioned port idiom | `PortableKernelDispatcherTests` "for_current_platform picks SIMD on arm64, scalar elsewhere" — `PortableKernelTests.swift:125` | Confirmed |
| Parametric bit-field primitive | `BitField` enum (namespace) — `BitField.swift:45` | `bit_field` module — `rust/src/bit_field.rs` (free fns: `extract_field:54`, `write_field:77`, `masked_equals:120`, `extract_flag:131`, `write_flag:142`, `popcount:158`, `hamming_distance:165`, `xor_fold:175`) | public / `pub` | Swift namespaced `static func` (`extractField`/`writeField`/`maskedEquals`/`extractFlag`/`writeFlag`/`popcount`/`hammingDistance`/`xorFold`) vs Rust free fns in a `mod`; Swift `Int`/`Int64` & labeled args, Rust `i64`/`u32` & positional — sanctioned idiom. `writeField(_ value:into:…)` arg-order matches Rust `write_field(value, into_bitmap, …)`. Note: audit keys on the type concept `BitField`; the Rust counterpart is a module of free fns, not a `pub` type, so the concept is anchored on the Swift `BitField` enum | `BitFieldTests` round-trip/extract/write vectors — `BitFieldTests.swift:22` (15 `@Test`s) / Rust `#[cfg(test)] mod tests` in `bit_field.rs:183` (cookbook §2.3 layout round-trip) | Confirmed |
| SHA-256 primitive | `SHA256` enum (namespace) — `SHA256.swift:26` | `sha256` module — `rust/src/sha256.rs` (free fn `hash:17`) | public / `pub` | Swift `SHA256.hash(_ bytes:[UInt8]) -> [UInt8]` (32) / Rust `sha256::hash(&[u8]) -> [u8; 32]`. FIPS 180-4, dependency-free, byte-identical. Swift namespaced enum vs Rust module of free fns — sanctioned idiom; concept anchored on Swift `SHA256` enum | `SHA256Tests` NIST vectors (empty / "abc" / 56-byte / 1M 'a' / 32-byte length) — `SHA256Tests.swift:17` / Rust NIST `#[cfg(test)] mod tests` in `sha256.rs:104` | Confirmed |
| HKDF-SHA256 key derivation | `GrantHKDF` enum (namespace) — `HKDF.swift:37` | `hkdf` module — `rust/src/hkdf.rs` (free fn `derive_key:34`) | public / `pub` | Swift `GrantHKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:) -> [UInt8]` / Rust `hkdf::derive_key(ikm,salt,info,output_byte_count) -> Vec<u8>`. RFC 5869 over the in-repo SHA-256, byte-identical Apple Silicon ↔ Linux (PAR-4-GL1 grant scope-key gate). Swift namespaced enum vs Rust module — sanctioned idiom; concept anchored on Swift `GrantHKDF` enum | Cross-port grant-domain vector: Rust `hkdf.rs::grant_hkdf_scope_key_vector` (`rust/src/hkdf.rs:207`, asserts `fd2331…`) ↔ Swift `HKDFTests` `grantDomainScopeKeyVector` — `HKDFTests.swift:16`; both gated on RFC 5869 A.1/A.3 vectors | Confirmed |
| Hamming-NN top-K search | `HammingNN` enum (namespace) — `HammingNN.swift:51` | `hamming_nn` module — `rust/src/hamming_nn.rs` (free fn `top_k:67`) | public / `pub` | Swift `HammingNN.topK(anchor:candidates:k:blocks:) -> [HammingNNHit]` / Rust `hamming_nn::top_k(anchor,candidates,k,blocks) -> Vec<HammingNNHit>`. Swift `blocks: BlockMask` / Rust `blocks: u8` bitmask — same block semantics, type idiom. Concept anchored on Swift `HammingNN` enum | `HammingNNTests` "top-1 finds the exact self-match" / "top-K sorted ascending" — `HammingNNTests.swift:20`; `HammingNNTopKTieBreakTests:14` / Rust `top_one_finds_self`, `top_k_returns_sorted_ascending` in `hamming_nn.rs:132` | Confirmed |
| Hamming-NN hit record | `HammingNNHit` struct — `HammingNN.swift:32` | `HammingNNHit` struct — `rust/src/hamming_nn.rs:37` | public / `pub` | Swift `rowID: UUID` + `distance: Int` (`Hashable, Sendable`) / Rust `row_id: u128` + `distance: u32` (`Ord`/`PartialOrd` for heap+sort). UUID ↔ u128 and Int ↔ u32 are sanctioned port idioms; tie-break is rowID/row_id ascending in both (UUID string order and u128 order agree on conformance IDs) | `HammingNNTopKTieBreakTests` "equal-distance hits return in rowID-ascending order" — `HammingNNTopKTieBreakTests.swift:22` / Rust `top_k_returns_sorted_ascending` — `hamming_nn.rs:153` | Confirmed |
| NEON kernel backend | `NeonKernel` struct — `PortableKernel-NEON.swift:39` | none — `import simd` Apple-Silicon NEON lane (no `pub` Rust kernel; Rust covers aarch64 via `SimdKernel` under `simd-nightly`) | public / — | Rust: none — Apple-Silicon `import simd` platform binding; the Rust port's aarch64 NEON path is `SimdKernel`, not a distinct `NeonKernel`. No separate cross-port contract type | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference" — `PortableKernelTests.swift:270` (Swift-only host) | Exempt |
| BNNS kernel backend | `BnnsKernel` struct — `PortableKernel-BNNS.swift:176` | none — Apple `Accelerate`/BNNS framework (`#if canImport(Accelerate)`) | public / — | Rust: none — Apple platform binding (Accelerate/BNNS is an Apple-only system framework; the Rust port uses scalar + portable SIMD) | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference" — `PortableKernelTests.swift:270` (Swift-only host) | Exempt |
| Metal GPU kernel backend | `MetalKernel` struct — `PortableKernel-Metal.swift:109` | none — Apple `Metal` framework (`#if canImport(Metal)`, `init?` since GPU may be unavailable) | public / — | Rust: none — Apple platform binding (Metal is an Apple-only GPU system framework; the Rust port uses scalar + portable SIMD). Already on the audit ignore-list | `PortableKernelConformanceTests` "every host-reachable backend matches the scalar reference" — `PortableKernelTests.swift:270` (Swift-only host) | Exempt |

### Concordance notes

- **Doc-vs-code corrections folded in.** Earlier prose sections of this
  interface cited symbols that do not exist in source (e.g.
  `xor256`/`xor_256` and `simhashSign`/`simhash_sign` on the protocol;
  `SHA256.hash256` / `hash256AsFingerprint`; `BitField.writeField(into:value:…)`
  arg order; `select_kernel()` free fns). The concordance above is anchored
  on the SHIPPED symbols read at the cited `file:line`. The legacy §2 code
  blocks are illustrative and known-stale; the concordance table is the
  read-anchored source of truth for the public surface.
- **Apple-platform exemptions.** `MetalKernel` (already on the audit
  ignore-list), `BnnsKernel` (Accelerate/BNNS), and `NeonKernel` (`import
  simd` Apple-Silicon lane) are Apple platform bindings with no distinct
  Rust kernel type — the Rust port covers aarch64 through `SimdKernel`
  under the `simd-nightly` feature plus the scalar fallback. They carry
  Exempt rows here. `BnnsKernel` and `NeonKernel` are proposed for the
  shared ignore-list (orchestrator applies); their Exempt rows already
  satisfy the audit by name presence.

