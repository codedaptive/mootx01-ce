---
status: decided
question: Which compute backends should serve `simhash_block` and the batched `simhash_block_batch`, and which is the aarch64 default?
authors: MOOTx01 maintainers
date: 2026-06-06
relates_to:
  - docs/decisions/DECISION_OR_REDUCE_BACKENDS_2026-05-17.md
  - docs/decisions/DECISION_HAMMING_BACKENDS_2026-05-17.md
  - docs/decisions/DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
supersedes: none
context:
  - "Op: `simhash_block` and the implicit `simhash_block_batch` (Rust: `SubstrateKernel::simhash_block`, Swift: `SubstrateKernel.simhashCompute`)."
  - "SimHash is the most compute-bound of the three substrate primitives (~768 popcounts per fingerprint)."
  - "Cookbook references: §3.2-§3.7, §3.9, §4.4, §17.5."
---

# Decision: `simhash_block_batch` Backends

## Context and op signature

SimHash is the Locality-Sensitive Hashing variant used to derive
each block of a `Fingerprint256` from a row's typed input vector
under a manifest-immutable family of 64 hyperplanes. Per cookbook
§3.6, the canonical formulation:

```rust
fn block(v: &[u64], family: &HyperplaneFamily) -> u64 {
    let mut result: u64 = 0;
    for k in 0..64 {
        if family.planes[k].sign(v) {
            result |= 1u64 << k;
        }
    }
    result
}

// where Hyperplane::sign is:
fn sign(&self, v: &[u64]) -> bool {
    let mut pos: u32 = 0;
    let mut neg: u32 = 0;
    for i in 0..v.len() {
        pos += (v[i] & self.positive_mask[i]).count_ones();
        neg += (v[i] & self.negative_mask[i]).count_ones();
    }
    pos > neg
}
```

The full `Fingerprint256` is the concatenation of four 64-bit
`block` outputs under four distinct hyperplane families
(H_0..H_3). Block 0 has a 192-bit input (`v.len() = 3` u64s);
blocks 1-3 have 64-bit input (`v.len() = 1` u64).

### Work per fingerprint

| Block | Input bits | u64 words | Popcounts/plane | Popcounts/block | Total |
|---:|---:|---:|---:|---:|---:|
| 0 | 192 | 3 | 6 | 384 | |
| 1 | 64  | 1 | 2 | 128 | |
| 2 | 64  | 1 | 2 | 128 | |
| 3 | 64  | 1 | 2 | 128 | |
| Σ | | | | | **768** |

That's roughly **192× more popcount work per fingerprint than
Hamming** (which is 4 popcounts per pair). SimHash is genuinely
compute-bound in a way Hamming is not, which puts the
methodology gate's per-axis investigation in a different regime
than the prior decisions.

### Baseline measurement before Phase 2.γ (apple-m5-max, 2026-05-18, commit `d70258a`)

`simhash_block_batch`, batched mode:

| Batch | Scalar (Swift) | Scalar (Rust) | SimdKernel (Swift, inherited) | SimdKernel (Rust, inherited) |
|---:|---:|---:|---:|---:|
| 1   | 166 ns    | 83 ns    | 166 ns    | 83 ns    |
| 8   | 2166 ns   | 1041 ns  | 2166 ns   | 1000 ns  |
| 32  | 10542 ns  | 4125 ns  | 10416 ns  | 4167 ns  |
| 128 | 45375 ns  | 16875 ns | 44875 ns  | 16750 ns |
| 256 | 96125 ns  | 33833 ns | 96084 ns  | 33583 ns |

The Phase 2.α SimdKernel inherits the scalar default for
`simhashCompute` (since Phase 2.α scope was OR-reduce only); the
1.00× "speedup" rows confirm the inheritance.

