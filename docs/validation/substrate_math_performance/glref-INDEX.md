# Cookbook § → Reference File Index

Mapping from `GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`
sections to the reference implementation files. Files live in
`swift/`, `rust/`, and `metal/` subdirectories of this folder.

## §3 — The fingerprint

| § | Topic | Files |
|---|-------|-------|
| §3.1 | 256-bit four-block structure | glref-swift-Fingerprint256.swift, glref-rust-fingerprint256.rs |
| §3.6 | SimHash construction | glref-swift-SimHash.swift, glref-rust-simhash.rs |
| §3.7 | Hyperplane seed families | glref-swift-HyperplaneFamily.swift, glref-rust-hyperplane.rs |
| §3.9 | Per-stream feature extractors (HealthKit, CoreLocation, EventKit, ScreenTime, SystemTelemetry) | glref-swift-FeatureExtractors.swift, glref-rust-feature_extractors.rs |

## §4 — Runtime layout

| § | Topic | Files |
|---|-------|-------|
| §4.1 | 3D bit-sliced tensor | glref-swift-ThreeDBitTensor.swift, glref-rust-bit_tensor.rs |
| §4.2 | Memory-mapped working set | glref-swift-WorkingSetMmap.swift, glref-rust-working_set.rs |
| §4.3 | SQLite durability tail | glref-swift-SQLiteDurabilityTail.swift, glref-rust-sqlite_tail.rs |
| §4.4 | Portable kernel layer (scalar reference; NEON / AVX-512 / AVX2 specializations follow) | glref-swift-PortableKernel.swift, glref-rust-kernel.rs |

## §5 — The audit log as CRDT

| § | Topic | Files |
|---|-------|-------|
| §5.1 | G-Set semantics | glref-swift-GSetAuditLog.swift, glref-rust-gset.rs |
| §5.2 | HLC ordering | glref-swift-HLC.swift, glref-rust-hlc.rs |

## §6 — Matrix tier

| § | Topic | Files |
|---|-------|-------|
| §6.1 | Field-presence matrix F | glref-swift-MatrixF.swift, glref-rust-matrix_f.rs |
| §6.2 | Correlation matrix C (derived) | glref-swift-MatrixC.swift, glref-rust-matrix_c.rs |
| §6.3 | Co-occurrence matrix O | glref-swift-MatrixO.swift, glref-rust-matrix_o.rs |
| §6.4 | Temporal causality matrix T | glref-swift-MatrixT.swift, glref-rust-matrix_t.rs |
| §6.5 | Action-outcome matrix | glref-swift-ActionOutcomeMatrix.swift, glref-rust-action_outcome.rs |
| §6.6 | LLM calibration curves | glref-swift-LLMCalibrationCurve.swift, glref-rust-calibration.rs |
| §6.8 | Matrix decay | glref-swift-MatrixDecay.swift, glref-rust-decay.rs |
| §6.9 | NMF latent factors (alternating least squares) | glref-swift-NMFAlternatingLeastSquares.swift, glref-rust-nmf.rs |

## §7 — The estate as a graph

| § | Topic | Files |
|---|-------|-------|
| §7.2 | Eigenvalue centrality | glref-swift-EigenvalueCentrality.swift, glref-rust-eigenvalue_centrality.rs |
| §7.3 | Community detection (Louvain phase 1) | glref-swift-CommunityDetection.swift, glref-rust-community_detection.rs |
| §7.4 | Random walks (with restart) | glref-swift-RandomWalks.swift, glref-rust-random_walks.rs |

## §8 — Algorithms

| § | Topic | Files |
|---|-------|-------|
| §8.2 | Hamming distance and Hamming-NN | glref-swift-Hamming.swift, glref-swift-HammingNN.swift, glref-rust-hamming.rs, glref-rust-hamming_nn.rs, glref-metal-hamming_nn.metal |
| §8.3 | Lattice distance (UDC + Wikidata) | glref-swift-LatticeDistance.swift, glref-rust-lattice_distance.rs |
| §8.4 | Composite distance | glref-swift-CompositeDistance.swift, glref-rust-composite_distance.rs |
| §8.5 | OR-reduction across scopes | glref-swift-ORReduce.swift, glref-rust-or_reduce.rs |
| §8.6 | Fingerprint bitwise arithmetic | glref-swift-BitwiseArithmetic.swift, glref-rust-bitwise.rs |
| §8.7 | Moment-summary fingerprint | glref-swift-MomentSummary.swift, glref-rust-moment_summary.rs |
| §8.8 | Partial-state recall | glref-swift-PartialStateRecall.swift, glref-rust-partial_state_recall.rs |
| §8.10 | FFT (rhythm analysis) | glref-swift-FFT.swift, glref-rust-fft.rs |
| §8.11 | Information theory (entropy, MI, KL, cross-entropy, JS, NMI) | glref-swift-InformationTheory.swift, glref-rust-info_theory.rs |
| §8.12 | Bradley-Terry online update | glref-swift-BradleyTerry.swift, glref-rust-bradley_terry.rs |
| §8.13 | Anomaly detection (z-score, modified z-score, rolling) | glref-swift-AnomalyDetection.swift, glref-rust-anomaly.rs |
| §8.14 | Temporal compression (hierarchical window roll-up) | glref-swift-TemporalCompression.swift, glref-rust-temporal_compression.rs |
| §8.15 | Audit-log fold (asOf projection) | glref-swift-AuditLogFold.swift, glref-rust-audit_log_fold.rs |

