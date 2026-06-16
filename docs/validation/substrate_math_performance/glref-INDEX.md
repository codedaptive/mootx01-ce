---
status: in_progress
created: 2026-05-16
last_updated: 2026-06-14
---

# Cookbook § → Reference File Index

Mapping from `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`
sections to the reference implementation files. The Swift
reference files live in the `GeniusLocusReference/` subdirectory of
this folder; the Metal kernel lives in `metal/`. The Rust port is
conformance-gated in the substrate crates (`packages/libs/Substrate*/rust`),
not duplicated here.

## §3 — The fingerprint

| § | Topic | Files |
|---|-------|-------|
| §3.1 | 256-bit four-block structure | glref-swift-Fingerprint256.swift |
| §3.6 | SimHash construction | glref-swift-SimHash.swift |
| §3.7 | Hyperplane seed families | glref-swift-HyperplaneFamily.swift |
| §3.9 | Per-stream feature extractors (HealthKit, CoreLocation, EventKit, ScreenTime, SystemTelemetry) | glref-swift-FeatureExtractors.swift |

## §4 — Runtime layout

| § | Topic | Files |
|---|-------|-------|
| §4.1 | 3D bit-sliced tensor | glref-swift-ThreeDBitTensor.swift |
| §4.2 | Memory-mapped working set | glref-swift-WorkingSetMmap.swift |
| §4.3 | SQLite durability tail | glref-swift-SQLiteDurabilityTail.swift |
| §4.4 | Portable kernel layer (scalar reference; NEON / AVX-512 / AVX2 specializations follow) | glref-swift-PortableKernel.swift |

## §5 — The audit log as CRDT

| § | Topic | Files |
|---|-------|-------|
| §5.1 | G-Set semantics | glref-swift-GSetAuditLog.swift |
| §5.2 | HLC ordering | glref-swift-HLC.swift |

## §6 — Matrix tier

| § | Topic | Files |
|---|-------|-------|
| §6.1 | Field-presence matrix F | glref-swift-MatrixF.swift |
| §6.2 | Correlation matrix C (derived) | glref-swift-MatrixC.swift |
| §6.3 | Co-occurrence matrix O | glref-swift-MatrixO.swift |
| §6.4 | Temporal causality matrix T | glref-swift-MatrixT.swift |
| §6.5 | Action-outcome matrix | glref-swift-ActionOutcomeMatrix.swift |
| §6.6 | LLM calibration curves | glref-swift-LLMCalibrationCurve.swift |
| §6.8 | Matrix decay | glref-swift-MatrixDecay.swift |
| §6.9 | NMF latent factors (alternating least squares) | glref-swift-NMFAlternatingLeastSquares.swift |

## §7 — The estate as a graph

| § | Topic | Files |
|---|-------|-------|
| §7.2 | Eigenvalue centrality | glref-swift-EigenvalueCentrality.swift |
| §7.3 | Community detection (Louvain phase 1) | glref-swift-CommunityDetection.swift |
| §7.4 | Random walks (with restart) | glref-swift-RandomWalks.swift |

## §8 — Algorithms

| § | Topic | Files |
|---|-------|-------|
| §8.2 | Hamming distance and Hamming-NN | glref-swift-Hamming.swift, glref-swift-HammingNN.swift, glref-metal-hamming_nn.metal |
| §8.3 | Lattice distance (UDC + Wikidata) | glref-swift-LatticeDistance.swift |
| §8.4 | Composite distance | glref-swift-CompositeDistance.swift |
| §8.5 | OR-reduction across scopes | glref-swift-ORReduce.swift |
| §8.6 | Fingerprint bitwise arithmetic | glref-swift-BitwiseArithmetic.swift |
| §8.7 | Moment-summary fingerprint | glref-swift-MomentSummary.swift |
| §8.8 | Partial-state recall | glref-swift-PartialStateRecall.swift |
| §8.10 | FFT (rhythm analysis) | glref-swift-FFT.swift |
| §8.11 | Information theory (entropy, MI, KL, cross-entropy, JS, NMI) | glref-swift-InformationTheory.swift |
| §8.12 | Bradley-Terry online update | glref-swift-BradleyTerry.swift |
| §8.13 | Anomaly detection (z-score, modified z-score, rolling) | glref-swift-AnomalyDetection.swift |
| §8.14 | Temporal compression (hierarchical window roll-up) | glref-swift-TemporalCompression.swift |
| §8.15 | Audit-log fold (asOf projection) | glref-swift-AuditLogFold.swift |

## §9 — Row-state finite-state automaton

| § | Topic | Files |
|---|-------|-------|
| §9.1–§9.9 | State set, transitions, safety, validator | glref-swift-RowStateAutomaton.swift |

## §10 — The nine verbs

| § | Topic | Files |
|---|-------|-------|
| §10.1–§10.9 | capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn | glref-swift-Verbs.swift |

## §11 — CognitionKit primitives

| § | Topic | Files |
|---|-------|-------|
| §11.1–§11.18 | Eighteen retrieval primitives (5 classes A through E); §11.14 recall_rhythm_analysis consumes FFT | glref-swift-CognitionKit.swift |

## §12 — Federation

| § | Topic | Files |
|---|-------|-------|
| §12.2 | Pairing handshake (5-step protocol, shared family generation) | glref-swift-PairingHandshake.swift |
| §12.3 | Tier contribution fingerprint (canonical 64-byte wire format) | glref-swift-TierContributionFingerprint.swift |
| §12.4 | Tier-ascending query protocol (5-step query/response with DP) | glref-swift-TierAscendingQuery.swift |
| §12.6 | Differentially-private OR-reduction (Laplace noise + k-anonymity) | glref-swift-DPORReduction.swift |
| §12.7 | Privacy ledger (peer-keyed ε/δ consumption, daily reset) | (included in glref-swift-TierAscendingQuery.swift) |

## §13 — Portable Cognition Bundle

| § | Topic | Files |
|---|-------|-------|
| §13.1–§13.3 | Tournament weights, ranking weights, RecallTrace summary, preferred pipelines, lexicon; text + binary serialization | glref-swift-PortableCognitionBundle.swift |

## §14 — ActuatorKit

| § | Topic | Files |
|---|-------|-------|
| §14.1–§14.4 | Action allowlist, outcome reporting, reversibility (I-21/I-22/I-23), handler protocol, dispatch | glref-swift-ActuatorKit.swift |

## §15 — Dreaming daemon

| § | Topic | Files |
|---|-------|-------|
| §15.1–§15.2 | Thirteen scheduled rules (decay, keystone, NMF, calibration, temporal, anomaly, compaction, federation, ledger, Bradley-Terry, action-outcome, bundle export) | glref-swift-DreamingDaemon.swift |

## Not yet implemented

| § | Topic |
|---|-------|
| §4.4 specializations | NEON / AVX-512 / AVX2 kernel overlays for PortableKernel (scalar reference and one Metal kernel for Hamming-NN already in tree) |
| §7.3 phase 2 | Louvain phase 2 (not yet implemented); CognitionKit recall_community and recall_exploratory are stubs pending implementation |

## Accelerator routing

The reference files target two routing surfaces:

- Apple-side routing across AMX, Metal, NEON, and the ANE.
- Non-Apple routing across AVX-512, NEON-aarch64, BLAS, and the scalar oracle.
