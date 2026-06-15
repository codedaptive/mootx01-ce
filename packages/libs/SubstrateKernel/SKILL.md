---
name: substrate-kernel
description: Use this skill when an agent needs to compute a substrate hot-path primitive — SimHash, Hamming distance, OR-reduce, bitwise combinators, Fingerprint256 construction, HammingNN top-K nearest neighbors, BitField bitmap extraction, or a SHA-256 hash. These are byte-identical Swift+Rust implementations behind a conformance-gated CRC. Trigger this skill whenever an agent is about to hand-write any of those operations, or use any bit operation on a Fingerprint256. (The AuditGate write gate lives in SubstrateLib and HLCGenerator in SubstrateTypes — see their skills.) The skill redirects to the existing implementation and prevents re-invention drift the conformance harness would catch in CI.
---

# substrate-kernel — hot-path bit ops, bitmap fields, hashing

## When this skill applies

An agent is about to write code that does any of:
- Random-projection LSH (SimHash) over a bit vector
- Hamming distance between 256-bit fingerprints
- OR-reduce / AND / XOR / majority-prototype over a set of fingerprints
- Top-K nearest-neighbor search by Hamming distance
- Bitmap field extraction / masked-equals (`BitField`)
- A SHA-256 hash (the primitive the AuditGate seal is built on)

(HLC comparison/tick and the audit-log write gate are NOT here — `HLC`
+ `HLCGenerator` live in `SubstrateTypes`, `AuditGate` in `SubstrateLib`.)

## The one rule

These are conformance-gated with CRC-32 seals. **Don't reinvent
any of them.** Swift and Rust implementations must produce
byte-identical output on the canonical test vector; CI runs the
four-way check on every commit. A hand-rolled SimHash WILL drift
from the seal and turn CI red.

| Primitive | Use |
|---|---|
| SimHash | `SimHash.computeBlock(_:family:)` / `simhash::compute_block` |
| Hamming | `fp.hammingDistance(other)` / `fp.hamming_distance(&other)` |
| OR-reduce | `Fingerprint256.orReduce([…])` / `Fingerprint256::or_reduce(&[…])` |
| Bitwise | `fp.intersect(other)` / `.difference(other)` / `Fingerprint256.prototype(of:)` |
| Fingerprint construction | `Fingerprint256.compute(row:manifest:)` |
| HammingNN top-K | `HammingNN.topK(anchor:candidates:K:)` |
| BitField | `BitField.extractField(_:shift:width:)` / `bit_field::extract_field` |
| SHA-256 hash | `SHA256.hash(_:)` / `sha256::hash(_:)` |

## Anti-patterns

1. Hand-rolling a SimHash (one popcount-and-sign loop). It will
   drift from the gated CRC `0x9af6b7e2`.
2. Using XOR + bit-loop for Hamming instead of `Fingerprint256.hammingDistance`,
   which is SIMD-vectorized.
3. Open-coding bitmap field extraction instead of `BitField`.
4. Computing a custom hash for content addressing. The seal is
   SHA-256 over a specific field order; deviation makes events
   non-verifiable. (HLC stamping via `HLCGenerator` and audit writes
   via `AuditGate` are the same rule — but those symbols are in
   `SubstrateTypes` / `SubstrateLib`; see their skills.)

## How to use

```swift
import SubstrateKernel

// Distance
let d = fpA.hammingDistance(fpB)

// Construction
let fp = Fingerprint256.compute(row: row, manifest: manifest)

// Top-K
let top = HammingNN.topK(anchor: anchor, candidates: rows, K: 10)

// SHA-256 hash (the AuditGate seal is built on this)
let digest = SHA256.hash(bytes)
```

```rust
use substrate_kernel::{fingerprint::Fingerprint256, hamming_nn, sha256};

let d = fp_a.hamming_distance(&fp_b);
let fp = Fingerprint256::compute(&row, &manifest);
let top = hamming_nn::top_k(&anchor, &candidates, 10);
let digest = sha256::hash(&bytes);
```

Package wiring:
```swift
.package(path: "../SubstrateKernel"),
// targets dependencies: ["SubstrateKernel"]
```

```toml
substrate-kernel = { path = "../../SubstrateKernel/rust" }
```

## If you change a gated primitive

Run the four-way conformance check from the harness directory.
See `docs/validation/substrate_math_performance/test-harness/SKILL.md`
for the workflow. All four cells must PASS at the CRC listed in
this package's `AGENTS.md` table before you commit.

## What to read

`packages/libs/SubstrateKernel/AGENTS.md` for the full API reference
with code examples per primitive. `docs/engineering/HARNESS_REFERENCE.md`
§2.1 for the canonical index with file paths and CRCs.
