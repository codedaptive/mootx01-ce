---
status: decided
question: "For NT-P0 Merkle/commitment math (ADR-017 hash-on-write hook): which SHA-256 and HMAC backends are selected, and which re-root strategy is selected?"
authors: MOOTx01 maintainers
date: 2026-06-21
hardware: apple-m5-max
commit: 972f47813
result_artifact: docs/validation/substrate_math_performance/benchmarks/results/nt_p0/nt_p0_bakeoff_sonnet.json
relates_to:
  - docs/decisions/ADR-017-brain-layer-governor-placement.md
  - docs/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md
  - substrate mathematics treatment (maintainer-internal) §7.2 (integrity triangle)
  - docs/validation/substrate_math_performance/V1_1_IMPLEMENTATION_BAKEOFFS_2026-06-17.md
supersedes: none
---

# Decision: NT-P0 Merkle/commitment backends — SHA kernel selection and re-root strategy

---

## Scope

ADR-017 adds CoW snapshots, Merkle content-integrity, and keyed-commitment
provenance erasure. NT-P0 is the parallel spike that freezes the byte contract
and measures two implementation choices before NT-P2 locks the write-path hook.

The two questions this record answers are:

1. **B1/B2. SHA kernel.** Should the production hash-on-write path use the in-repo
   scalar `SHA256.swift` (I-25 conformance oracle) or `CryptoKit.SHA256`
   (ARMv8 sha2 hardware extension) for both plain digest and HMAC?

2. **B3. Re-root strategy.** Should the Merkle root update on each write be a
   full estate recompute or a dirty-chain incremental recompute propagating only
   through the changed room and wing?

Protocol followed: methodology gate per `AGENT_HOWTO.md` and
`DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md`. Gate B (byte identity)
before Gate C (measurement). 20% margin rule for selection.

---

## Conformance gate (Gate B)

A six-case conformance vector file was generated and validated across two legs:

```
swift run -c release gen-vectors --primitive merkle_contract \
  --seed 0xCAFEBABEDEADBEEF --out test-harness/vectors/merkle_contract.json

swift run -c release validate-vectors test-harness/vectors/merkle_contract.json
  PASS  crc 0xd389766e

cargo run --release --bin validate-vectors -- test-harness/vectors/merkle_contract.json
  PASS  crc 0xd389766e
```

CRC `0xd389766e` confirmed across Swift and Rust scalar legs.

Note on cross-brain reconciliation: the Codex brain produced CRC `0x3e2109eb`
under a different domain tag assignment (COMMITMENT = 0x11, EMPTY_ROOT tag = 0x04)
and a different interior encoding (with explicit child count field). This record
fixes this brain's contract at the values above. The two contracts are
incompatible. Reconciliation to one canonical contract is required before NT-P2
merges, and must be Bob's explicit decision.

---

## B1. SHA-256 and HMAC throughput

### Axis 1: The "1" path — SubstrateKernel.SHA256 scalar

`SHA256.swift` is the FIPS 180-4 scalar reference. Pure Swift, no SIMD, no
Accelerate. It is the I-25 oracle: all four conformance cells gate against it,
and no implementation may diverge from its output. The scalar path is always
available and always the correctness reference.

### Axis 2: The "1a" path — CryptoKit.SHA256 and CryptoKit.HMAC

CryptoKit.SHA256 on Apple Silicon uses the ARMv8 `sha256h`, `sha256h2`,
`sha256su0`, and `sha256su1` instructions — a dedicated SHA-2 hardware pipeline
in the performance cores. CryptoKit.HMAC<SHA256> uses the same pipeline for
both the inner and outer SHA-256 calls of the RFC 2104 construction. The same
`HMAC-SHA256(key=[0xAB]*32, data=payload)` call was byte-checked against the
scalar oracle for every payload size before its timing row was accepted.

Every `byte_identical_to_scalar` flag in the result artifact is `true`. The
platform path produces FIPS SHA-256 output identical to the scalar reference.

### Measured results (apple-m5-max, 2026-06-21, commit 972f47813)

