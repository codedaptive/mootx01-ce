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
