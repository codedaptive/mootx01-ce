# EngramLib

EngramLib is the product-facing API for 256-bit engram similarity and retrieval over the GeniusLocus substrate. Fourth kit in the eleven-kit family per `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`.

EngramLib wraps SubstrateLib's kernel layer behind a stable, minimal surface. Consumers do not see kernel selection, dispatcher logic, or substrate internals.

## Status (2026-05-19)

Mission 4 complete. EngramLib refactored to depend on the published SubstrateLib package instead of the upstream-staging `GeniusLocusReference` path package.

| Surface | Status |
|---|---|
| EngramLib static API (distance, distances, findNearest, findWithin, union) | Complete |
| EngramLib.Session for hot loops | Complete |
| Match result type with Comparable + Codable conformance | Complete |
| 20 tests | Passing |

## The model

The substrate represents structural similarity as a 256-bit fingerprint with four 64-bit blocks (bitmap-LSH, lattice-LSH, lineage+temporal, channel+source, per paper section 5). EngramLib calls this an `Engram` and treats it as an opaque value.

```swift
let probe = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
let estate: [Engram] = loadFromStore()

// Top-K nearest
let matches = EngramLib.findNearest(probe: probe, in: estate, k: 10)

// All within distance
let close = EngramLib.findWithin(probe: probe, in: estate, maxDistance: 32)

// Aggregation
let cohort = EngramLib.union(estate)
```

For hot loops that benefit from kernel reuse:

```swift
let session = EngramLib.session()
for query in queries {
    let matches = session.findNearest(probe: query, in: estate, k: 10)
    // ...
}
```

## Dependency

```
EngramLib → SubstrateLib (Fingerprint256, PortableKernel, SubstrateKernel protocol)
```

Substrate kernels (NEON, BNNS, Metal, SIMD, scalar reference) are selected automatically per hardware. EngramLib does not expose this choice.

## Building and testing

```
cd EngramLib
swift build
swift test
```

Requires Swift 6.0+ and SubstrateLib at `../SubstrateLib`.

## Public API stability

The `Engram` typealias is the stable public name. The current substrate uses `Fingerprint256` underneath; if a future substrate uses `Fingerprint512` or another representation, the typealias absorbs the change so product code does not need to update.

Adding methods to `EngramLib` enum or `EngramLib.Session` is additive. Removing or changing method signatures is a breaking change requiring a major version bump.

## See also

- `SKILL.md`: operator skill record
- `AGENT_HOWTO.md`: agent-facing usage notes
- `docs/INTERFACE_DOCTRINE.md`: contract for downstream consumers
- `../SubstrateLib/`: the substrate primitives EngramLib consumes
