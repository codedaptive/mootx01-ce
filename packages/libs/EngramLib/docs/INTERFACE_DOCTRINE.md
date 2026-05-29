# EngramLib Interface Doctrine

For coding agents using EngramLib in product code or downstream kits.

## 1. Always go through the public API

Call `EngramLib.distance`, `EngramLib.findNearest`, `EngramLib.findWithin`, `EngramLib.union`, or `EngramLib.session()`. Never import SubstrateLib directly from product code just to call a kernel method. The dispatcher and kernel selection are internal; consumers do not see them.

```swift
// CORRECT
let matches = EngramLib.findNearest(probe: query, in: estate, k: 10)

// WRONG
import SubstrateLib
let raw = PortableKernel.kernelForCurrentPlatform().hammingTopK(...)
```

If you find yourself reaching for SubstrateLib directly from a non-substrate kit, file a decision record proposing a new EngramLib surface for that need.

## 2. Treat Engram as opaque

The `Engram` typealias maps to `SubstrateLib.Fingerprint256` today. Future substrate versions may use a different representation (wider fingerprint, different block layout). Product code that constructs engrams via `Engram(blocks: b0, b1, b2, b3)` and treats them as opaque survives the change; code that reaches into `.block0`, `.block1` directly does not.

```swift
// CORRECT
let e = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
let d = EngramLib.distance(e1, e2)

// FRAGILE: depends on the underlying representation
let e: Engram = something
let firstBlock = e.block0
```

If you genuinely need the block layout (federation handshakes, on-wire encoding), do that work inside a substrate-aware kit, not in product code.

## 3. Use Session for hot loops

The stateless static methods (`EngramLib.distance`, `EngramLib.findNearest`, etc.) construct a kernel per call. For hundreds or thousands of operations in a hot path, prefer `EngramLib.session()`: the session holds one kernel for reuse.

```swift
let session = EngramLib.session()
for q in queries {
    let matches = session.findNearest(probe: q, in: estate, k: 10)
    process(matches)
}
```

`EngramLib.Session` is `Sendable` and safe to share across tasks.

## 4. Match ordering is stable

`findNearest` and `findWithin` return matches ordered by distance ascending, with ties broken by candidate index ascending. This ordering is deterministic across kernel implementations (NEON, BNNS, Metal, SIMD, scalar). Tests can assume it; product code can rely on it for UI rendering.

## 5. Distance semantics are Hamming

All distance methods return Hamming distance, 0...256. Zero means identical engrams; 256 means bit-inverse. Cosine, Euclidean, Jaccard, and Hyperplane-family-aware distances live in VectorKit (mission 6) and federation-aware code (SubstrateLib + ConvergenceKit-Federation). EngramLib's stable contract is Hamming.

## 6. Union semantics are bitwise OR

`EngramLib.union(_ engrams:)` returns the bitwise OR of all inputs. The result has a 1-bit at every position where at least one input had a 1-bit. Empty input returns the zero engram. This is the substrate's standard cohort/union operator (paper section 5.3); the same operation backs federation OR-reductions.

## 7. Empty inputs return empty outputs

`findNearest(probe:in:[], k:)` returns `[]`. `findWithin(probe:in:[], maxDistance:)` returns `[]`. `distances(probe:candidates: [])` returns `[]`. `union([])` returns `Engram.zero`. No `nil`, no throw, no error. Product code can call these with empty collections safely.

## 8. When you need something EngramLib does not expose

File a decision record. Examples of valid additions:

- A different distance metric (cosine over engrams, hyperplane-family-aware)
- Approximate nearest neighbor (LSH index, HNSW over engrams)
- Streaming top-K over a sequence rather than an array
- Bit-pattern queries (find engrams with all bits in a mask set)

Examples of invalid additions:

- Exposing kernel selection (`EngramLib.useMetalKernel`): defeats the dispatcher
- Returning raw substrate types (`EngramLib.rawKernel()`): leaks abstraction
- Mutating-shape methods (engrams are values; product code never mutates them)
