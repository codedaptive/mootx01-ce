# Accelerator Scope — NEON, AVX, Metal

Scoping doc for Path 4 (kernel accelerator backends) on the
GeniusLocus reference substrate. Reads the existing scalar
KernelBackend trait, the cookbook §4.4 priority order, and the
§4.5 / §17 bandwidth budgets, then evaluates the three
accelerator tracks against feasibility, expected win, and risk.

This doc is **scope-only**. Implementation work follows in a
later session after a track is chosen. The accelerator that
lands first should be the one where the dev loop is tightest
and the conformance gate is unambiguous.

---

## §1. What we already have

The portable kernel layer is **structurally complete**. The trait
is defined in both Swift (`glref-swift-PortableKernel.swift`) and
Rust (`glref-rust-kernel.rs`); the scalar reference passes the
existing conformance gate; runtime dispatch goes through
`PortableKernel.for_current_platform()` or explicit
`PortableKernel.of_kind(.neon | .avx512 | .avx2 | .scalar)`.

**KernelBackend surface** (cookbook §4.4):

| Op | Signature (Rust) | Bandwidth shape | Workload class |
|---|---|---|---|
| `popcount64` | `fn(u64) -> u32` | trivially scalar | hot path, called per block |
| `hamming_distance_256` | `fn(&Fingerprint256, &Fingerprint256) -> u32` | 32-byte XOR + 4× popcount | hot path, primary Hamming-NN inner loop |
| `or_reduce_256` | `fn(&[Fingerprint256]) -> Fingerprint256` | linear scan, 32 bytes / item | cold path (temporal compression, tier contribution), but bandwidth dominates |
| `hamming_top_k` | `fn(probe, candidates, k) -> Vec<(idx, dist)>` | N × `hamming_distance_256` + heap | hot path, every `recall_similar_moments` query |
| `simhash_block` | `fn(&[u64], &HyperplaneFamily) -> u64` | 64× (mask + popcount) per block | hot path, every `capture` rebuilds 4 blocks |

The scalar reference produces bit-identical output on the 18
committed test vectors. Any accelerator backend must produce the
same CRCs against the same vectors. The harness already supports
this: `PrimitiveDescriptor` doesn't care which backend produced
the output; the conformance gate is byte equality.

**What's missing for any accelerator track**: per-kernel overlay
files, runtime CPU feature detection beyond the current trivial
`for_current_platform()` stub, and per-accelerator conformance
gating in CI.

---

## §2. Bandwidth math (the win we're chasing)

Per cookbook §17.5: Apple Silicon M-series carries roughly
60 GB/s of LPDDR5 bandwidth. A 1M-row Hamming-NN scan touches
~32 MB of fingerprint data, so the **theoretical floor is
~530 µs** at peak bandwidth. The scalar reference, per current
measurements, does not reach that floor; the inner loop is
compute-bound on popcount even though the architectural ceiling
is bandwidth-bound.

The point of accelerators is not to add arithmetic — the popcount
is already O(1) per word — but to **process more words per cycle**
so the inner loop becomes bandwidth-bound, where it should be.

Expected speedup factor per accelerator on the dominant op
(`hamming_distance_256`, which is 4× 64-bit XOR + popcount):

| Backend | Vector width | Theoretical speedup vs scalar | Real expected |
|---|---|---|---|
| NEON (128-bit) | 2× u64 lanes | 2× | 1.5-2× (loop overhead) |
| AVX2 (256-bit) | 4× u64 lanes | 4× | 2.5-3.5× |
| AVX-512 (512-bit) | 8× u64 lanes + VPOPCNTQ | 8× | 5-7× |
| Metal (GPU) | thousands of lanes | huge for batched | only profitable at ≥ 10k candidate scans |

OR-reduce_256 and simhash_block both benefit similarly. The win
is real but bounded by the bandwidth ceiling — past 2-3× the
scalar throughput, we're limited by LPDDR5, not the kernel.

---

## §3. Track A — NEON

**Target**: Apple Silicon (M-series and A-series), ARM Linux
servers, iOS/iPadOS devices.