SHA-256:

| Payload | Scalar p50 (µs) | Platform p50 (µs) | Speedup | 20% threshold met |
|--------:|----------------:|------------------:|--------:|:-----------------:|
| 256 B   | 1.167           | 0.375             | 3.1×    | yes               |
| 4 KB    | 13.208          | 1.500             | 8.8×    | yes               |
| 64 KB   | 208.583         | 20.041            | 10.4×   | yes               |
| ~5 KB vector-heavy | 16.666 | 1.792           | 9.3×    | yes               |

HMAC-SHA256:

| Payload | Scalar p50 (µs) | Platform p50 (µs) | Speedup | 20% threshold met |
|--------:|----------------:|------------------:|--------:|:-----------------:|
| 256 B   | 2.167           | 1.250             | 1.7×    | yes               |
| 4 KB    | 14.458          | 2.500             | 5.8×    | yes               |

**Methodology note on HMAC at 256B.** At 256B, platform HMAC is still 1.7× faster
than scalar (p50 1.250 µs vs 2.167 µs). This exceeds the 20% margin. The Codex
brain measured the opposite on its hardware (platform HMAC 0.7× scalar at 256B).
These results diverge. The likeliest explanation is per-call `Data` allocation
overhead inside CryptoKit at small payloads, which may be amortized differently
across M5 Max vs the hardware Codex measured on. This brain measured on the same
apple-m5-max target as the Phase 2 bakeoffs. The result here stands for this
hardware. If the hardware target changes, re-measure B1 before locking the
selection.

### Axis 3: Usage profile

| Caller | Path | Per-call size | Note |
|--------|------|:-------------:|------|
| NT-P2 write hook (leaf hash) | Hot | 256B–64KB typical | I-27 §7.2 content seal |
| NT-P2 rollup (room/wing/estate) | Hot | 33 + N×32 B | N children, max 256 in tested tree |
| NT-P2 keyed commitment | Hot | same as leaf + tag | HMAC over COMMITMENT payload |
| Dreaming consolidation | Cold | same | Lazy custody bit flip |

The hash-on-write path is user-facing: the write blocks until the hash completes.
Platform acceleration directly reduces write latency.

### Axis 4: Batching opportunity

The per-drawer leaf hash is inherently per-write; no batching opportunity on the
synchronous path. Rollup hashes batch naturally by tree level (all dirty rooms
before wings before root) but this is structural to the incremental algorithm
(B3), not a SHA kernel choice.

### Axis 5: Dispatcher policy

C-2 pattern (same as SimdKernel on aarch64): deterministic scalar reference
always available, hardware-accelerated path enabled on Apple platforms behind a
`#if canImport(CryptoKit)` guard. Federation-disabled if single-platform
acceleration is declared. The scalar path remains the conformance oracle; the
platform path is the production default on Apple.

### B1 disposition

**Selected: CryptoKit platform path for both SHA-256 and HMAC on Apple Swift.**

Platform SHA-256 wins by 3.1× to 10.4× across all measured payload sizes.
Platform HMAC wins by 1.7× at 256B and 5.8× at 4KB. Both exceed the 20% margin
at every measured workload point. All byte-identity assertions pass.

The scalar path remains the conformance oracle, the cross-language reference, and
the non-Apple fallback.

Rust accelerated SHA/HMAC is not selected by this record. No Rust accelerated
candidate was implemented or measured. Rust remains on the scalar oracle path
until a Rust platform candidate is added, conformance-checked, and measured under
the same gate. That is a separate decision.

---

## B2. Hash-on-write path cost

### Measured results (apple-m5-max, 2026-06-21, commit 972f47813)

4KB synthetic drawer, 256-room × 16-leaf tree:

| Candidate | p50 (µs) | p95 (µs) |
|-----------|--------:|--------:|
| Baseline encode only (no hash) | 0.167 | 0.250 |
| + leaf hash, scalar | 13.292 | 14.208 |
| + leaf hash, platform | 1.625 | 1.916 |
| + leaf hash + room/wing/estate rollup, scalar | 44.167 | 50.292 |
| + leaf hash + room/wing/estate rollup, platform | 7.583 | 9.542 |