Note the cross-language gap: Rust's scalar is roughly 2.8× faster
than Swift's scalar across the entire batch range. The same
pattern from the OR-reduce decision: Rust's compiler
autovectorizes the popcount loop while Swift's does not. The
specific gap for SimHash is smaller than OR-reduce (~3× vs
~14×) because SimHash has more arithmetic per popcount (the
`pos > neg` comparison and the bit-set construction add scalar
work the compiler can't hide).

---

## Axis 1: The "1" path

### What the work looks like

For each fingerprint block, 64 hyperplanes are evaluated. Each
hyperplane needs 2 ANDs + 2 popcounts + comparison + bit-set.
The natural SIMD reformulation is **vertical SIMD over
hyperplanes**: pack 4 consecutive hyperplanes' `positive_mask`
and `negative_mask` into `SIMD4<UInt64>` lanes, broadcast `v[i]`
across the 4 lanes, AND, popcount per lane, accumulate.

Pseudocode for block 0 (input `v` is 3 u64s):

```
for k_group in 0..16 {           // 16 groups of 4 hyperplanes
    let mut pos4 = SIMD4<UInt32>(0, 0, 0, 0)
    let mut neg4 = SIMD4<UInt32>(0, 0, 0, 0)
    for i in 0..3 {              // 3 words of v
        let v_i = SIMD4<UInt64>(repeating: v[i])
        let pos_masks = SIMD4(pos[4*k_group+0][i], ..., pos[4*k_group+3][i])
        let neg_masks = SIMD4(neg[4*k_group+0][i], ..., neg[4*k_group+3][i])
        pos4 += popcount4(v_i & pos_masks)
        neg4 += popcount4(v_i & neg_masks)
    }
    for lane in 0..4 {
        if pos4[lane] > neg4[lane] {
            result |= 1u64 << (4 * k_group + lane)
        }
    }
}
```

This is the conceptual SIMD shape; the per-lane comparison +
bit-set at the end requires either explicit lane extraction (the
shape above) or a SIMD-mask + compress operation. The latter
would emit `cmgt` + `bsl` on aarch64 and avoid the scalar lane
loop, but is more work to express in idiomatic Swift `SIMD4`.

### Key dependencies

**Lane-wise popcount on SIMD4<UInt64>.** Per the Phase 2.β-1
finding, Swift's `xv[0].nonzeroBitCount + ...` compiles to a
reasonable sequence on aarch64 (4 CNT-based sequences, 4
adds, 4 lanes of effective work). The same approach should
extend to per-lane popcount accumulation here.

**Hyperplane storage layout.** The current `HyperplaneFamily`
stores planes as a `Vec<Hyperplane>` where each `Hyperplane`
has a `positive_mask: Vec<u64>` and `negative_mask: Vec<u64>`.
This is **AoS** (array-of-structures) layout. The vertical
SIMD shape above wants **SoA** (structure-of-arrays):

```
struct HyperplaneFamilySoA {
    positive_masks: [[u64; 3]; 64]   // [plane][word]
    negative_masks: [[u64; 3]; 64]
}
```

Or, even better for SIMD4 access:

```
struct HyperplaneFamilyPacked {
    positive_masks_word0: [SIMD4<UInt64>; 16]  // 16 groups of 4
    positive_masks_word1: [SIMD4<UInt64>; 16]
    positive_masks_word2: [SIMD4<UInt64>; 16]
    negative_masks_word0: [SIMD4<UInt64>; 16]
    ...
}
```

The SoA / packed layout is a kernel implementation detail and
should be derivable from the canonical AoS layout at kernel
construction time. The conformance gate ensures the derivation
preserves semantics.

### Cost on M-series (estimated)

Per block 0: 16 groups × 3 words × (2 SIMD ANDs + 2 SIMD
popcounts + 2 SIMD adds + comparison) ≈ 16 × 18 cycles ≈ 288
cycles ≈ 72 ns at 4 GHz.

Per blocks 1-3: 16 groups × 1 word × ~18 cycles ≈ 16 × 18 ≈ 288
cycles per block; but more accurately ≈ 16 × 12 cycles ≈ 192
cycles ≈ 48 ns each.

Total per fingerprint: 72 + 3 × 48 ≈ 216 ns, vs the current
~166 ns Swift scalar at bs=1 (and ~83 ns Rust scalar). The
estimate suggests the explicit SIMD shape might *not* outpace
Rust's autovectorized scalar. We'll measure.

For Swift specifically: Swift's scalar is 166 ns at bs=1 vs
Rust's 83 ns. If the explicit SIMD lands at ~200 ns, that's a
*regression* on Rust and a wash on Swift. The methodology gate
says: implement and measure; the prediction here is "this might
not help, but the empirical answer is the answer."

### Lit references

- **Mula sse-popcount** (`github.com/WojciechMula/sse-popcount`):
  the popcount-over-fixed-width-vector idiom transfers
  directly; SimHash's 64-plane structure maps to 16 SIMD4
  groups.
- **Apple Developer docs** confirm `SIMD4<UInt64>.&` and
  `SIMD4<UInt64>.|=` lower to NEON. Lane-wise popcount through
  `nonzeroBitCount` per lane lowers acceptably per Phase 2.β-1.
- **Rust `std::simd`**: `u64x4 & u64x4` and
  `.count_ones()` per-lane lower equivalently.

---

## Axis 2: The "1a" path — AMX/BNNS matrix multiply

### Theory

The 64-hyperplane block is structurally a matrix-vector
product. Encode `v` and the hyperplane family as ±1 floats:

- Block 0: matrix `M_0` is 64 rows × 192 cols of Float32 (a
  hyperplane per row; ±1 entry per column).
- Block 0 input: vector `v_0` is 192 Float32 (bits of `v` as
  ±1.0).
- Result: 64 Float32 elements; `result_bit_k = sign(M_0[k] · v_0)`.

For blocks 1-3, the matrix is 64×64 and the input is 64 floats.

This is **exactly the BNN inference identity** the Hamming Axis
2 referenced, but applied to a different op. Two structural
differences from the Hamming case:

1. **The matrix is constant.** Hyperplanes are manifest-immutable
   per cookbook §3.7. The float-encoded matrices can be **pre-
   computed once at manifest load** and cached for the lifetime
   of the estate. Encoding cost is paid once, not per call.
2. **The "candidates" are the queries.** In Hamming-NN, the probe
   is one vector and the candidates are many; encoding the
   candidates dominates. Here, every fingerprint computation
   sends one new input vector through the same precomputed
   matrix. Per-call encoding cost is one vector worth of
   floats, not N.

### Why this might actually win

The Hamming Axis 2 paper-then-measure cycle established two
inescapable Big Ones:

1. The encoding cost dominates if it scales with N. (Phase
   2.α-4 BNNS or_reduce, Phase 2.β-2(b) BNNS Hamming both
   confirmed this empirically.)
2. The Metal dispatch overhead is ~70 µs floor regardless of
   N. (Phase 2.β-2(c) MetalKernel confirmed this.)

Neither failure mode automatically applies to BNNS SimHash:

- The hyperplane matrix encoding is **once per estate lifetime**,
  not per call. The per-call cost is one 192-Float encode for
  block 0 + three 64-Float encodes for blocks 1-3 = 384 floats
  worth of encoding work. That's ~1500 bytes per call, vs
  Hamming's 32×N×4 = 128 KB per call at N=1K.
- The matmul shape is 64×192 × 192×1 = 64 output elements per
  block 0 call, or 64×64 × 64×1 = 64 output elements per blocks
  1-3 call. These are smaller than Hamming's 1×256 × 256×N
  shape, but they happen 4× per fingerprint, and the input
  vector is much smaller.

The methodology gate's protocol: implement and measure. The
paper analysis above suggests BNNS SimHash might be the second
candidate (after Metal Hamming at large N) where the paper
estimate is essentially right.

### Caveat: AMX vs LocalNLM contention

The Hamming Axis 2 raised the AMX-vs-LocalNLM resource-
contention argument. It applies here too: SimHash on the hot
path of row capture runs alongside LocalNLM token generation
which also uses AMX. If BnnsKernel SimHash on the hot path
ends up resource-contending with LocalNLM, the dispatcher
needs a thermal/contention-aware fallback to SimdKernel.

This is a dispatcher-policy concern, not a kernel-correctness
concern. The kernel ships; the dispatcher learns when to use
it (cookbook §4.4 learned dispatch).

---

## Axis 3: Usage profile

Audit of `simhash_block` callers per cookbook §3.6:

| Caller | Path | Latency budget | Typical N | Queueable |
|---|---|---|---|---|
| Row ingestion (`captureRow`) | Hot path | <1 ms per row | 1 (per row) | No |
| Fingerprint regeneration (manifest update) | Cold path | None | 100K-10M | Yes |
| Federation pairing handshake (§12.1) | Cold path | <5 sec | <1000 | Yes |
| Dreaming-daemon contribution pass (§15.4) | Cold path | None | 100K-1M | Yes |

Two regimes:

1. **Per-row hot path.** One fingerprint per call, latency-
   bound. SimdKernel-class kernel is the right choice for this
   regime if it can land near or below the scalar baseline.
2. **Bulk cold path.** Millions of rows in one pass, no user
   waiting. BNNS / Metal candidates earn their per-call setup
   cost across the batch.

The 4-block fingerprint composition (cookbook §3.2-§3.5) means
both regimes always compute all four blocks per row; per-block
specialization isn't useful.

---

## Axis 4: Batching opportunity

### Hot path: one row at a time

Row ingestion has no queue point upstream of `simhash_block`.
The capture flow is "row arrives, fingerprint it, persist". No
batching at the row level without changing the capture
contract.

The four blocks per fingerprint *can* be computed in parallel
(they're independent). A future kernel could issue all four
in one BNNS call (the matmuls are independent so it's not a
fused op, but the dispatch overhead is shared). Phase 2.γ-2
will measure whether this matters.

### Cold path: bulk regeneration

The dreaming-daemon contribution pass and manifest-rotation
regen both process many rows in one pass. Natural batch sizes:
10K to 10M. Both batch trivially at the kernel layer; no new
queueing needed.

### Federation pairing handshake

Pairing computes "compatibility fingerprints" between two
estates: each fingerprints a sample of its rows under the
shared family, compares, decides pairing fit. Per cookbook
§12.1 the handshake processes ~100-1000 rows. Batches at the
kernel layer.

---

## Axis 5: Dispatcher policy

### Backend menu (Phase 2.γ scope)

Candidates to be evaluated:

- **ScalarKernel** — reference, always available.
- **SimdKernel-with-SimHash-override** (Phase 2.γ-1): explicit
  SIMD over hyperplanes via `SIMD4<UInt64>` packed mask layout.
  Replaces the current inherited-scalar `simhashCompute`.
- **BnnsKernel.simhashCompute** (Phase 2.γ-2): pre-encoded
  hyperplane matrix at manifest load, per-call float-encode of
  input vector, BNNS matrix-vector multiply, sign() decode.
- **MetalKernel.simhashCompute** (Phase 2.γ-3): only if Phase
  2.γ-2 doesn't decisively win. The Metal dispatch floor (~70 µs
  per Phase 2.β-2(c)) likely makes per-row SimHash a non-starter,
  but the bulk-regeneration cold path may shift the math.

### Policy sketch (to be refined after measurements)

```
dispatch_simhash_block(v, family, caller_class):
    if caller_class == .bulkRegeneration:
        # Try BNNS first; large amortization window.
        if BnnsKernel available and not AMX-contended:
            return BnnsKernel
        if MetalKernel available and batch_size > ~10K:
            return MetalKernel
        return SimdKernel
    else:  # hot path / per-row
        # Latency wins; AMX setup overhead almost certainly loses.
        if SimdKernel available:
            return SimdKernel
        return ScalarKernel
```

### Resource pressure response

Per the Hamming Axis 5 framing, NEON does not contend with
LocalNLM AMX. The SIMD path is the safe default under thermal
pressure. The BNNS path needs to defer to LocalNLM if AMX is
contended; the dispatcher can read AMX queue depth via the
NeuronKit telemetry layer (cookbook §4.4).

### Fallback

If `import simd` / `std::simd` / `Accelerate` / `Metal` are
unavailable, the dispatcher falls through to ScalarKernel.
Correctness preserved.

---

## Implementation plan

**Phase 2.γ-1**:
- Override `simhashCompute` in Swift `SimdKernel` to use explicit
  `SIMD4<UInt64>` over packed hyperplane lanes.
- Override `simhash_block` in Rust `SimdKernel` to use `u64x4`
  with the equivalent packed layout.
- Build a derived SoA/packed view of `HyperplaneFamily` at
  kernel-construction time (or pass through a separate adapter
  layer; design decision deferred to implementation).
- Run conformance gate `--kernel simd` for the `simhash`
  primitive. CRC must match scalar byte-for-byte.
- Stress-test sweep; update this DR with measured numbers.

**Phase 2.γ-2**:
- Implement `BnnsKernel.simhashCompute`. Pre-encode the four
  hyperplane families to ±1 Float32 matrices at kernel
  construction; per-call encode the input vector to floats and
  issue `BNNS.applyMatrixMultiplication`. Decode the 64 output
  signs as block bits.
- The pre-encoded matrix lifetime question: BnnsKernel needs
  the family at construction. Either (a) BnnsKernel takes the
  families as constructor arguments, in which case the
  registry needs to know them, or (b) BnnsKernel lazily
  encodes on first use and caches per-family. Decision
  deferred to implementation.
- Conformance gate `--kernel bnns`. Same byte-identity rule.
- Stress-test sweep; update this DR.

**Phase 2.γ-3** (conditional):
- If Phase 2.γ-2 wins decisively in the bulk-regeneration
  regime, MetalKernel SimHash is likely redundant. If Phase
  2.γ-2 loses (e.g., AMX contention or BNNS setup cost still
  dominates), implement MetalKernel.simhashCompute via a new
  compute shader.
- Decision criterion: measure 2.γ-1 and 2.γ-2 first; decide
  whether 2.γ-3 is worth implementing.

---

## Open questions / future work

1. **Hyperplane SoA layout**: where does the packed layout
   live? Options:
   - On `HyperplaneFamily` itself, derived once.
   - On the kernel (SimdKernel caches a packed view).
   - In a separate adapter struct that kernels accept as input.
   Affects the trait signature. Defer to implementation.

2. **Cross-block parallelism**: a single SimHash call computes
   four blocks. The blocks are independent. Within `SimdKernel`,
   should the four be computed in parallel via separate SIMD
   registers, or sequentially with one register reused?
   Empirically test once the per-block SIMD path is measured.

3. **BNNS matrix pre-encoding lifetime**: the hyperplane family
   is manifest-immutable but the kernel is instantiated per
   call site. Either (a) BnnsKernel takes the family at
   construction (changes the trait), (b) BnnsKernel caches
   per-family-hash internally (adds state), or (c) the harness
   special-cases SimHash kernel construction. Defer to
   implementation; (b) feels right but adds complexity.

4. **Stress-test result**: speedups at batch sizes 1, 2, 4, 8,
   16, 32, 64, 128, 256 in both languages. Fill in this section
   after implementation, mirroring the Phase 2.β-1 pattern.

5. **Phase 2.γ-3 MetalKernel decision**: deferred until Phase
   2.γ-1 and 2.γ-2 are measured.

6. **AMX contention measurement**: under simulated LocalNLM
   load, does BnnsKernel SimHash regress sharply? Test once
   the kernel is in place.

---

## Phase 2.γ-1 addendum — SimdKernel SimHash measured win

Phase 2.γ-1 implements the Axis 1 "1" path: explicit vertical
SIMD over packed hyperplane lanes, with a one-time packed
family construction amortized across the batch. The methodology
gate's prediction was "this might not help, but the empirical
answer is the answer." The empirical answer is: **it helps,
decisively, in both languages, converging to the same floor.**

### Implementation

**Swift**: `SimdKernel.simhashBlockBatch` overrides the protocol default
loop. The override:

1. Builds a `PackedFamily` view of the input `HyperplaneFamily`
   ONCE per batch. 16 groups × wordCount entries of
   `SIMD4<UInt64>` for positive and negative masks each. Cost
   ~250 ns per construction on apple-m5-max; amortized across
   N inputs.
2. For each input vector, runs `simhashBlockSIMD`: 16 outer
   iterations (one per group of 4 hyperplanes), inner loop over
   wordCount, vertical SIMD AND + lane-wise `nonzeroBitCount` +
   `SIMD4<UInt32>` accumulator. Final per-lane `pos > neg`
   comparison + bit-set.

**Rust**: mirror implementation using `std::simd::u64x4` and
`count_ones`. Same algorithmic
shape; the PackedFamily lives as a private module-level struct
with its own `new(...)` constructor.

`simhashCompute` (the full per-fingerprint call, used at row
capture) continues to inherit the scalar path. Per-call packing
at bs=1 would cost ~1 µs of family-construction overhead with
no amortization; that path stays scalar.

Conformance passes byte-identical to scalar across all four
cells (CRC `0xddd18e12` for simhash.json):

- Swift × scalar:  PASS
- Swift × simd:    PASS
- Rust  × scalar:  PASS
- Rust  × simd:    PASS

### Measurement (apple-m5-max, 2026-05-18, commit pending)

`simhash_block_batch`, batched mode:

**Swift:**

| Batch | Scalar | SimdKernel | SIMD speedup |
|---:|---:|---:|---:|
| 1   | 166 ns    | 416 ns    | 0.40x (overhead > work) |
| 4   | 833 ns    | 625 ns    | 1.33x |
| 8   | 2166 ns   | 875 ns    | 2.48x |
| 16  | 4875 ns   | 1291 ns   | 3.78x |
| 32  | 10791 ns  | 2250 ns   | 4.80x |
| 64  | 23500 ns  | 4083 ns   | 5.76x |
| 128 | 48500 ns  | 7791 ns   | 6.22x |
| 256 | 98208 ns  | 15166 ns  | **6.48x** |

**Rust:**

| Batch | Scalar | SimdKernel | SIMD speedup |
|---:|---:|---:|---:|
| 1   | 83 ns     | 166 ns    | 0.50x (overhead) |
| 4   | 458 ns    | 333 ns    | 1.38x |
| 8   | 958 ns    | 583 ns    | 1.64x |
| 16  | 2000 ns   | 1083 ns   | 1.85x |
| 32  | 4083 ns   | 2041 ns   | 2.00x |
| 64  | 8250 ns   | 3958 ns   | 2.08x |
| 128 | 16541 ns  | 7791 ns   | 2.12x |
| 256 | 33125 ns  | 15500 ns  | **2.14x** |

### Findings

**(1) Both languages converge to the same floor.** Swift SIMD
at bs=256 lands at 15166 ns; Rust SIMD at 15500 ns. The gap
is within the timer's noise floor. The explicit SIMD shape is
compiler-independent: once the code is forced into u64x4 lanes,
both Swift and Rust LLVM lower to the same NEON sequence. The
cross-language scalar gap (Swift 98208 ns, Rust 33125 ns) is
entirely a compiler-frontend difference; the optimal floor is
identical.

**(2) The SimHash speedup pattern fits between OR-reduce and
Hamming.** Recap of cross-language SIMD speedup at bs=256:

| Op | Swift speedup | Rust speedup | Mechanism |
|---|---:|---:|---|
| OR-reduce | 23.3x | 2.2x | Swift fails to autovec accumulator-OR |
| SimHash   | 6.5x  | 2.1x | Swift partially fails on comparison branch |
| Hamming   | 1.0x  | 1.5x | Both compilers autovec the popcount loop |

SimHash's intermediate position confirms the prediction in the
Phase 2.γ scoping doc: "Swift sees a bigger win because more
non-popcount scalar work (the `pos > neg` comparison and bit-set
construction) the compiler couldn't hide." The comparison
branch is the specific feature that the Swift autovectorizer
doesn't handle as well as the popcount-only inner loop.

**(3) Crossover at bs ~= 4.** Below bs=4 the packed-family
construction cost dominates; above bs=4 the per-input SIMD work
dominates. For the hot-path row-capture case (bs=1), the
override is *worse* than scalar by ~2x. This matters for
dispatcher policy: if SimdKernel is unconditionally chosen on
aarch64, the per-row hot path regresses. Two resolutions:

   a. Keep `simhashCompute` (per-fingerprint, 4 families) on
      scalar in SimdKernel — already done.
   b. The harness measures `simhashBlockBatch` which is the
      bulk path; that's the path that gets the 6.5x. The hot
      single-row path is `simhashCompute` and stays scalar.

This is the right factoring: bulk batched ops use vectorized
paths, per-row ops use the path with the lowest constant
overhead.

### Methodology takeaway

The scoping doc estimated ~256 ns per fingerprint for the SIMD
path (worse than the ~166 ns scalar at bs=1). The measurement
confirmed that estimate at small batches: bs=1 SIMD is 416 ns
vs scalar 166 ns, a regression. But the *amortized* cost across
the batch is what wins: 15166 / 256 = 59 ns/input for SIMD vs
98208 / 256 = 383 ns/input for scalar.

This is the **fourth case where engineering by wallet replaced
a paper estimate with a measured number, and the second case
where the paper estimate was wrong in a *useful* direction**
(the first being Metal Hamming with the crossover prediction
within 13%). The scoping doc's prediction "this might not help"
was qualitatively right at the smallest batch sizes and
quantitatively wrong about whether the batch-amortized regime
would be faster. The wallet says: batch-amortized is faster,
in both languages, by a wide margin.

### Open questions resolved

OQ #1 (Hyperplane SoA layout): resolved in favor of
"PackedFamily lives in the SIMD kernel module, built per-call
from the canonical AoS HyperplaneFamily." Per-batch
construction cost is amortizable; no need to change
`HyperplaneFamily` itself.

OQ #2 (Cross-block parallelism): not relevant for
`simhashBlockBatch` which processes one family at a time. The
full-fingerprint `simhashCompute` could parallelize across 4
families but stays scalar at bs=1 anyway.

OQ #4 (Stress-test result): filled in above.

### Disposition

Dispatcher returns `SimdKernel` on aarch64 for
`simhashBlockBatch`. `simhashCompute` continues to use the
scalar inherited path for hot-path row-capture latency. Phase
2.γ-2 (BnnsKernel float matmul) will measure whether AMX-via-
BNNS beats the SIMD floor at large batches; the prediction in
the scoping doc was "BNNS might genuinely win for cold-path
bulk regeneration" because the matrix encoding is amortized
across the estate lifetime.

Filed as Phase 2.γ candidate #1.

---

## Phase 2.γ-2 addendum — BnnsKernel SimHash measured rejection

Phase 2.γ-2 implements the Axis 2 "1a" path: pre-encoded ±1/0
Float32 hyperplane matrix cached on `family.canonicalHash()`,
per-call 0/1 Float32 encoding of the input vector, single BNNS
matrix multiply for the full batch, sign() decode. The scoping
doc predicted this might genuinely win for bulk regeneration
because the matrix encoding is amortized across the estate
lifetime (unlike Hamming where the candidate matrix is per-call).

The empirical answer: BNNS SimHash loses to SimdKernel at every
batch size measured, with the gap narrowing from 8.8x at bs=1
to 3.7x at bs=256, but never crossing the SIMD baseline. The
paper estimate was *qualitatively wrong* about whether BNNS
would win; quantitatively, the asymptotic per-input slope is
favorable to BNNS but never catches up at the batch sizes the
harness measures.

### Implementation

`BnnsKernel.simhashBlockBatch` added. The path:

1. **Cache check**: `SimhashMatrixCache.matrix(for: family)`
   returns the cached `EncodedHyperplaneMatrix`, or builds one
   if absent. Keyed on `family.canonicalHash()`. Reference-type
   cache with `os_unfair_lock` guard; build-outside-lock pattern
   to keep the critical section short.
2. **Matrix encoding** (one-time per family lifetime): scan the
   family's 64 planes; for each plane k, for each bit i in
   `[0, inputBits)`, set `M[k][i]` to +1.0/-1.0/0.0 based on the
   plane's positive/negative masks. Cost: 64 × inputBits scalar
   writes. For block 0 (inputBits=192): 12288 writes; for blocks
   1-3 (inputBits=64): 4096 writes each.
3. **Per-call input encoding**: heap-allocate [N, inputBits]
   float buffer. Expand each input vector's bits as 0.0/1.0
   Float32. Cost: N × inputBits scalar writes per call.
4. **BNNS matmul**: single `applyMatrixMultiplication` call
   with shape `matrixRowMajor(inputBits, n)` ×
   `matrixRowMajor(inputBits, 64)` (B transposed) → output
   `matrixRowMajor(64, n)`.
5. **Decode**: for each row, set bit k iff `output[row*64 + k] > 0`
   (strict, to match scalar `Hyperplane.sign` tie-break
   semantics).

Falls through to scalar `SimHash.block` per-input on any BNNS
failure. `SubstrateKernel: Sendable` conformance maintained via
`@unchecked Sendable` on the cache class with documented lock
discipline.

Conformance passes byte-identical to scalar (CRC `0xddd18e12`),
including the strict positive sign-bit (anything `> 0` sets the
bit, ties resolve to false matching the scalar contract).

### Measurement (apple-m5-max, 2026-05-18, commit pending)

`simhash_block_batch`, batched mode, Swift:

| Batch | Scalar | SimdKernel | BnnsKernel | BnnsKernel vs SimdKernel |
|---:|---:|---:|---:|---:|
| 1   | 166 ns    | 416 ns    | 3666 ns   | 8.81x slower |
| 2   | 333 ns    | 500 ns    | 4792 ns   | 9.58x slower |
| 4   | 833 ns    | 625 ns    | 5125 ns   | 8.20x slower |
| 8   | 2166 ns   | 875 ns    | 5750 ns   | 6.57x slower |
| 16  | 4875 ns   | 1291 ns   | 7041 ns   | 5.45x slower |
| 32  | 10791 ns  | 2250 ns   | 10125 ns  | 4.50x slower |
| 64  | 23500 ns  | 4083 ns   | 16209 ns  | 3.97x slower |
| 128 | 48500 ns  | 7791 ns   | 28291 ns  | 3.63x slower |
| 256 | 98208 ns  | 15166 ns  | 56208 ns  | 3.71x slower |

BnnsKernel beats scalar above bs=32 (10125 ns vs 10791 ns) and
the gap widens with batch size. So the BNNS path is genuinely
faster than the un-vectorized scalar baseline; it just doesn't
beat the explicit SimdKernel path that Phase 2.γ-1 introduced.

### Per-input cost breakdown

Linear regression on the bs >= 32 portion of the measured data
(where the per-call setup is amortized):

- SimdKernel:   ~58.7 ns/input + ~250 ns one-time PackedFamily build
- BnnsKernel:   ~219 ns/input + ~3500 ns one-time BNNS dispatch floor
- Scalar:       ~382 ns/input + ~0 ns setup

BnnsKernel's per-input slope (219 ns) is 3.7x SimdKernel's
(58.7 ns). The BNNS dispatch floor is about 14x SimdKernel's
PackedFamily build cost. Both contribute; neither alone
explains the full gap.

Projected crossover (where would SimdKernel and BnnsKernel
meet?):

```
58.7 * N + 250 = 219 * N + 3500
160.3 * N = -3250
N < 0
```

There is no positive crossover. BnnsKernel is asymptotically
slower per input AND has a higher fixed setup cost. SimdKernel
wins at every batch size.

### Why BNNS lost the structural-advantage case

The scoping doc's argument for BNNS was: "the hyperplane matrix
is manifest-immutable; pre-encode once and amortize forever."
That argument is empirically true — the cache works, the
encoded matrix lives across calls, the per-call cost has no
matrix-encoding term. So why doesn't BNNS win?

Three empirical observations:

**(1) Per-call input encoding is still expensive.** N × 192
float writes for block 0 dominates the per-call cost. At
N=256, that's 49152 writes, vs SimdKernel which reads 256 × 3
= 768 UInt64 values and writes 256 UInt64 results. BNNS does
64x more memory work per input on the read side.

**(2) BNNS matmul on small-N, narrow-M shapes is not its
sweet spot.** The matmul shape is [N, 192] × [192, 64]. AMX
throughput peaks on shapes with large outer dimensions; here
the inner dimension (192) is small enough that the matmul
doesn't fill AMX's pipeline. The Apple AMX documentation and
the philipturner amx-benchmarks repo both indicate that AMX
starts to dominate around inner dimensions of 512+ and outer
dimensions of 1024+. SimHash's 192 inner dimension is
structurally below the AMX sweet spot.

**(3) The dispatch floor itself is ~3500 ns even with the
matrix cached.** The measurement at bs=1 (one input, 192
floats encoded, 64 floats decoded) is 3666 ns. Subtracting
the encode + decode (~150 ns generously), the BNNS framework
overhead is ~3500 ns. That's the per-call cost of descriptor
creation + AMX setup + result barrier + descriptor teardown.
It's smaller than MetalKernel's ~70 µs dispatch floor by 20x
but still 5-6x larger than what SimdKernel does in total at
bs=8.

### Why the slope narrows with batch size

The BnnsKernel vs SimdKernel ratio drops from 8.8x at bs=1 to
3.7x at bs=256. This is the fixed-cost amortization: as N
grows, the ~3500 ns BNNS dispatch floor spreads across more
inputs. At bs=256: 3500 / 256 = 13.7 ns/input fixed component.
The variable component (per-input encode + matmul work) is
~219 ns/input. So the ratio asymptotically converges toward
219 / 59 ≈ 3.7. The measured 3.7x at bs=256 is essentially
the asymptotic floor; pushing bs higher won't help.

### Methodology takeaway

This is the **fifth confirmed engineering-by-wallet case**.
The scoping doc's argument was structurally correct: the
matrix-encoding cost is amortized successfully via the cache.
But the *consequence* ("BNNS might genuinely win for bulk
regeneration") was empirically wrong, in a way the paper
analysis could not have predicted without measuring the per-
call encode-and-dispatch overhead on apple-m5-max specifically.

Updated tally:

- Phase 2.α-4 BNNS or_reduce: paper said "slow due to 8x";
  measured 192x slower (also API gap)
- Phase 2.β-2(a) NeonKernel: paper said "Mula NEON wins";
  measured 193x slower (Swift gap)
- Phase 2.β-2(b) BnnsKernel Hamming: paper said "slow at
  typical batches"; measured 68x slower (encode cost)
- Phase 2.β-2(c) MetalKernel: paper said "crossover 100K";
  measured 87.5K (within 13%) — **paper right**
- Phase 2.γ-1 SimdKernel SimHash: paper said "might not help";
  measured 6.5x faster — **paper wrong in useful direction**
- Phase 2.γ-2 BnnsKernel SimHash (this case): paper said
  "might genuinely win for bulk"; measured 3.7x slower at
  bs=256, no positive crossover — **paper wrong in useful
  direction**

The pattern remains consistent: paper analyses tend to
over-trust the *architectural* case for accelerator backends
while under-counting the dispatch and encoding costs on the
actual silicon. The measurement is always cheaper than the
later operational surprise.

### Open questions resolved

OQ #3 (BNNS matrix pre-encoding lifetime): resolved in favor
of (b) — the kernel caches per-family-hash internally with
`SimhashMatrixCache`. The trait did not need to change; the
cache is a kernel implementation detail. Concurrent access is
guarded by `os_unfair_lock` with a build-outside-lock pattern.

OQ #6 (AMX contention): not measured in this phase; the
measurement was on a quiet machine. The BnnsKernel SimHash
result here is the *best case* for BNNS, with no AMX
contention from LocalNLM. Under LocalNLM load, expect
further regression. Filed for future investigation if BNNS
SimHash becomes interesting for any other reason.

### Disposition

Dispatcher continues to return `SimdKernel` on aarch64 for
`simhashBlockBatch` at all batch sizes. `BnnsKernel`'s
SimHash override stays in the repository as the canonical
example of "AMX-via-BNNS structurally cannot win this shape
on this hardware," reachable via `--kernel bnns` for future
re-benchmarking when:

- A future Apple Silicon generation may have a different AMX
  dispatch floor or different small-N matmul behavior.
- The cookbook may add SimHash variants with larger inner
  dimensions (currently 192 for block 0, 64 for blocks 1-3)
  that move into AMX's sweet spot.
- The dreaming-daemon batch index-build pass may add scenarios
  where the per-call BNNS dispatch is amortized across
  thousands of calls in a tight loop (not measured here).

Filed as Phase 2.γ candidate #2 (of three total). Phase 2.γ-3
is the conditional MetalKernel SimHash; given the ~70 µs Metal
dispatch floor from Phase 2.β-2(c), Metal SimHash would need
N >= ~1200 inputs to begin amortizing its dispatch against
SimdKernel's 59 ns/input slope. Likely not worth implementing
for the row-capture hot path. Decision deferred to Phase 2.δ
or the dreaming-daemon batch index work.

---

## Phase 2.γ-3 disposition — MetalKernel SimHash declined

Phase 2.γ-3 (MetalKernel SimHash) was conditional per the
scoping plan: implement only if Phase 2.γ-1 and 2.γ-2 do not
settle the question. They do. The Metal candidate is declined
on architectural grounds rather than implemented-and-rejected,
representing the first time in Phase 2 we've stopped short of
measurement.

Two reasons:

**(1) The architectural math forbids a positive crossover at
harness-measurable batch sizes.** From Phase 2.β-2(c) the Metal
dispatch floor on apple-m5-max is ~70 µs. SimdKernel SimHash
slope from Phase 2.γ-1 is ~59 ns per input. The crossover:

```
70000 ns = N × 59 ns/input
N ≈ 1186 inputs
```

The harness sweep tops out at bs=256, four times below the
crossover. Even extending the sweep to N=10K, MetalKernel
would need to beat SimdKernel's roughly 590 µs per 10K-batch.
Metal's actual per-input compute cost (a 64-plane signed
popcount + bit assembly) is sub-nanosecond per input on the GPU
but adds to the 70 µs floor. So at N=10K, Metal would land
around 80 µs and SimdKernel around 590 µs, and Metal would
finally win by ~7x.

That regime exists for the dreaming-daemon batch index-build
pass (cookbook §15.4) but does NOT exist for any other
documented caller. The row-capture hot path is
`simhashCompute` at bs=1, where Metal's 70 µs floor is
400-700x slower than scalar.

**(2) No Metal SimHash shader exists.** Phase 2.β-2(c) had a
structural advantage: a Metal Hamming-NN compute shader already
existed with a header claim about the crossover, and the
host-side work was just Swift plumbing.
For SimHash, no compute shader exists. Building one requires:

- Encoding the HyperplaneFamily as a Metal constant buffer
  matching some layout convention.
- Implementing per-thread vertical popcount over 64 planes,
  signed compare, bit-set assembly into the 64-bit output.
- Dealing with the 64-bit output (Metal's natural types are
  32-bit; the kernel needs careful uint2 packing).
- A separate kernel for each block index (since inputBits is
  192 for block 0 and 64 for blocks 1-3).

This is a real engineering project, not a thin host wrapper.
The engineering-by-wallet protocol requires implementing
candidates when the paper estimate is uncertain; here the math
is arithmetic, not paper estimate, and the architectural
reason for the floor (command-buffer creation + AMX/GPU
setup + result barrier + buffer release) is the same
empirical 70 µs that Phase 2.β-2(c) measured.

### Filing for future work

MetalKernel SimHash is filed under Phase 2.δ (future kernel
specializations) with two trigger conditions:

- **The dreaming-daemon batch index-build pass becomes a real
  workload** (cookbook §15.4). In that regime, batch sizes are
  10K-1M per call and the Metal crossover lands cleanly. A new
  decision record will scope the shader, the host code, and
  the integration with the daemon's existing batch boundary.
- **A future Apple Silicon generation reduces the Metal
  dispatch floor materially.** If a future M-series chip cuts
  the 70 µs floor to <10 µs, the crossover drops to N ≈ 170,
  inside the row-capture batch-bound range, and Metal SimHash
  becomes interesting for routine hot-path work. Re-measure on
  any new Apple Silicon generation.

### Methodology takeaway

This is the first Phase 2 candidate **declined without
measurement**. The decision is defensible because:

- The architectural math is arithmetic (Metal floor measured
  in Phase 2.β-2(c), SimdKernel slope measured in Phase 2.γ-1),
  not paper estimate.
- The implementation effort is substantial (new shader, not
  just host wrapper) and would burn time better spent on Phase
  2.δ work.
- The disposition is conditional rather than terminal: when
  the trigger conditions appear, the decision will be revisited
  with measurement.

The engineering-by-wallet protocol's principle is "measure
before deciding" — not "measure everything regardless of
cost." Phase 2.γ-3 represents the case where the cost of
measurement exceeds the expected value of the measurement, and
the protocol explicitly accommodates that by allowing
architectural-floor calculations as substitutes for full
measurement when the floor is itself measured and the slope is
also measured.

Filed as Phase 2.γ candidate #3, declined.

---

## Status

Accepted. SimdKernel SimHash override (Phase 2.γ-1) ships as the
aarch64 default. BnnsKernel SimHash (Phase 2.γ-2) retained as
measurement evidence and reachable via `--kernel bnns`. Metal-
Kernel SimHash (Phase 2.γ-3) declined; revisit with the
dreaming-daemon batch index-build pass or a future hardware
generation.

Phase 2.γ closes. Phase 2 dispatch architecture is complete
across all three primitives:

| Op | aarch64 default | Other candidates retained |
|---|---|---|
| or_reduce_256 | SimdKernel (23.3x Swift, 2.2x Rust vs scalar) | BnnsKernel (reachable, 192x slower) |
| hamming_distance_batch | SimdKernel (1.0x Swift, 1.5x Rust) | BnnsKernel, NeonKernel, MetalKernel (crossover at N≈87.5K) |
| simhash_block_batch | SimdKernel (6.5x Swift, 2.1x Rust) | BnnsKernel (asymptotic 3.7x slower) |

Phase 2.δ candidate set, to be scoped in a future decision
record:

- AVX-512 / AVX-2 kernel specializations (currently fall
  through to scalar on x86_64)
- Bit-slice runtime layout per cookbook §4.1 (changes the
  hammingDistanceBatch inner-loop shape, separate decision)
- Branchless top-K maintenance via corsix SMIN/SMAX ladder
  (cookbook §11.2 follow-up)
- Pre-encoded float-matrix variant for dreaming-daemon batch
  index-build pass at large N (cookbook §15.4)
- Cached-pipeline / persistent-buffer architecture for Metal
  dispatch-floor reduction
- Phase 2.γ-3 MetalKernel SimHash if dreaming-daemon batch
  workload materializes or Metal floor improves on future
  hardware

---

## BNNSGraph disposal addendum — 2026-06-06

**Hardware:** apple-m5-max. **OS:** macOS 26.5 (build 25F71).
**Build:** release. **Methodology:** min-of-5 runs after 2 warmups.

A later effort migrated BnnsKernel off the deprecated
`BNNS.applyMatrixMultiplication` API to the BNNSGraph API and measured
whether the simhashBlockBatch path improved. It did not.

simhashBlockBatch measured results (ns/op, lower is better):

| N | ScalarKernel | SimdKernel | BnnsKernel |
|---|---|---|---|
| 1k | 407.46 | 75.67 | 626.12 |
| 10k | 412.27 | 78.99 | 643.41 |
| 100k | 414.34 | 78.61 | 654.44 |

BnnsKernel is 8x to 8.3x slower than SimdKernel at every measured N.
This is consistent with the Phase 2.γ-2 rejection (3.7x slower vs
scalar at that time, with the new BNNSGraph path being no improvement).
Note also that BNNSGraph matmul with two dynamic inputs crashes on
macOS 26.5 build 25F71 (EXC_BREAKPOINT in `_bnns_graph_builder_finalize`,
libBNNS.dylib, Apple framework bug), which affects the hamming path and
would affect any matrix-multiply-based simhash variant.

SimdKernel remains the selected default. No change to the dispatcher.

BnnsKernel was removed from the source tree on 2026-06-06. It is 8x
slower than SimdKernel on simhashBlockBatch, its BNNSGraph matmul is
unusable on current macOS, and a non-dispatched kernel violates the
standing rule to remove unused code. The Phase 2.γ-2 investigation and
these measurements are the permanent record of why BNNS was tried and
rejected.