**Reach**: Largest of the three tracks. Covers Bob's primary
hardware, the Codedaptive deployment surface, every iOS device
the substrate will ever run on, and AWS Graviton.

### §3.1. Implementation surface

NEON is ARMv8 standard SIMD, 128-bit registers. The relevant
intrinsics for our ops:

| Op | NEON intrinsic | Notes |
|---|---|---|
| 128-bit XOR | `veorq_u64` | two u64s per instruction |
| 128-bit OR | `vorrq_u64` | for or_reduce_256 |
| 128-bit AND | `vandq_u64` | for simhash_block masks |
| popcount per byte | `vcntq_u8` | counts ones per byte, 16 bytes per call |
| horizontal byte-sum | `vaddvq_u8` | sums the 16 bytes into one u8 (returns u8) |

`hamming_distance_256` becomes: 2× (XOR + vcntq_u8 + vaddvq_u8)
to cover the 32 bytes. About 6 instructions vs the scalar's 8
(4× XOR + 4× popcount). The win is modest per-call but compounds
over the inner loop of `hamming_top_k`.

Apple Silicon adds Apple AMX for matrix work, but our ops are not
matrix-shaped. NEON is the right level.

### §3.2. Dev loop

Bob's hardware is Apple Silicon. Build, run, profile, all local.
Conformance runs in seconds against the existing 18 vectors. CI
already runs on `macos-14` (Apple Silicon) for the harness, so
the NEON path gets covered there for free; ARM Linux coverage
needs a Graviton or QEMU job (the existing CI has an aarch64
QEMU step marked `continue-on-error: true`).

### §3.3. Code layout

Rust: a new module `kernel_neon.rs` gated by
`#[cfg(target_arch = "aarch64")]`. The module exposes
`pub struct NeonKernel;` implementing `SubstrateKernel`. The
`PortableKernel::for_current_platform()` returns `Box<NeonKernel>`
when the target arch and feature detection align.

Swift: NEON intrinsics are not directly exposed in Swift; the
standard path is **Accelerate.framework** for popcount-like
operations (`vDSP_distancesq_*`, `vImagePopCount_PlanarU8`),
or call into a C/Objective-C bridge that uses `<arm_neon.h>`.
For Hamming over fixed 32-byte fingerprints, Accelerate is
overkill; a thin C bridge is the cleanest path.

### §3.4. Risk

Low. The intrinsic surface is small, well-documented, and well-
exercised by the broader ecosystem. The conformance gate is byte
equality, so floating-point reorderings (a common SIMD risk) do
not apply — these are integer ops.