### Disposition

Full platform write path (leaf + incremental rollup): **7.6 µs p50, 9.5 µs p95.**

The cost is absorbable. For comparison, the Phase 2 bakeoff performance budget
(cookbook §17.1) targets <100 µs for the full `recall_similar_moments` hot path
over 1M rows. The full write-path Merkle overhead under the platform path is
7.6 µs p50 — under 8% of the recall budget for a single write.

Scalar path: 44 µs p50 is still well under 100 µs, and is acceptable as the
non-Apple fallback.

**ADR-017's claim that hash-on-write is absorbable is confirmed by measurement.**

---

## B3. Merkle re-root strategy

### Axis 1: The "1" path — dirty-chain incremental

On a write to one drawer in one room, only that room's hash changes, only that
wing's hash changes, and only the estate root changes. Incremental recomputes
exactly those hashes from cached room/wing inputs. The cache is the existing
room and wing hash arrays maintained by the incremental path.

NT-P2 implication: the StorageObserver invalidation payload must carry
`(room_id, wing_id)` of the modified drawer. Without that, incremental
recompute requires a full tree scan to find what changed.

### Axis 2: The "2" path — full recompute

Recompute all room hashes across the entire tree, then all wing hashes, then the
estate root. No cache required. Correct for snapshot rebuilds and integrity sweeps
where every drawer must be re-hashed from scratch.

### Measured results (apple-m5-max, 2026-06-21, commit 972f47813)

4096-leaf, fanout-16, 256-room tree (scalar backend):

| Batch | Full p50 (µs) | Full p95 (µs) | Dirty p50 (µs) | Dirty p95 (µs) | Speedup |
|------:|--------------:|--------------:|---------------:|---------------:|--------:|
| 1     | 619.0         | 751.2         | 31.2           | 37.2           | 19.9×   |
| 8     | 620.1         | 704.9         | 33.5           | 37.0           | 18.5×   |
| 64    | 631.9         | 666.7         | 61.8           | 67.0           | 10.2×   |
| 256   | 703.8         | 726.9         | 164.2          | 206.6          | 4.3×    |

Same tree (platform backend):

| Batch | Full p50 (µs) | Full p95 (µs) | Dirty p50 (µs) | Dirty p95 (µs) | Speedup |
|------:|--------------:|--------------:|---------------:|---------------:|--------:|
| 1     | 219.0         | 235.3         | 5.8            | 6.3            | 37.8×   |
| 8     | 226.9         | 242.2         | 8.3            | 9.6            | 27.4×   |
| 64    | 239.8         | 256.6         | 30.6           | 35.6           | 7.8×    |
| 256   | 313.1         | 333.3         | 115.0          | 125.0          | 2.7×    |

### Axis 3: Crossover analysis

Incremental wins at every batch size measured (1 through 256). At batch=256,
the scalar speedup is 4.3× (still well above the 20% threshold). The crossover
where full recompute equals incremental requires dirty rooms to number all rooms
(batch_size ≥ n_leaves = 4096). That is the cold-start or full-sweep workload,
not the normal per-write path.

### Axis 4: Cache state requirement

Full recompute: no cache required. Incremental: room hash cache and wing hash
cache must be maintained across writes. Cache size: `n_rooms × 32 B + n_wings ×
32 B`. For the measured tree: 256 × 32 + 16 × 32 = 8704 bytes — negligible.

### Axis 5: NT-P2 hook design consequence

Incremental is the correct production path. The StorageObserver invalidation
payload MUST carry `(room_id, wing_id)` of the modified drawer. Full recompute
is retained as the rebuild and sweep path (snapshot integrity checks, migration,
first-boot hash generation). Neither path is wrong; they serve different workloads.

### B3 disposition

**Selected: dirty-chain incremental for normal capture/mutate/expunge writes.
Full recompute retained for snapshot rebuilds, integrity sweeps, and cold-start
estate hashing.**

