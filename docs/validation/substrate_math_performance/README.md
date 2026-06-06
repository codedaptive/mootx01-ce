# Substrate reference

This directory holds the substrate's kernel reference
implementation, language ports, GPU shader source, and benchmark
harness. It is the empirical foundation for the cookbook's §4.4
portable kernel layer and §17 performance budgets.

A new engineer (human or agent) joining substrate work reads
this README, the decision index at `../../_internal/decisions/README.md`,
and the Phase 2 final selection at
`../../_internal/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md`,
then is ready to extend the kernel layer with new backends or
new ops.

## Directory layout

```
substrate_math_performance/
├── README.md                              this file
├── AGENT_HOWTO.md                         orientation for agentic
│                                           programming agents
├── SKILL.md                               Claude skill descriptor
├── GeniusLocusReference/                  Swift reference port (library only)
│   ├── Package.swift
│   ├── glref-swift-PortableKernel.swift   trait + dispatcher + KernelKind
│   ├── glref-swift-PortableKernel-SIMD.swift  SimdKernel (production default)
│   ├── glref-swift-PortableKernel-NEON.swift  NeonKernel (retained)
│   ├── glref-swift-PortableKernel-Metal.swift MetalKernel (rejected, retained)
│   ├── glref-swift-HyperplaneFamily.swift
│   ├── glref-swift-SimHash.swift
│   └── ... (reference files)
├── metal/                                 Metal compute shaders
│   └── glref-metal-hamming_nn.metal       (rejected at large N,
│                                           retained; see Phase 2.δ-2)
└── test-harness/                          conformance harness (benchmark
    │                                       sweep not yet ported — see below)
    ├── vectors/                            24 JSON test-vector files
    │                                       (+ locuskit/ subdir, 4 files)
    ├── swift/                              Swift harness (SwiftPM)
    │   ├── Package.swift
    │   ├── Sources/
    │   │   ├── GenVectors/                 generate test vectors from scalar ref
    │   │   ├── ValidateVectors/            validate vectors against any kernel
    │   │   └── Harness/                    shared utilities
    │   └── Tests/
    │       └── HarnessTests/               DispatcherTests + HarnessTests
    ├── rust/                               Rust harness (Cargo; pinned nightly)
    │   ├── Cargo.toml
    │   ├── rust-toolchain.toml             pins nightly-2026-05-16
    │   └── src/bin/
    │       ├── gen_vectors.rs
    │       └── validate_vectors.rs
    └── benchmarks/results/                 gitignored per-run JSON output
        └── {date}-{hw-slug}/               e.g. 2026-05-18-apple-m5-max/
```

The Rust reference port is no longer a single `rust/` tree here. After
the 2026-05-29 four-package refactor it is split across
`packages/libs/SubstrateTypes/rust/` (types: SimHash, Fingerprint256,
HLC, Hamming), `packages/libs/SubstrateKernel/rust/` (kernel dispatch +
SIMD), `packages/libs/SubstrateML/rust/` (ML primitives), and
`packages/libs/SubstrateLib/rust/` (the orchestration layer). The current
constitutional spec is `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md`
(the v0.36 cookbook is archived under `docs/_internal/workhistory/architecture/`).

The benchmark sweep (`stress-test`, `topk-bench`, Rust `stress_test`) is
NOT present in this repo: the `StressTest/` and `TopKBench/` Swift sources
and the Rust `stress_test` bin were not carried over from the prior
`mootx01-rc` tree. Until they are ported, only the conformance binaries
(`gen-vectors`, `validate-vectors`) build and run here. Porting the sweep
is tracked in
`docs/_internal/workhistory/missions/MISSION_PERF_SWEEP_HARNESS.md`.

## What lives where

- **The constitutional spec** is
  `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md`.
  Math first, annotations where needed. The cookbook defines the
  contract; the reference implementations satisfy it. New
  cookbook sections come from upstream design sessions, not from
  kernel work.
- **The trait surface** is `GeniusLocusReference/glref-swift-PortableKernel.swift`
  (Swift) and `rust/glref-rust-kernel.rs` (Rust). Every concrete
  kernel implements this trait. The trait is the API contract;
  the trait extension provides scalar defaults that any kernel
  can override.
- **The dispatcher** is `PortableKernel.kernelForCurrentPlatform()`
  in the same file. As of Phase 2 closure, it returns
  `SimdKernel` on `arch(arm64)` and `ScalarKernel` elsewhere. No
  learned dispatch.