The one real risk: ARM Linux machines on cross-toolchain runners
may differ from Apple Silicon in subtle ways (`libm` is a separate
concern but doesn't apply here since the ops are integer). CI
should validate both.

### §3.5. Sequence (if NEON ships first)

1. Add `NeonKernel` skeleton to the Rust crate, implements trait
   with scalar fallback inside each method.
2. Replace `hamming_distance_256` body with NEON. Run conformance
   sweep: must produce the same CRCs.
3. Replace `or_reduce_256`, `simhash_block`, `popcount64`,
   `hamming_top_k` in that order. Conformance after each.
4. Add `cfg`-gated Swift NEON path via a C bridge under the
   Swift package's `Sources/CGeniusLocusNEON/`.
5. Wire `PortableKernel::for_current_platform()` to return
   `NeonKernel` on aarch64 (Rust) and use the C bridge on Apple
   Silicon Swift builds.
6. Add a per-backend CI job that runs the same 18 conformance
   vectors with `KernelKind::Neon` explicitly selected.
7. Benchmark microbenchmarks for each op against the scalar
   reference; publish ratio in the catalog.

Estimated effort: 1-2 sessions for Rust, +1 for Swift, +1 for CI
and benchmarks. Total ~4 sessions.

---

## §4. Track B — AVX (AVX2 + AVX-512)

**Target**: x86_64 Linux servers, Windows desktops, Intel/AMD Macs
(EOL but still in the wild).

**Reach**: Server-side deployments, CI runners, and any user not
on Apple Silicon. The fleet/MSP deployment paths for case 2 and
case 3 may eventually land here.

### §4.1. Implementation surface

AVX2 (256-bit) and AVX-512 (512-bit) are both relevant. The win
escalates: AVX2 processes 4 u64s per instruction, AVX-512 does 8
and adds VPOPCNTQ for direct vectorized popcount (the killer
feature for Hamming-NN).

| Op | AVX2 intrinsic | AVX-512 intrinsic | Notes |
|---|---|---|---|
| 256-bit XOR | `_mm256_xor_si256` | `_mm512_xor_si512` | |
| popcount per u64 | (none direct, manual sum-of-bytes) | `_mm512_popcnt_epi64` (VPOPCNTQ) | AVX-512 makes this trivial |
| OR-reduce | `_mm256_or_si256` | `_mm512_or_si512` | |

AVX2 needs a popcount-by-byte trick (PSHUFB lookup table) since
direct popcount per lane was only added with AVX-512 BITALG.
AVX2 with this trick yields ~3× scalar; AVX-512 with VPOPCNTQ
yields ~5-7×.

### §4.2. Dev loop

**Bob has no local x86_64 hardware**. CI is the only test surface.
Implementation goes blind in the sense that bugs land in CI runs,
not in a local REPL. The conformance gate is still byte equality,
so correctness is verifiable from CI logs.

Mitigation: a local x86_64 VM via UTM or a remote runner via
Tailscale to a Linux x86_64 box would tighten the loop. Without
one, AVX is a "land it, watch CI" workflow.

### §4.3. Code layout

Rust: `kernel_avx2.rs` and `kernel_avx512.rs`, both gated by
`#[cfg(target_arch = "x86_64")]`. Runtime selection by
`std::is_x86_feature_detected!` checks at construction time.

Swift: x86_64 Swift on macOS Intel is a shrinking surface; Swift
on Linux x86_64 is possible but not a current target. AVX support
in Swift goes through C bridges identical to NEON's setup; the
work is structurally the same as NEON's Swift bridge but with
different intrinsics.

### §4.4. Risk

Medium. The intrinsic surface is larger than NEON, the popcount
trick for AVX2 is more involved, and the dev loop is slower. The
absence of local hardware means more debugging-via-CI cycles.

Conformance risk: same low risk as NEON — integer ops, byte
equality gate.

### §4.5. Sequence (if AVX ships first)

1. AVX-512 first (cleanest implementation with VPOPCNTQ).
   Skeleton, then `hamming_distance_256`, then conformance check
   via CI on an AVX-512 runner (some GitHub runners support it;
   need to verify which).
2. Replace remaining ops in the AVX-512 backend. Conformance gate
   after each.
3. AVX2 second, using PSHUFB popcount trick. Cross-validate against
   AVX-512 CRCs.
4. Runtime feature detection and dispatch in
   `PortableKernel::for_current_platform()`.
5. CI matrix expansion: AVX2-only runner, AVX-512 runner.

Estimated effort: 2-3 sessions for AVX-512, +2 for AVX2, +1 for CI
matrix. Total ~5-6 sessions.

---

## §5. Track C — Metal

**Target**: Apple Silicon GPUs (M-series and A-series).

**Reach**: Only Apple Silicon, only when the workload is large
enough to amortize GPU dispatch overhead. Not relevant on ARM
Linux, not relevant on x86_64.

### §5.1. Implementation surface

Metal compute shaders for **batched Hamming-NN** (the only op
where GPU offload makes sense). The other ops are too small to
clear the dispatch overhead.

| Op | GPU-suitable? | Why |
|---|---|---|
| `popcount64` | No | Single u64; dispatch dwarfs work |
| `hamming_distance_256` | Maybe batched | Single pair too small; batched yes |
| `or_reduce_256` | Maybe batched | Same reasoning |
| `hamming_top_k` (N candidates) | **Yes** when N ≥ ~10k | Big batched XOR-popcount + heap |
| `simhash_block` | Maybe batched | Single block too small; batched at capture time, yes |

### §5.2. Dev loop

Apple Silicon required. Local for Bob. Metal compiler is in Xcode;
the Swift API is straightforward (`MTLDevice`, `MTLBuffer`,
`MTLComputeCommandEncoder`). Rust bridging is awkward; either
`metal-rs` crate (mature) or a Swift bridge.

### §5.3. Code layout

Swift: a new `MetalKernel.swift` under
`Sources/GeniusLocusReference/`. Shader source in
`Resources/Kernel.metal`. The kernel only implements
`hamming_top_k` (and the other ops fall through to NEON/scalar).

Rust: `metal-rs`-based `kernel_metal.rs`, gated by
`#[cfg(all(target_os = "macos", target_arch = "aarch64"))]`. Same
fall-through pattern.

### §5.4. Risk

Higher than NEON, lower than AVX (because the dev loop is local).
The risks are different:

- **Determinism risk**: GPU floating-point math is allowed to
  reorder in some modes. Our ops are integer, so this should not
  bite, but care needed.
- **Dispatch overhead**: if the heuristic for "batch big enough
  for GPU" is wrong, GPU path is slower than CPU. Need
  benchmarking to pick the threshold.
- **Memory transfer**: candidate fingerprints must be in a
  `MTLBuffer`. If the substrate keeps them mmap'd in CPU memory,
  there's a copy. Unified memory on Apple Silicon mitigates but
  doesn't eliminate this.

### §5.5. Sequence (if Metal ships first)

1. Build a Metal shader for batched `hamming_top_k` over a fixed
   candidate buffer. Validate against scalar conformance on a
   1000-candidate vector case.
2. Wire `MetalKernel.hammingTopK` into the Swift kernel. Other
   ops fall through to scalar (or NEON if it ships first).
3. Benchmark the dispatch-overhead break-even point. Encode the
   threshold in `PortableKernel.kernelForCurrentPlatform()` so
   small queries use CPU and big queries use GPU.
4. Rust side via `metal-rs`. Same scalar fall-through pattern.
5. CI: only macos-14 runner can test Metal; add a job that
   exercises `KernelKind::Metal` with synthetic large cases.

Estimated effort: 2-3 sessions for Swift Metal, +2 for Rust
metal-rs, +1 for benchmarks and CI. Total ~5-6 sessions.

---

## §6. Cross-track architecture decisions

Whichever track ships first, these decisions need to be made
once and apply to all three:

### §6.1. Where do per-backend overlays live?

Two options:

**A. Inside the existing reference crate**:
`substrate_reference/rust/glref-rust-kernel-neon.rs` (etc.)
gated by `#[cfg]`. The reference crate stays a single crate;
build profiles select which backends compile in.

**B. Sibling crates**: `geniuslocus-kernels-neon`,
`geniuslocus-kernels-avx`, `geniuslocus-kernels-metal`. The
reference crate depends on these via optional dependencies. Each
sibling can be tested in isolation; consumers pick which to link.

**Recommendation**: **A** for the first accelerator. The trait is
already in the reference crate; splitting now buys little. If a
later accelerator drags in heavy dependencies (Metal's
`metal-rs`, for example), promote it to its own crate then.

Swift: the analogous question is whether NEON/Metal live in the
same Swift package or in sibling packages. Swift packages don't
have optional-dependency discipline the way Cargo does; single
package with conditional compilation is the right answer.

### §6.2. How is the active backend chosen at runtime?

Cookbook §4.4 specifies the priority order (AMX > SVE > NEON >
AVX-512 > AVX2 > scalar). The current
`PortableKernel::for_current_platform()` is a stub. It needs to:

1. Detect target architecture at compile time.
2. Detect CPU features at runtime (e.g.
   `std::is_x86_feature_detected!("avx512vpopcntdq")`).
3. Return the highest-priority backend that's available.

The harness should expose an env var override (e.g.
`GENIUSLOCUS_KERNEL=scalar`) for forcing a specific backend in
CI and benchmarks. This is small surface; one function on each
side.

### §6.3. How do we benchmark the win?

Microbenchmarks per op, comparing the active backend to the
scalar reference, on a fixed input set (the harness can produce
these from the existing test vectors). Results published in
`primitive-catalog.md` alongside the CRC.

Two benchmark frameworks:
- Rust: `criterion` is the standard.
- Swift: `XCTest` with `measure(metrics:)` or a simple
  hand-rolled timer over a fixed-iteration loop.

This is one session of work once the first accelerator lands.

### §6.4. How does conformance gate the accelerator?

The existing test vector harness is the gate. For each
accelerator backend, run the full 18-primitive sweep with that
backend explicitly selected; all 18 CRCs must match the
scalar-generated vectors.

Concretely, a new CI job per backend:
```sh
GENIUSLOCUS_KERNEL=neon \
  cargo run --release --bin validate-vectors -- \
    docs/validation/substrate_math_performance/test-harness/vectors/*.json
```

The matrix expands from 4 cells (Swift gen × Rust gen × Swift
validate × Rust validate, all scalar) to 4 × (1 + N_accelerators)
cells. For each accelerator the validate-side runs the
accelerated kernel and confirms CRC equality.

---

## §7. Comparison table — pick a track

| Axis | NEON | AVX | Metal |
|---|---|---|---|
| Local dev hardware | ✓ (Apple Silicon) | ✗ (no x86_64 box) | ✓ (Apple Silicon) |
| Reach | Apple Silicon + ARM Linux + iOS | x86_64 Linux + Windows + Intel Mac | Apple Silicon only |
| Expected speedup | 1.5-2× | 3-7× | 10-100× on batched, but only for big batches |
| Implementation surface | Small (few intrinsics) | Medium (AVX2 popcount trick) | Medium-large (shaders + dispatch) |
| Dev loop tightness | Tightest | Slowest (blind via CI) | Local but slower than CPU |
| Conformance risk | Low | Low | Low-medium |
| CI cost | Tiny (existing macos-14 runner) | Medium (new Linux runners) | Tiny (macos-14 runner) |
| Sessions to land | ~4 | ~5-6 | ~5-6 |
| Right answer for Bob's daily-driver | **Yes** | Eventually | Eventually (only for large-N queries) |

### §7.1. Recommendation

**Ship NEON first.** The dev loop is local, the implementation
surface is small, the CI cost is zero (existing macos-14 runner
covers it), and it's the only track that improves Bob's primary
development hardware. AVX and Metal both depend on architecture
decisions (where backends live, runtime dispatch, benchmark
discipline) that NEON forces us to make first. Once NEON is in
and proven, AVX and Metal follow the same pattern.

**Ship Metal second**, gated on a real workload that exceeds the
GPU dispatch break-even (which won't happen until estate sizes
push past ~10k candidate scans on real data). If Apple Silicon
remains the only deployment target through 2026, Metal is
optional infrastructure — nice to have, not required.

**Ship AVX third**, when there's a Linux x86_64 deployment with
real workload. Until then it's CI-only validation work with no
runtime users.

---

## §8. Out of scope for this doc

- Apple AMX (matrix coprocessor): cookbook §4.4 lists it first
  in the priority order, but our ops are not matrix-shaped. AMX
  would only matter for batched fingerprint computation across
  many rows, which the substrate doesn't currently expose as a
  separate primitive. Deferred indefinitely.
- ARM SVE/SVE2: ARMv9 vector-length-agnostic SIMD. Sun-server-
  class hardware mostly; not a current deployment target. Cookbook
  §4.4 lists it ahead of NEON in the priority order, but the
  realistic ordering on Apple Silicon (which is ARMv8.5/ARMv9 with
  no SVE) is NEON. Defer to whenever ARM Linux on SVE-capable
  hardware becomes a deployment target.
- WASM SIMD: relevant for browser-resident substrate. Out of scope
  for v0.36 entirely.

---

## §9. Decision record promotion

Once a track is chosen, this scope's recommendation becomes a
decision record under `docs/decisions/`. The DR captures:

- Chosen track and reason
- Implementation sequence (the §3.5 / §4.5 / §5.5 list)
- Conformance gate definition (which backend at which CI job)
- Benchmark methodology and acceptance criteria
- Out-of-scope items deferred at decision time

Until promoted, this scope is reference material. The actual
implementation work waits on the decision.
