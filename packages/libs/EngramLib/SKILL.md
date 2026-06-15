---
name: engramkit-product
description: |
  Building product features that USE EngramLib (Swift or Rust).
  Trigger when product code needs similarity, nearest-neighbor,
  radius search, or engram aggregation. Trigger on phrases
  including "EngramLib", "Engram", "find nearest", "Hamming
  similarity in app code", "recall similar", "build a feature on
  the substrate", "EngramLib.Session", "engram_kit". Do NOT
  trigger on kernel implementation, decision records, or
  substrate engineering maintenance — that is the
  substrate-engineering skill.
when_to_use: |
  Use when building product code on top of EngramLib (Swift or
  Rust):
    - Application features needing similarity or recall
    - Service code that takes a probe and returns matches
    - Cohort or set-union features
    - Any consumer of the EngramLib API
when_not_to_use: |
  Do NOT use when:
    - Modifying kernel implementations
    - Authoring decision records
    - Running stress-test / topk-bench / validate-vectors
    - Working in docs/validation/substrate_math_performance/
    - Substrate kernel implementation or maintenance
---

# engramkit-product skill

Product integration with EngramLib. The kit is the API surface;
this skill orients product work on top of it. Two parallel
implementations: Swift (this package) and Rust (`./rust`, the
`engram-kit` crate).

## Install

**Swift:** `.package(path: "../EngramLib")` then `import EngramLib`.

**Rust:** `engram-kit = { path = "../EngramLib/rust" }` then
`use engram_kit::{Engram, EngramLib, EngramExt, Match};`.

## The API in one block

### Swift

```swift
let probe = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)

EngramLib.distance(a, b)                                       // pair
EngramLib.distances(probe: p, candidates: estate)              // batch
EngramLib.findNearest(probe: p, in: estate, k: 10)             // top-K
EngramLib.findNearest(probe: p, in: estate)                    // best
EngramLib.findWithin(probe: p, in: estate, maxDistance: 16)    // radius
EngramLib.union(engrams)                                       // OR-reduce
EngramLib.union(a, b)                                          // pair OR

let session = EngramLib.session()
// same methods on session, faster for hot loops
```

### Rust

```rust
let probe = Engram::from_blocks(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);

EngramLib::distance(&a, &b);                                   // pair
EngramLib::distances(&probe, &estate);                         // batch
EngramLib::find_nearest(&probe, &estate, 10);                  // top-K
EngramLib::find_nearest_one(&probe, &estate);                  // best
EngramLib::find_within(&probe, &estate, 16);                   // radius
EngramLib::union(&engrams);                                    // OR-reduce
EngramLib::union_pair(&a, &b);                                 // pair OR

let session = EngramLib::session();
// same methods on session, faster for hot loops
```

## Result types

- `Match { index, distance }`. Sorted by distance ascending,
  ties by index ascending.
- Swift: Hashable, Sendable, Codable, Comparable.
- Rust: Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord.
- Empty inputs return empty arrays / vectors. `k == 0` returns
  empty.

## Concurrency

All static methods are stateless and thread-safe. `Session` is
Sendable (Swift) / Send+Sync (Rust). No actors required.

## What lives outside EngramLib

Storage, capture, metadata filtering, persistence. Build those
in your product layer; pass `[Engram]` / `Vec<Engram>` into
EngramLib and map results back via index.

## Common product patterns

- Recall similar: load store → findNearest → map indices back.
- Deduplicate: findWithin with small maxDistance.
- Cohort signature: union member engrams.
- Set comparison: union each set, then distance between unions.

## Performance expectations (apple-m5-max)

- Pair distance: ~3 ns
- Batch: 0.65 ns/cand at bs=256
- Top-K K=10 at N=1M: 604 µs

## Language selection

Swift for Apple-platform apps and Swift servers. Rust for
cross-platform services and non-Apple hosts. Both kits wrap the
same scalar reference under conformance gate; results are
byte-identical.

## When to extend the kit (vs consume it)

Coordinate with the kit maintainers before:

- Adding a new public method to EngramLib (either language)
- Changing return types
- Anything that breaks API compatibility

No coordination needed to consume the existing API in product code.

## Anti-patterns

- Importing `GeniusLocusReference` (Swift) or
  `geniuslocus-reference` (Rust) directly in product code.
  Always import the kit instead.
- Accessing kernel types, `PortableKernel`, or `Fingerprint256`
  directly. Use `Engram` and the kit facade.
- Building filter logic inside EngramLib. Filter in product.
