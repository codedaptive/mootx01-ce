---
status: in_progress
created: 2026-05-16
last_updated: 2026-06-14
---

# GeniusLocus Reference Implementation

Reference implementations of every technique specified in
[`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`](../../engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md).

These files are **canonical sources** for shipping code. They are
not the shipping code itself. A coder wrapping these for production
keeps the math identical, swaps the data-structure shapes for their
target runtime, and gains:

- A bit-for-bit oracle against the cookbook's pseudocode
- A test-vector basis for cross-language conformance
- Inline cookbook section references for every algorithm
- A Swift reference here plus Metal where the bandwidth profile
  makes a GPU kernel meaningful; the Rust port (the four
  `packages/libs/Substrate*/rust/` crates) is conformance-gated
  against the same vectors via `test-harness/rust`

## Layout

```
substrate_math_performance/
├── glref-README.md           This file
├── glref-INDEX.md            Cookbook § → file mapping
├── GeniusLocusReference/     Swift reference implementations (library)
│   ├── Package.swift
│   └── glref-swift-<TechniqueName>.swift   (50 files)
├── metal/                    Metal compute shaders
│   └── glref-metal-hamming_nn.metal
├── test-harness/             conformance + drift harness (see test-harness/README.md)
│   ├── swift/                Swift harness (gen-vectors, validate-vectors)
│   ├── rust/                 Rust harness (pinned nightly)
│   └── vectors/             canonical test-vector JSON files
└── validation-app/           cross-language comparison app
    ├── rust/
    ├── swift-app/
    └── cross_lang_compare.py
```

The reference implementations in `GeniusLocusReference/` are **Swift
only** — there is no parallel `glref-rust-*` reference tree in this
directory. The Rust port of the substrate lives in the four substrate
crates under `packages/libs/Substrate*/rust/`, and is exercised here
through `test-harness/rust` (conformance against the same vectors) and
`validation-app/rust` (cross-language output comparison). Equivalence
between the Swift reference and the Rust port is verified by running
both against the shared test vectors and confirming bit-identical
output, not by reading two side-by-side files in this directory.

## Authoring workflow

Reference implementations are authored from the cookbook as the
single source of truth. Swift and Rust ports land together for the
same primitive, not sequentially. The cookbook prose is
authoritative; both language ports are equal-status implementations
of that prose.

The conformance gate is bit-identity between the two ports on
every test vector. When they disagree, the cookbook is ambiguous
on that primitive — investigate, fix the cookbook, both re-run.
This catches spec bugs that single-language authoring would
silently paper over.

## Accelerator routing (which silicon runs which math)

Substrate primitives route by workload class and device
capability. The shipping code consults a kernel-layer selector at
runtime; the reference implementations are the scalar oracle every
backend must match bit-for-bit.

| Math operation | Mac / iPhone 12+ / M-series iPad | PC / Linux x86_64 | Linux aarch64 |
|---|---|---|---|
| Bit-vector ops (Hamming, OR-reduce, bitwise) | NEON inline | AVX-512 / AVX2 | NEON inline |
| Hamming-NN ≥ 100K candidates | **Metal GPU** | AVX-512 CPU | NEON CPU |
| SimHash projection (dense matrix) | **AMX** via Accelerate | BLAS (OpenBLAS / MKL) | BLAS |
| F / C / O / T matrix decay + update | **AMX** via Accelerate | BLAS or pure Rust | BLAS or pure Rust |
| NMF, eigenvalue centrality | **AMX** via Accelerate | BLAS | BLAS |
| FFT rhythm analysis | **AMX** via Accelerate (vDSP_fft) | BLAS / pure Rust | BLAS / pure Rust |
| Sparse / irregular matrix | NEON CPU | AVX2 CPU | NEON CPU |
| Row-state automaton, HLC, G-Set, verbs | CPU scalar | CPU scalar | CPU scalar |
| Bradley-Terry online update | CPU scalar | CPU scalar | CPU scalar |
| LLM inference (cognition tier above) | **ANE** via Core ML | CUDA / DirectML / CPU | CUDA / ROCm / CPU |

