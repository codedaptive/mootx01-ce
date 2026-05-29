# SubstrateKernel

The substrate's hot-path layer. Bandwidth-bound bit operations, the
write gate, the clock maker, and the SHA-256 seal. Every hot-path
read or write in the substrate touches at least one symbol from
this package.

## When to use this package

Use this when you need to:
- Compute a 256-bit fingerprint or hash a bit vector with SimHash
- Measure Hamming distance, OR-reduce, AND, XOR, or majority-vote
  combine fingerprints
- Run a top-K nearest-neighbor search by Hamming distance
- Stamp an event with an HLC and seal it with SHA-256
- Open or hold the estate-wide HLC generator
- Admit a mutation through the AuditGate (capture or mutate)

## DON'T reinvent these — they're conformance-gated

The harness gate pins six Tier-1 primitives in this package, all
byte-identical Swift+Rust. If you write a second SimHash or Hamming
loop, the gate will catch the drift and CI will go red.

| Primitive | Cookbook § | CRC | Don't write a second one |
|---|---|---|---|
| `SimHash` | §3.6 | `0x9af6b7e2` | One of the six |
| Hamming distance (256-bit) | §8.2 | `0x5e3a0291` | |
| OR-reduce over fingerprints | §8.5 | `0x6e5c89b1` | |
| Bitwise combinators (∩, ⊕, prototype) | §8.6 | `0xc7a85f08` | |
| `Fingerprint256.compute` (full four-block) | §3.6 | `0xa4b2c8d3` | |
| `HLC` compare + wire encoding | §5.2 | `0x4f1e8073` | |