## §9 — Row-state finite-state automaton

| § | Topic | Files |
|---|-------|-------|
| §9.1–§9.9 | State set, transitions, safety, validator | glref-swift-RowStateAutomaton.swift, glref-rust-row_state.rs |

## §10 — The nine verbs

| § | Topic | Files |
|---|-------|-------|
| §10.1–§10.9 | capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn | glref-swift-Verbs.swift, glref-rust-verbs.rs |

## §11 — CognitionKit primitives

| § | Topic | Files |
|---|-------|-------|
| §11.1–§11.18 | Eighteen retrieval primitives (5 classes A through E); §11.14 recall_rhythm_analysis consumes FFT | glref-swift-CognitionKit.swift, glref-rust-cognition_kit.rs |

## §12 — Federation

| § | Topic | Files |
|---|-------|-------|
| §12.2 | Pairing handshake (5-step protocol, shared family generation) | glref-swift-PairingHandshake.swift, glref-rust-pairing.rs |
| §12.3 | Tier contribution fingerprint (canonical 64-byte wire format) | glref-swift-TierContributionFingerprint.swift, glref-rust-tier_contribution.rs |
| §12.4 | Tier-ascending query protocol (5-step query/response with DP) | glref-swift-TierAscendingQuery.swift, glref-rust-tier_query.rs |
| §12.6 | Differentially-private OR-reduction (Laplace noise + k-anonymity) | glref-swift-DPORReduction.swift, glref-rust-dp_or_reduce.rs |
| §12.7 | Privacy ledger (peer-keyed ε/δ consumption, daily reset) | (included in glref-swift-TierAscendingQuery.swift, glref-rust-tier_query.rs) |

## §13 — Portable Cognition Bundle

| § | Topic | Files |
|---|-------|-------|
| §13.1–§13.3 | Tournament weights, ranking weights, RecallTrace summary, preferred pipelines, lexicon; text + binary serialization | glref-swift-PortableCognitionBundle.swift, glref-rust-cognition_bundle.rs |

## §14 — ActuatorKit

| § | Topic | Files |
|---|-------|-------|
| §14.1–§14.4 | Action allowlist, outcome reporting, reversibility (I-21/I-22/I-23), handler protocol, dispatch | glref-swift-ActuatorKit.swift, glref-rust-actuator.rs |

## §15 — Dreaming daemon

| § | Topic | Files |
|---|-------|-------|
| §15.1–§15.2 | Thirteen scheduled rules (decay, keystone, NMF, calibration, temporal, anomaly, compaction, federation, ledger, Bradley-Terry, action-outcome, bundle export) | glref-swift-DreamingDaemon.swift, glref-rust-dreaming.rs |

## Not yet implemented

| § | Topic |
|---|-------|
| §4.4 specializations | NEON / AVX-512 / AVX2 kernel overlays for PortableKernel (scalar reference and one Metal kernel for Hamming-NN already in tree) |
| §7.3 phase 2 | Louvain phase 2 (deferred to v0.37); CognitionKit recall_community and recall_exploratory are v0.37 stubs |

## Decision records related to this tree

- [`docs/decisions/DECISION_ACCELERATOR_ROUTING_2026-05-16.md`](../../decisions/DECISION_ACCELERATOR_ROUTING_2026-05-16.md) — Apple-side routing (AMX, Metal, NEON, ANE)
- [`docs/decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md`](../../decisions/DECISION_RUST_PORT_ROUTING_2026-05-16.md) — Non-Apple routing (AVX-512, NEON-aarch64, BLAS, scalar oracle) and parallel-sub-agent authoring workflow