Routing follows the kernel-dispatch contract: the scalar reference
is the oracle every accelerator backend must match bit-for-bit,
and each platform selects the fastest backend that preserves that
identity.

## Implementation status

### Done (both Swift and Rust)

| Technique | Cookbook § | Swift | Rust | Metal |
|---|---|---|---|---|
| Fingerprint256 type | §3.1 | ✓ | ✓ | — |
| HyperplaneFamily | §3.7 | ✓ | ✓ | — |
| SimHash | §3.6 | ✓ | ✓ | — |
| Per-stream feature extractors (5 streams) | §3.9 | ✓ | ✓ | — |
| 3D bit-sliced tensor | §4.1 | ✓ | ✓ | — |
| Memory-mapped working set | §4.2 | ✓ | ✓ | — |
| SQLite durability tail | §4.3 | ✓ | ✓ | — |
| Portable kernel layer (scalar reference) | §4.4 | ✓ | ✓ | — |
| HLC clock | §5.2 | ✓ | ✓ | — |
| G-Set audit log | §5.1 | ✓ | ✓ | — |
| F matrix (field presence) | §6.1 | ✓ | ✓ | — |
| C matrix (correlation) | §6.2 | ✓ | ✓ | — |
| O matrix (co-occurrence) | §6.3 | ✓ | ✓ | — |
| T matrix (temporal causality) | §6.4 | ✓ | ✓ | — |
| Action-outcome matrix | §6.5 | ✓ | ✓ | — |
| LLM calibration curves | §6.6 | ✓ | ✓ | — |
| Matrix decay | §6.8 | ✓ | ✓ | — |
| NMF alternating least squares | §6.9 / §8.9 | ✓ | ✓ | — |
| Eigenvalue centrality | §7.2 | ✓ | ✓ | — |
| Community detection (Louvain phase 1) | §7.3 | ✓ | ✓ | — |
| Random walks (with restart) | §7.4 | ✓ | ✓ | — |
| Hamming distance | §8.2 | ✓ | ✓ | — |
| Hamming-NN | §8.2 | ✓ | ✓ | ✓ |
| Lattice distance (UDC + Wikidata) | §8.3 | ✓ | ✓ | — |
| Composite distance | §8.4 | ✓ | ✓ | — |
| OR-reduce | §8.5 | ✓ | ✓ | — |
| Bitwise arithmetic | §8.6 | ✓ | ✓ | — |
| Moment-summary fingerprint | §8.7 | ✓ | ✓ | — |
| Partial-state recall | §8.8 | ✓ | ✓ | — |
| FFT rhythm analysis | §8.10 / §11.14 | ✓ | ✓ | — |
| Information theory (entropy, MI, KL, JS, NMI) | §8.11 | ✓ | ✓ | — |
| Bradley-Terry update | §8.12 | ✓ | ✓ | — |
| Anomaly detection (z-score, modified, rolling) | §8.13 | ✓ | ✓ | — |
| Temporal compression (hierarchical roll-up) | §8.14 | ✓ | ✓ | — |
| Audit-log fold (asOf projection) | §8.15 | ✓ | ✓ | — |
| Row-state automaton | §9 | ✓ | ✓ | — |
| Nine verbs (capture, mutate, …) | §10 | ✓ | ✓ | — |
| CognitionKit (18 retrieval primitives) | §11 | ✓ | ✓ | — |
| Pairing handshake | §12.2 | ✓ | ✓ | — |
| Tier contribution fingerprint | §12.3 | ✓ | ✓ | — |
| Tier-ascending query protocol | §12.4 | ✓ | ✓ | — |
| Differentially-private OR-reduction | §12.6 | ✓ | ✓ | — |
| Portable Cognition Bundle | §13 | ✓ | ✓ | — |
| ActuatorKit | §14 | ✓ | ✓ | — |
| Dreaming daemon (13 rules) | §15 | ✓ | ✓ | — |