Incremental wins by 4.3× to 37.8× across all measured batch sizes. All results
exceed the 20% margin by a large factor.

---

## Methodology ledger entry

| Claim | Paper said | Measured | Direction |
|-------|-----------|---------|---------|
| Platform SHA-256 faster than scalar | Yes, ARMv8 sha2 | 3.1×–10.4× faster at all sizes | correct |
| Platform HMAC faster at 256B | Ambiguous — Codex measured slower | 1.7× faster on apple-m5-max | diverges from Codex; re-measure if hardware changes |
| Platform HMAC faster at 4KB+ | Yes | 5.8× faster | correct |
| Write-path cost absorbable | Yes, claimed in ADR-017 | 7.6 µs p50 platform path | confirmed |
| Incremental faster than full recompute | Yes, at all write sizes | 4.3×–37.8× across batch 1–256 | correct |

Score: paper analysis correct in direction 4 of 5 cases. One case (HMAC at 256B)
required measurement to resolve a cross-brain divergence; the Phase 2 methodology
gate earned its keep.

---

## Final selection table

| Workload | Selected path | Evidence |
|---------|--------------|---------|
| SHA-256 on Apple Swift | CryptoKit.SHA256 | 3.1×–10.4× at all payload sizes, byte-identical |
| HMAC-SHA256 on Apple Swift | CryptoKit.HMAC<SHA256> | 1.7×–5.8× at all measured sizes, byte-identical |
| SHA-256/HMAC on Rust / non-Apple | SubstrateKernel.SHA256 + GrantHKDF.hmac scalar | Unmeasured platform candidates; scalar is current path |
| Merkle root update (normal writes) | Dirty-chain incremental | 4.3×–37.8× at batch 1–256, both backends |
| Merkle root rebuild (snapshot/sweep) | Full recompute | Correct for full-integrity passes; incremental not applicable |

---

## Open items before NT-P2

1. **Cross-brain byte contract reconciliation.** Codex: COMMITMENT tag = 0x11,
   EMPTY_ROOT tag = 0x04, interior with explicit child count. This brain:
   COMMITMENT = 0x04, EMPTY_ROOT = SHA256([0x02]), interior without child count.
   The CRCs differ (0x3e2109eb vs 0xd389766e). Bob must pick one before NT-P2
   locks; the decision has no performance implication, only byte compatibility.

2. **Rust accelerated SHA/HMAC.** Not measured. Rust remains on scalar until a
   Rust CryptoKit equivalent (e.g. ring crate SHA-256) is implemented,
   conformance-gated, and measured under this same protocol.

3. **Key storage.** KeyedCommitmentBuilder takes an estate key as a parameter.
   Where that key comes from (Keychain, estate key store) is NT-P3 scope.

4. **StorageObserver payload.** NT-P2 must add `(room_id, wing_id)` to the
   invalidation payload to enable incremental re-root. This is a NT-P2 design
   decision, not NT-P0.

---

## Artifacts

| Path | Status |
|------|--------|
| `packages/libs/SubstrateTypes/Sources/SubstrateTypes/ContentHash.swift` | done |
| `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MerkleContract.swift` | done |
| `packages/libs/SubstrateKernel/Sources/SubstrateKernel/KeyedCommitment.swift` | done |
| `packages/libs/SubstrateTypes/rust/src/content_hash.rs` | done |
| `packages/libs/SubstrateKernel/rust/src/merkle_contract.rs` | done |
| `packages/libs/SubstrateTypes/Tests/.../MerkleContractTests.swift` | done, 171 passing |
| `packages/libs/SubstrateKernel/Tests/.../KeyedCommitmentTests.swift` | done, 87 passing |
| `test-harness/swift/.../MerkleContractPrimitive.swift` | done |
| `test-harness/vectors/merkle_contract.json` | done, CRC 0xd389766e |
| `test-harness/swift/Sources/NTP0Bakeoff/main.swift` | done |
| `benchmarks/results/nt_p0/nt_p0_bakeoff_sonnet.json` | done |
