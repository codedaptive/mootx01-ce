# SubstrateLib

SubstrateLib is the **orchestration layer** of the four-package substrate
split — the control surface that composes the three sub-packages into a
*writable* substrate. It depends on `SubstrateTypes` (value types),
`SubstrateKernel` (hot-path kernels), and `SubstrateML` (cold-path
algorithms).

Promoted from `docs/validation/substrate_math_performance/GeniusLocusReference/`
on 2026-05-19. The four-package split landed 2026-05-29
(`docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md` §20
+ the 2026-05-29 addendum), which moved the value types, kernels, and ML
primitives into the three sub-packages and **retained SubstrateLib** as
the orchestration package. The transitional `@_exported` re-export shim
has been removed; consumers depend on the sub-packages directly.

## What SubstrateLib holds

Three orchestration symbols — the substrate's write-path control surface
— plus the Rust scalar-oracle reference impls for higher layers.

- **`Verbs` (spec §10).** The nine substrate verbs (capture, reanchor,
  mutate, withdraw, expunge, recall, propose, associate, learn) and their
  mechanics. Source: `Verbs.swift`.
- **`RowStateAutomaton` (spec §9).** The row-state finite-state machine
  that validates verb preconditions/postconditions and I-22 forbidden
  combinations. Source: `RowStateAutomaton.swift`.
- **`AuditGate`.** The single write gate: every mutation passes through
  `AuditGate.admit`, which validates the transition (`RowStateAutomaton`),
  checks forbidden combinations (I-22), seals the event (I-27, via
  `SubstrateKernel.SHA256`), and emits one `AuditEvent`. This is why
  AuditGate lives here, not in SubstrateKernel — it depends on the
  orchestration FSM. Source: `AuditGate.swift`.

The Rust leg additionally carries cookbook reference implementations for
kit-level sections (`working_set`, `sqlite_tail`, `cognition_kit`,
`cognition_bundle`, `actuator`, `dreaming`) — the scalar oracle for kits
that do not yet have their own Rust crates. Not substrate atomics.

## What SubstrateLib no longer holds

Everything else moved to the sub-packages in the 2026-05-29 split:

| Was here | Now in |
|---|---|
| `Fingerprint256`, `HLC` + `HLCGenerator`, `AuditEvent`, `LatticeAnchor`, `Row`, `NounType`, `MatrixF/C/O/T`, `SimHash`, `Hamming`, `ORReduce`, `BitwiseArithmetic`, `HyperplaneFamily`, `CountVector256`, `FNV`, `GSetAuditLog`, `RecallTypes`, `ThreeDBitTensor` | `../SubstrateTypes/` |
| `PortableKernel` + NEON/BNNS/Metal/SIMD/scalar, `SHA256`, `HammingNN`, `BitField` | `../SubstrateKernel/` |
| `MatrixDecay`, `MomentSummary`, `BradleyTerry`, `NMF`, `FFT`, `EigenvalueCentrality`, `CommunityDetection`, `RandomWalks`, `AnomalyDetection`, `InformationTheory`, `LLMCalibrationCurve`, `TemporalCompression`, `AuditLogFold`, `PartialStateRecall`, `PairingHandshake`, `TierContributionFingerprint`, `TierAscendingQuery`, `ActionOutcomeMatrix`, `DPORReduction`, `FloatSimHash`, `LatticeDistance`, `CompositeDistance`, `FeatureExtractors` | `../SubstrateML/` |

## Who depends on SubstrateLib

Only verb-drivers — kits that drive the substrate verbs / row-state
machine. Today that is **LocusKit**. Every other kit depends on the
precise sub-package(s) it uses.

## Constitutional invariants enforced here

- **I-1 (verbatim rung sacred):** `Verbs` exposes a capture verb that
  writes the verbatim rung but no verb to mutate it.
- **I-22 (audit-trail-is-substrate) + write-gate totality:** `AuditGate`
  is the only authoring path; corruption is unrepresentable through it.

## Building and testing

```
cd SubstrateLib
swift build
swift test
```

Requires Swift 6.0+. Tested on Apple Silicon macOS 14+; Linux x86_64
conformance is enforced by the external test harness.

## Cookbook cross-reference

Cookbook v1.0 §20 + the 2026-05-29 addendum describe the four-package
split. `docs/engineering/HARNESS_REFERENCE.md` is the
canonical primitive index across all four packages.