Beyond the gated six, this package also publishes the AuditGate,
HLCGenerator, and SHA-256 seal — equally not-to-be-reimplemented
(they're enforcement points for I-26, I-27, I-28).

## Hot-path primitives — by name

### SimHash

Random-projection LSH. 64 ±1 hyperplanes over a bit vector produce
a 64-bit signature. The fingerprint's four blocks each invoke this
once with a different hyperplane family.

```swift
import SubstrateKernel
let block0: UInt64 = SimHash.computeBlock(rowBitmaps, family: manifest.H_0)
```

```rust
use substrate_kernel::simhash;
let block0: u64 = simhash::compute_block(&row_bitmaps, &manifest.h_0);
```

### Fingerprint256 — distance, combine, build

```swift
let dist: Int = fpA.hammingDistance(fpB)
let merged: Fingerprint256 = Fingerprint256.orReduce([fp1, fp2, fp3])
let intersect: Fingerprint256 = fpA.intersect(fpB)
let diff: Fingerprint256 = fpA.difference(fpB)
let prototype: Fingerprint256 = Fingerprint256.prototype(of: cohort)
let fp: Fingerprint256 = Fingerprint256.compute(row: row, manifest: manifest)
```

```rust
use substrate_kernel::fingerprint::Fingerprint256;

let dist: u32 = fp_a.hamming_distance(&fp_b);
let merged: Fingerprint256 = Fingerprint256::or_reduce(&[fp1, fp2, fp3]);
let intersect = fp_a.intersect(&fp_b);
let diff      = fp_a.difference(&fp_b);
let prototype = Fingerprint256::prototype(&cohort);
let fp = Fingerprint256::compute(&row, &manifest);
```

### HammingNN — top-K nearest neighbors

Branchless K-element sorted ladder. ~604 µs at K=10, N=1M on
apple-m5-max (cookbook §17.6).

```swift
let top: [(Row, Int)] = HammingNN.topK(anchor: anchor,
                                        candidates: rows,
                                        K: 10)
```

```rust
use substrate_kernel::hamming_nn;
let top: Vec<(Row, u32)> = hamming_nn::top_k(&anchor, &candidates, 10);
```

### SimdKernel — the production bit-tensor backend

You generally don't call this directly; it's selected by the
runtime's kernel dispatcher. But if you need to bypass dispatch
for a benchmark or a custom path:

```swift
let kernel = PortableKernel.kernelForCurrentPlatform()
// On aarch64 returns SimdKernel; on x86_64 fallback returns ScalarKernel.
```

```rust
let kernel = portable_kernel::for_current_platform();
```

## Write-gate and clock-maker primitives

### AuditGate — the only legitimate path to a mutation

Every write — including capture (I-26) — passes through
`AuditGate.admit`. The `prior == nil` branch is capture; `prior !=
nil` branches are the four mutators. The gate runs
`ForbiddenCombinations.check` over the merged basis (I-22), seals
the event per custody mode (I-27), and emits one `AuditEvent`.

```swift
let event = try AuditGate.admit(
    verb: .capture,
    prior: nil,
    writes: fieldWrites,
    actor: actor,
    hlc: hlc.tick()
)
```

```rust
let event = AuditGate::admit(
    Verb::Capture, None, &field_writes, &actor, hlc.tick()
)?;
```

Do not bypass the gate. Storage layers (PersistenceKit) ENFORCE
the gate's contract on receive — they refuse a write missing a
required HLC or seal — but PersistenceKit does not author HLCs or
seals (cookbook §5.11). The gate is the only authoring point.

### HLCGenerator — the clock maker (I-28)

There is exactly one active maker per audit log. `open` claims the
maker; a second `open` is REFUSED. Promotion is an explicit
logged `takeover`.

```swift
// At estate boot (GLK or a standalone kit's top entity):
let hlc = try HLCGenerator.open(over: log, nodeID: thisNodeID)

// Hand to holders by initializer injection:
let locus = LocusKit(hlc: hlc)
let rag   = RagKit(hlc: hlc)

// In any holder, stamp events:
let stamp = hlc.tick()
```

```rust
let hlc = HLCGenerator::open(&log, this_node_id)?;
let stamp = hlc.tick();
```

### SHA-256 content-ID and seal — the I-27 binding leg

The seal is SHA-256 over the wire fields of an event, including
the full HLC with maker node id. Computed inline at the gate.

```swift
let id: UInt128 = ContentID.compute(verb: verb, hlc: hlc,
                                     before: before, after: after,
                                     actor: actor)
```

```rust
use substrate_kernel::audit_gate::content_id;
let id: u128 = content_id(verb, &hlc, &before, &after, &actor);
```

You do not stamp the seal bit directly. That's `AuditGate`'s job
per custody mode (strict → 1 at write; lazy → 0 at write, dreaming
pass flips to 1 after the seal computes).

## Importing

Swift `Package.swift`:
```swift
dependencies: [
    .package(path: "../SubstrateKernel"),
],
targets: [
    .target(name: "YourKit", dependencies: ["SubstrateKernel"]),
],
```

Rust `Cargo.toml`:
```toml
[dependencies]
substrate-kernel = { path = "../../SubstrateKernel/rust" }
```

`SubstrateKernel` re-exports nothing from `SubstrateTypes`. If you
need a `Row` or `HLC` struct, depend on `SubstrateTypes` directly.

## Anti-patterns (agents commonly do these — don't)

1. **Writing a SimHash inline.** "Just a quick popcount and signs
   accumulator." There is one canonical SimHash in this package,
   conformance-gated. Yours won't match the gate's CRC.

2. **Computing Hamming distance with a naive XOR-then-loop.** Use
   `Fingerprint256.hammingDistance`. The implementation in this
   package is SIMD-vectorized and was benchmarked at ~2.6 ns/pair.

3. **Stamping HLC fields by hand.** Always go through
   `HLCGenerator.tick()`. Manually constructing an HLC value skips
   the monotonicity guarantee.

4. **Writing to the audit log directly.** All writes go through
   `AuditGate.admit`. The gate is where I-22 enforcement,
   ForbiddenCombinations.check, the seal, and the per-mode
   `sealed` bit all happen.

5. **Computing a custom seal.** The seal is SHA-256 over a specific
   field order (verb || hlc || before || after || actor || ...). If
   you change the order or the included fields, the seal becomes
   non-verifiable.

## Conformance — running the gate

If you change ANY symbol in this package that maps to a gated
primitive, run the four-way conformance check from
`../../../docs/validation/substrate_math_performance/test-harness/`:

```bash
cd swift
.build/debug/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF
.build/debug/validate-vectors ../vectors/<name>.json
../rust/target/release/validate-vectors ../vectors/<name>.json
../rust/target/release/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF --out /tmp/x.json
.build/debug/validate-vectors /tmp/x.json
../rust/target/release/validate-vectors /tmp/x.json
```

All four cells must PASS at the CRC listed in the Tier-1 table
above. If they don't, you've drifted — the legacy implementation
must produce the same bits as yours.

## Related docs

- `../../../docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md`
  §2.1 — Tier-1 primitives indexed with Swift API, Rust API, file
  paths, and CRCs.
- Cookbook v1.0 §3 (fingerprint), §5 (audit log + clock + seal),
  §8 (algorithms), §17.6 (Phase 2 measured selection).

## License

MIT OR Apache-2.0.
