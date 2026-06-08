# EngramLib howto

Product-integration guide for EngramLib (Swift and Rust). For
agents and engineers building features ON TOP of the kit, not
maintaining the kernel layer underneath it.

## What EngramLib is

A library for similarity, retrieval, and aggregation over 256-bit
engrams. Stateless by default. Thread-safe. The underlying
representation and kernel selection are hidden; you write product
code against a stable surface.

Two parallel implementations:

- **Swift**: this package (SwiftPM)
- **Rust**: `./rust` — the `engram-kit` crate (Cargo)

API shape is parallel across both. Naming follows each language's
idiom (`findNearest` / `find_nearest`).

## Install

**Swift:**
```swift
.package(path: "../EngramLib")
```
Then `import EngramLib`.

**Rust:**
```toml
engram-kit = { path = "../EngramLib/rust" }
```
Then `use engram_kit::{Engram, EngramLib, EngramExt, Match};`.

## The five things you actually do

### Swift

```swift
// 1. Pair distance
let d = EngramLib.distance(a, b)

// 2. Batch distance (probe against estate)
let ds = EngramLib.distances(probe: probe, candidates: estate)

// 3. Top-K nearest
let topK = EngramLib.findNearest(probe: probe, in: estate, k: 10)

// 4. Radius search
let near = EngramLib.findWithin(probe: probe, in: estate, maxDistance: 16)

// 5. Set union (OR-reduce)
let cohort = EngramLib.union(engrams)
```

### Rust

```rust
// 1. Pair distance
let d = EngramLib::distance(&a, &b);

// 2. Batch distance
let ds = EngramLib::distances(&probe, &estate);

// 3. Top-K nearest
let top_k = EngramLib::find_nearest(&probe, &estate, 10);

// 4. Radius search
let near = EngramLib::find_within(&probe, &estate, 16);

// 5. Set union
let cohort = EngramLib::union(&engrams);
```

All five exist as `Session` methods too. Use a Session when
running thousands of operations in a hot loop:

```swift
let session = EngramLib.session()
for probe in probes {
    let matches = session.findNearest(probe: probe, in: estate, k: 5)
}
```

```rust
let session = EngramLib::session();
for probe in &probes {
    let matches = session.find_nearest(probe, &estate, 5);
}
```

## Constructing engrams

```swift
let probe = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
let zero  = Engram.zero
```

```rust
let probe = Engram::from_blocks(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);
let zero  = Engram::zero_engram();
```

Product code treats engrams opaquely; the underlying block
semantics belong to the substrate layer.

## Returns and ordering

- `findNearest` / `find_nearest` and `findWithin` / `find_within`
  return matches sorted by distance ascending, ties by index
  ascending.
- `Match` is `{ index, distance }`. Index points into the input
  candidate array.
- Empty inputs return empty arrays. `k <= 0` (Swift) / `k == 0`
  (Rust) returns empty. `k > n` returns n matches.
- Swift `Match`: Hashable, Sendable, Codable, Comparable.
- Rust `Match`: `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`,
  `Hash`, `PartialOrd`, `Ord`.

## Concurrency

EngramLib static methods are stateless and safe to call from any
task or thread. `Session` is Sendable (Swift) / `Send + Sync`
implicit via `Box<dyn SubstrateKernel + Send + Sync>` (Rust).
No locks, no actors required.

## What EngramLib does NOT do

- No storage. Bring your own `[Engram]` / `Vec<Engram>`.
- No capture. Construct engrams upstream.
- No metadata filtering. Filter before or after the kit call.
- No persistence. RAM only.

These belong in higher layers built on top of EngramLib.

## Common patterns

**Recall similar.** Load candidate engrams from your store, call
`findNearest` / `find_nearest`, map the returned indices back to
your store records.

**Deduplicate near-duplicates.** Call `findWithin` / `find_within`
with a small maxDistance (4-8 bits) and treat the matches as
duplicates.

**Build a cohort engram.** Collect member engrams, call
`union(_:)` / `union(&...)`, store the result as the cohort's
structural signature.

**Compare two sets structurally.** Union each set independently,
then take the Hamming distance between the two union engrams.

## Performance notes

The kit uses the production-default kernel for the platform (SIMD
on aarch64). Expected throughput on Apple Silicon:

- Pair distance: ~3 ns
- Batch distance: 0.65 ns per candidate at bs=256
- Top-K with K=10: 604 µs at N=1M

These are measured numbers from the Phase 2 kernel work, not
estimates.

## Swift vs Rust selection

Choose by host:

- macOS / iOS app, server-side Swift, command-line Swift tool:
  Swift kit.
- Cross-platform service, embedded host, anything non-Apple:
  Rust kit.
- Both: each language's product code consumes its own kit;
  results are byte-identical because both wrap the same scalar
  reference under conformance gate.

## When to use Session vs static

Use static methods when the operation is rare (less than once
per second). Use Session when you're inside a loop that runs
hundreds or thousands of operations. Session avoids the kernel
construction overhead per call.

## What you do NOT need to know

- The underlying engram representation (currently 256-bit, may
  widen in future)
- Which kernel is running (SimdKernel, ScalarKernel, etc.)
- The cookbook math
- The decision-record corpus
- The methodology gate
- The test harness

Those live under the kit. Engineers maintaining the kernel layer
work in `docs/validation/substrate_math_performance/` and consult
that directory's AGENT_HOWTO.md. Different job.
