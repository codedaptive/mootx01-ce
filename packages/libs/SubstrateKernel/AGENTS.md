# SubstrateKernel

The substrate's hot-path layer. Bandwidth-bound bit operations, bitmap
field extraction, and the SHA-256 hash. Every hot-path read or write in
the substrate touches at least one symbol from this package.

The write gate (`AuditGate`) lives in `SubstrateLib` and the clock maker
(`HLCGenerator`) in `SubstrateTypes`; both *consume* this package but are
documented in their own AGENTS.md (see the 2026-05-29 four-package
addendum).

## When to use this package

Use this when you need to:
- Compute a 256-bit fingerprint or hash a bit vector with SimHash
- Measure Hamming distance, OR-reduce, AND, XOR, or majority-vote
  combine fingerprints
- Run a top-K nearest-neighbor search by Hamming distance
- Extract or masked-compare a bitmap field (`BitField`)
- Compute a SHA-256 hash (the primitive the AuditGate seal is built on)

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

Beyond the gated six, this package also publishes `BitField` and the
`SHA-256` hash — equally not-to-be-reimplemented. The AuditGate write
gate (I-26/I-22, in `SubstrateLib`) and the HLCGenerator clock maker
(I-28, in `SubstrateTypes`) build on these.

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

### BitField — bitmap field extraction

Branchless extract / masked-equals over the packed adjective /
operational / provenance bitmaps. The substrate's bitmap accessors and
the AuditGate vocabulary check both build on it.

```swift
let trust = BitField.extractField(adjectiveBitmap, shift: 18, width: 6)
```

```rust
use substrate_kernel::bit_field;
let trust = bit_field::extract_field(adjective_bitmap, 18, 6);
```

### SHA-256 — the content-hash primitive (I-27 binding leg)

SHA-256 over the wire fields of an event is the seal. The hash itself
lives here; the seal/content-ID is *computed by* `AuditGate`
(`SubstrateLib`) using this primitive — you do not stamp the seal bit
directly (that is the gate's job per custody mode).

```swift
let digest: [UInt8] = SHA256.hash(bytes)
```

```rust
use substrate_kernel::sha256;
let digest: [u8; 32] = sha256::hash(&bytes);
```

## Not in this package: the write gate + clock maker

- **`AuditGate`** — the only legitimate path to a mutation — lives in
  `SubstrateLib` (it validates against `RowStateAutomaton`, the
  orchestration FSM). It consumes this package's `BitField` + `SHA256`.
  See `SubstrateLib`'s AGENTS.md.
- **`HLCGenerator`** — the clock maker (I-28) — lives in `SubstrateTypes`
  alongside the `HLC` value type. See `SubstrateTypes`' AGENTS.md.

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

3. **Open-coding bitmap field extraction.** Use `BitField.extractField`
   / `maskedEquals`; a hand-rolled shift-and-mask drifts from the gated
   layout. (HLC stamping via `HLCGenerator` and audit writes via
   `AuditGate` are the same "don't reinvent" rule, but those symbols
   live in `SubstrateTypes` / `SubstrateLib` — see their AGENTS.md.)

4. **Computing a custom seal.** The seal is SHA-256 over a specific
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

- `../../../docs/engineering/HARNESS_REFERENCE.md`
  §2.1 — Tier-1 primitives indexed with Swift API, Rust API, file
  paths, and CRCs.
- Cookbook v1.0 §3 (fingerprint), §5 (audit log + clock + seal),
  §8 (algorithms), §17.6 (Phase 2 measured selection).

## License

MIT OR Apache-2.0.
