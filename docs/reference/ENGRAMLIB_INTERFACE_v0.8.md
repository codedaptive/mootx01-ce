---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: EngramLib
languages: [swift, rust]
relates_to:
  - ENGRAMLIB_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of EngramLib in both ports: the Engram type, the
  similarity / nearest-neighbour / threshold / union operations, the
  Match result type, and the Session reuse handle. The companion SPEC
  carries the behavioral contracts (invariants I-1…I-4, conformance
  C-1…C-4).
---

# EngramLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/EngramLib/`

- `Sources/EngramLib/EngramLib.swift` — the `EngramLib` namespace,
  `Engram` typealias + initializer, `Session`
- `Sources/EngramLib/Match.swift` — the `Match` result type
- `Tests/EngramLibTests/`, `Package.swift`

**Rust:** `packages/libs/EngramLib/rust/`

- `src/lib.rs` — crate `engram-lib`: `Engram` type alias, `EngramLib`,
  `Session`, `Match`
- depends on `substrate-lib`

## § 2 — Public types

### `Engram`

The encoded-memory unit; a stable alias over the substrate fingerprint
(SPEC § 4, I-1).

**Swift:**

```swift
public typealias Engram = SubstrateLib.Fingerprint256

extension Engram {
    /// Construct an engram from four 64-bit blocks (treated opaquely).
    public init(blocks b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64)
}
```

**Rust:**

```rust
pub type Engram = Fingerprint256;
```

### `Match`

A single similarity result (SPEC § 5, B-6).

**Swift:**

```swift
public struct Match: Hashable, Sendable, Codable, Comparable {
    public let index: Int      // position in the candidates array
    public let distance: Int   // Hamming distance from the probe
    public init(index: Int, distance: Int)
    // Comparable: by distance asc, then index asc
}
```

**Rust:**

```rust
pub struct Match { pub index: usize, pub distance: u32 }
```

### `EngramLib.Session`

A reusable handle holding a kernel for hot loops; result-equivalent to
the static API (SPEC § 4, I-3).

**Swift:**

```swift
extension EngramLib {
    public struct Session: Sendable {
        public init()
        public func distance(_ a: Engram, _ b: Engram) -> Int
        public func distances(probe: Engram, candidates: [Engram]) -> [Int]
        public func findNearest(probe: Engram, in candidates: [Engram], k: Int) -> [Match]
        public func findWithin(probe: Engram, in candidates: [Engram], maxDistance: Int) -> [Match]
        public func union(_ engrams: [Engram]) -> Engram
    }
}
```

**Rust:**

```rust
pub struct Session { /* holds a kernel */ }
impl Session {
    pub fn new() -> Self;
    pub fn distance(&self, a: &Engram, b: &Engram) -> u32;
    pub fn distances(&self, probe: &Engram, candidates: &[Engram]) -> Vec<u32>;
    pub fn find_nearest(&self, probe: &Engram, candidates: &[Engram], k: usize) -> Vec<Match>;
    pub fn find_within(&self, probe: &Engram, candidates: &[Engram], max_distance: u32) -> Vec<Match>;
    pub fn union(&self, engrams: &[Engram]) -> Engram;
}
```

## § 3 — Public functions

All on the `EngramLib` namespace (Swift) / `EngramLib` unit struct
(Rust). Behavioral contracts: SPEC § 5.

**Swift:**

```swift
public enum EngramLib {
    // Distance
    public static func distance(_ a: Engram, _ b: Engram) -> Int                     // 0…256
    public static func distances(probe: Engram, candidates: [Engram]) -> [Int]       // same indexing as input

    // Nearest neighbour
    public static func findNearest(probe: Engram, in candidates: [Engram], k: Int) -> [Match]
    public static func findNearest(probe: Engram, in candidates: [Engram]) -> Match? // k = 1 convenience

    // Threshold filter
    public static func findWithin(probe: Engram, in candidates: [Engram], maxDistance: Int) -> [Match]

    // Aggregation
    public static func union(_ engrams: [Engram]) -> Engram      // OR-reduce; [] -> zero
    public static func union(_ a: Engram, _ b: Engram) -> Engram // pairwise OR

    // Session factory
    public static func session() -> Session
}
```

**Rust:**

```rust
pub struct EngramLib;
impl EngramLib {
    pub fn distance(a: &Engram, b: &Engram) -> u32;
    pub fn distances(probe: &Engram, candidates: &[Engram]) -> Vec<u32>;
    pub fn find_nearest(probe: &Engram, candidates: &[Engram], k: usize) -> Vec<Match>;
    pub fn find_nearest_one(probe: &Engram, candidates: &[Engram]) -> Option<Match>;
    pub fn find_within(probe: &Engram, candidates: &[Engram], max_distance: u32) -> Vec<Match>;
    pub fn union(engrams: &[Engram]) -> Engram;
    pub fn union_pair(a: &Engram, b: &Engram) -> Engram;
    pub fn session() -> Session;
}
```

## § 4 — Errors

Not applicable — no failable operations (SPEC § 6). There is no error
enum in either port; edge inputs return empty/`nil`/zero results.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/libs/EngramLib
```

(Target: `EngramLibTests`.)

**Rust:**

```
cargo test -p engram-lib
```

## § 6 — Examples

```swift
import EngramLib

let probe = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
let estate: [Engram] = loadFromStore()

let top10 = EngramLib.findNearest(probe: probe, in: estate, k: 10)   // sorted, ties by index
let near  = EngramLib.findWithin(probe: probe, in: estate, maxDistance: 32)
let cohort = EngramLib.union(estate)                                 // structural union

// Hot loop: reuse one kernel.
let s = EngramLib.session()
for q in queries { _ = s.findNearest(probe: q, in: estate, k: 5) }
```

---

*End of EngramLib Interface v0.8.*