- **Reference kernel implementations** live alongside the trait
  in `glref-{lang}-PortableKernel-{Kernel}.{ext}`. Phase 2
  registered four candidates; three remain after measurement:
  SimdKernel (production), NeonKernel, MetalKernel. BnnsKernel
  was removed 2026-06-06 after BNNSGraph measurement confirmed it
  is slower than SimdKernel on every op (see decision-record
  addenda for the per-op numbers). NeonKernel and MetalKernel are
  retained for benchmarking and conformance gates.
- **Test vectors** in `test-harness/vectors/` are the byte-
  identical conformance fixtures. The Swift scalar reference
  generates them via `gen-vectors`; every other kernel and
  language port validates against them via `validate-vectors`.
  Vectors are committed; their CRCs are the kernel's correctness
  contract.

## How to build and run

### Prerequisites

- macOS 14+ on Apple Silicon (apple-m5-max is the reference
  hardware; older M-series works too; validated on macOS 26)
- Swift 6.0+ toolchain (Xcode 15.4+ or standalone Swift; validated 6.3.2)
- Rust stable 1.75+ toolchain (rustup) for the four substrate crates
- Rust nightly-2026-05-16 toolchain for the test harness: it pulls the
  SIMD kernel via the `simd-nightly` / `portable_simd` feature, which is
  unstable. Install it before building the harness:
  `rustup toolchain install nightly-2026-05-16`. The
  `test-harness/rust/rust-toolchain.toml` then selects it automatically;
  on stable the harness fails with `error[E0554]`.
- For Metal kernel: any Apple Silicon Mac; no extra setup

### Swift reference + harness

If a `.build/` directory was copied from another worktree (a stale module
cache referencing a different absolute path), the first build fails with
`missing required module 'SwiftShims'`. Run `rm -rf .build` first.

```sh
# Reference Swift port (the GeniusLocusReference package — a library, no
# test target, so do not run `swift test` here)
cd docs/validation/substrate_math_performance/GeniusLocusReference
swift build -c release            # compiles to .build/release/

# Harness (depends on the reference package via local path)
cd docs/validation/substrate_math_performance/test-harness/swift
swift build -c release             # compiles gen-vectors and validate-vectors
swift test                         # DispatcherTests + HarnessTests, all pass

# Conformance gate: every kernel passes against every vector
.build/release/validate-vectors ../vectors/hamming.json --kernel scalar
.build/release/validate-vectors ../vectors/hamming.json --kernel simd
.build/release/validate-vectors ../vectors/hamming.json --kernel neon
.build/release/validate-vectors ../vectors/hamming.json --kernel metal
# Each prints CRC expected/actual and PASS or FAIL.
```

The benchmark sweep (`stress-test`, `topk-bench`) is not yet ported to
this repo (see the directory-layout note above and
`MISSION_PERF_SWEEP_HARNESS.md`). The commands below are the intended
interface once those executables land:

```sh
# Benchmark sweep (produces JSON in benchmarks/results/{date}-{hw}/)
.build/release/stress-test                     # full sweep, ~5 minutes
.build/release/stress-test --quick             # 1-minute version
.build/release/stress-test --op hamming        # one op only
.build/release/stress-test --kernel simd       # one kernel only

# Phase 2.δ-1 top-K sweep (sweeps K × N independently)
.build/release/topk-bench --quick              # ~30 seconds
.build/release/topk-bench --n 1024,1048576 --k 10
```

### Rust reference + harness

The Rust reference is the four substrate crates (no single `rust/` tree
under this directory). Each builds on stable Rust:

```sh
# Reference Rust port — four crates (build/test on stable)
cd packages/libs/SubstrateTypes/rust  && cargo build --release && cargo test
cd packages/libs/SubstrateKernel/rust && cargo build --release && cargo test
cd packages/libs/SubstrateML/rust     && cargo build --release && cargo test
cd packages/libs/SubstrateLib/rust    && cargo build --release && cargo test

# Harness — requires the pinned nightly (rust-toolchain.toml selects it
# automatically once nightly-2026-05-16 is installed; see Prerequisites)
cd docs/validation/substrate_math_performance/test-harness/rust
cargo build --release
cargo test

# Conformance mirrors the Swift binaries
./target/release/validate-vectors ../vectors/hamming.json --kernel scalar
./target/release/validate-vectors ../vectors/hamming.json --kernel simd
# (Rust stress_test is part of the not-yet-ported sweep above.)
```

