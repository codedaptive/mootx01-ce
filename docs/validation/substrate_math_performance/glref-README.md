# GeniusLocus Reference Implementation

Reference implementations of every technique specified in
[`docs/specs/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`](../../specs/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md).

These files are **canonical sources** for shipping code. They are
not the shipping code itself. A coder wrapping these for production
keeps the math identical, swaps the data-structure shapes for their
target runtime, and gains:

- A bit-for-bit oracle against the cookbook's pseudocode
- A test-vector basis for cross-language conformance
- Inline cookbook section references for every algorithm
- Two reference languages (Swift, Rust) plus Metal where the
  bandwidth profile makes a GPU kernel meaningful

## Layout

```
substrate_reference/
├── README.md              This file
├── INDEX.md               Cookbook § → file mapping
├── swift/                 Swift reference implementations
│   └── glref-swift-<TechniqueName>.swift
├── rust/                  Rust reference implementations
│   └── glref-rust-<technique_name>.rs
└── metal/                 Metal compute shaders
    └── glref-metal-<shader_name>.metal
```

A Swift and Rust file with the same root name implement the same
algorithm. Compare them side by side to verify equivalence; run
the cross-language test vectors to verify bit-identical output.

## Authoring workflow

Reference implementations are authored in **parallel sub-agents
working from the cookbook as the single source of truth**. Swift
and Rust ports land together for the same primitive, not
sequentially. The cookbook prose is authoritative; both language
ports are equal-status implementations of that prose.

The conformance gate is bit-identity between the two ports on
every test vector. When they disagree, the cookbook is ambiguous
on that primitive — investigate, fix the cookbook, both re-run.
This catches spec bugs that single-language authoring would
silently paper over.

See [`docs/decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md`](../../decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md)
for the rationale.

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

Apple-side rationale: [`docs/decisions/DECISION_ACCELERATOR_ROUTING_2026-05-16.md`](../../decisions/DECISION_ACCELERATOR_ROUTING_2026-05-16.md).
Non-Apple rationale: [`docs/decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md`](../../decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md).

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
| Test vectors | Per-component canonical input/output pairs in `test-harness/vectors/` exercising every new Block 2a + 2b component. Gates future re-implementations and SIMD specializations at bit-identity. |
| NEON / AVX-512 / AVX2 kernels | Specializations of PortableKernel for ARM and x86-64. Each must produce bit-identical output to ScalarKernel under the four-way conformance gate. |
| Louvain phase 2 | Deferred from §7.3 to v0.37. Phase 1 already shipped; CognitionKit's recall_community and recall_exploratory are documented v0.37 stubs. |
| Paper v0.2 | Quantitative results from M6 evaluation suite once test vectors and a runnable benchmark land. |

## Conformance

Each reference implementation is paired with test vectors that any
shipping implementation must reproduce bit-for-bit. The vectors
are the contract between this reference tree and production code
in LocusKit / LociKit / NeuronKit / CognitionKit / NexusKit /
CorpusKit.

Test vectors are produced by running the reference on a fixed
seed and recording outputs. They land in
`test-harness/vectors/`. Both the Swift scalar reference and the
Rust scalar reference are conformance oracles; CI gates merges on
bit-identical output across language and backend.

## Building

### Swift

```sh
cd docs/validation/substrate_math_performance/swift && swift build && swift test
```

### Rust

```sh
cd docs/validation/substrate_math_performance/rust && cargo build && cargo test
```

### Metal

Shaders are validated via the Swift package's `MetalKernels`
target once the portable kernel layer (federation/runtime pass)
lands.

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
| glref-*-FeatureExtractors | NexusIOS, NexusMacOS (ambient stream capture) |
| glref-*-CognitionKit | CognitionKit (the shipping kit of the same name) |
| glref-*-ThreeDBitTensor, WorkingSetMmap, SQLiteDurabilityTail, PortableKernel | LocusKit (substrate runtime) |
| glref-*-PairingHandshake, TierContribution*, TierAscendingQuery, DPORReduction | NexusKit (federation) |
| glref-*-PortableCognitionBundle | CognitionKit (export/import) |
| glref-*-ActuatorKit | NeuronKit (actuator dispatch) |
| glref-*-DreamingDaemon | LocusKit (background maintenance) |
| glref-metal-* | NeuronKit (kernel backends) |

The reference implementations are **NOT** imported by shipping
kits. Shipping code re-implements with platform-appropriate
optimizations; the reference exists so the shipping
implementation can be tested against a known-correct oracle.