### Next pass

| Pass | Scope |
|---|---|
| Test vectors | Per-component canonical input/output pairs in `test-harness/vectors/` exercising every component. Gates future re-implementations and SIMD specializations at bit-identity. |
| NEON / AVX-512 / AVX2 kernels | Specializations of PortableKernel for ARM and x86-64. Each must produce bit-identical output to ScalarKernel under the four-way conformance gate. |
| Louvain phase 2 | Deferred from §7.3. Phase 1 already shipped; CognitionKit's recall_community and recall_exploratory are documented stubs pending phase 2. |
| Quantitative paper | Quantitative results from the evaluation suite once test vectors and a runnable benchmark land. |

## Conformance

Each reference implementation is paired with test vectors that any
shipping implementation must reproduce bit-for-bit. The vectors
are the contract between this reference tree and production code
in LocusKit / GeniusLocusKit / NeuronKit / CognitionKit /
ConvergenceKit / CorpusKit.

Test vectors are produced by running the reference on a fixed
seed and recording outputs. They land in
`test-harness/vectors/`. Both the Swift scalar reference and the
Rust scalar reference are conformance oracles; CI gates merges on
bit-identical output across language and backend.

## Building

### Swift reference

The reference implementations are a single SwiftPM library package
with no test target:

```sh
cd docs/validation/substrate_math_performance/GeniusLocusReference && swift build
```

### Conformance harness (Swift)

The harness builds and tests the conformance binaries (`gen-vectors`,
`validate-vectors`) against the shared vectors:

```sh
cd docs/validation/substrate_math_performance/test-harness/swift && swift build && swift test
```

### Conformance harness (Rust)

The Rust harness requires the pinned nightly toolchain selected by
`test-harness/rust/rust-toolchain.toml` (see `test-harness/README.md`):

```sh
cd docs/validation/substrate_math_performance/test-harness/rust && cargo build && cargo test
```

### Metal

The single shader lives at `metal/glref-metal-hamming_nn.metal`. It is
validated through the harness's Metal kernel path against the same
Hamming-NN vectors.

## Relationship to shipping kits

| Reference file | Shipping target |
|---|---|
| glref-*-Fingerprint256, SimHash, Hamming, ORReduce, Bitwise | NeuronKit |
| glref-*-HyperplaneFamily | LocusKit (manifest) + NeuronKit (consumer) |
| glref-*-HLC, GSetAuditLog | LocusKit (EstateAudit) |
| glref-*-RowStateAutomaton | LocusKit (DrawerStateValidator) |
| glref-*-BradleyTerry, MatrixDecay | NeuronKit (cognition tier) |
| glref-*-FFT | NeuronKit (rhythm analysis path, consumed by §11.14) |
| glref-*-ActionOutcomeMatrix, LLMCalibrationCurve | NeuronKit (cognition tier) |
| glref-*-NMF, InformationTheory, AnomalyDetection, TemporalCompression | NeuronKit (matrix tier maintenance) |
| glref-*-FeatureExtractors | Mootx01-App (ambient stream capture) |
| glref-*-CognitionKit | CognitionKit (the shipping kit of the same name) |
| glref-*-ThreeDBitTensor, WorkingSetMmap, SQLiteDurabilityTail, PortableKernel | LocusKit (substrate runtime) |
| glref-*-PairingHandshake, TierContribution*, TierAscendingQuery, DPORReduction | ConvergenceKit (federation) |
| glref-*-PortableCognitionBundle | CognitionKit (export/import) |
| glref-*-ActuatorKit | NeuronKit (actuator dispatch) |
| glref-*-DreamingDaemon | LocusKit (background maintenance) |
| glref-metal-* | NeuronKit (kernel backends) |

The reference implementations are **NOT** imported by shipping
kits. Shipping code re-implements with platform-appropriate
optimizations; the reference exists so the shipping
implementation can be tested against a known-correct oracle.