### Regenerating vectors

If the scalar reference changes (rare; only when the cookbook
algorithm changes), regenerate every vector:

```sh
cd docs/validation/substrate_math_performance/test-harness/swift
.build/release/gen-vectors ../vectors/         # overwrites all 24 vectors
```

Every kernel's `validate-vectors` then re-runs and must PASS.
Failure here means a kernel diverged from the scalar reference;
fix the kernel, not the vector.

## Adding a new kernel

The trait surface is stable. To add a new kernel:

1. Create `glref-{lang}-PortableKernel-{Name}.{ext}` next to the
   existing implementations.
2. Declare `struct {Name}Kernel: SubstrateKernel` (Swift) or
   `pub struct {Name}Kernel { ... } impl SubstrateKernel for ...`
   (Rust).
3. Implement `kind`, `popcount64`, and overrides for whichever
   ops the new kernel optimizes. Inherit scalar defaults for
   ops the kernel does not specialize.
4. Add to the kernel registry:
   - Swift: `KernelRegistry.available()` and `KernelSelector.parse()`
   - Rust: equivalent registry function
5. Run `validate-vectors --kernel {name}` against every vector.
   All CRCs must match the scalar reference.
6. Run `stress-test --kernel {name}` and capture the JSON in
   `benchmarks/results/{date}-{hw}/`.
7. Write a decision-doc addendum to the relevant per-op record
   (e.g., `DECISION_HAMMING_BACKENDS_2026-05-17.md`) with the
   measured numbers, the disposition (selected / rejected /
   declined), and the citation to the benchmark JSON.
8. If the kernel becomes the new production default for an op,
   update `kernelForCurrentPlatform()` and the per-op decision
   record's selection table.

The conformance gate is non-negotiable: a kernel that produces
byte-different output from the scalar reference is broken, not
faster.

## Adding a new op

Less frequent. New ops are driven by the cookbook (a new
primitive added to §1.2 P1-P12 or §8 algorithms). To add one:

1. Update the cookbook (separate workstream) with the new
   primitive's pseudocode and conformance fixture.
2. Implement in the Swift scalar reference under
   `GeniusLocusReference/glref-swift-{...}.swift`.
3. Mirror in the Rust scalar reference under
   `rust/glref-rust-{...}.rs`.
4. Add to the `SubstrateKernel` trait with a scalar default in
   the trait extension.
5. Generate test vectors via the Swift scalar reference; commit
   to `test-harness/vectors/{name}.json`.
6. Validate the Rust scalar reference against the Swift-
   generated vectors. CRC must match.
7. Write a per-op decision record using the existing per-op
   records as a template. Run a measurement sweep against every
   existing kernel via the trait's default; document which
   kernels would benefit from an override.

## Hardware tag and reproducibility

Every benchmark JSON file includes the hardware tag and the
commit hash that produced it. Hardware tags are produced by
`Harness.swift`'s `Hardware.tag()` and follow the pattern
`{vendor}-{model}` (e.g., `apple-m5-max`, `apple-m3-pro`).
Decision records cite the hardware tag in measurement tables so
that a future reader on different hardware knows whether the
result transfers.

Benchmark JSONs are gitignored. The schema is committed (the
`writeJSON` function in `StressTest/main.swift` and
`TopKBench/main.swift`). To compare a current measurement
against a historical one, check out the historical commit, run
the same stress-test invocation on the same hardware, and
compare.

## Sample sizes and noise

- `--quick` mode uses 10 ms warmup + 40 ms measurement. Suitable
  for iteration; ±5% noise is typical.
- Full mode uses 50 ms warmup + 200 ms measurement. Suitable for
  decision-record citation; ±2% noise is typical.
- For very small per-call cost (<100 ns), the harness reports
  `ns_per_call_min` and `ns_per_element_min`. Use the min when
  comparing against floor calculations (e.g., cookbook §17.5
  bandwidth floor).

## What this directory does not contain

- The substrate's runtime layout (cookbook §4.2 memory-mapped
  bit-slice files). This is a future workstream gated on the
  substrate-level bit-slice decision.
- The audit log, CRDT, and SQLite durability tail (cookbook §5,
  §4.3). Separate substrate-level work.
- CognitionKit primitives (cookbook §11). These compose from the
  kernel layer's ops; they live in a different package.
- ActuatorKit (cookbook §14). Separate package.
