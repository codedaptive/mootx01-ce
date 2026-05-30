---
name: substrate-lib
description: Use this skill when an agent is deciding whether to depend on SubstrateLib or one of its three sub-packages, or is working with the substrate's write path — the nine verbs, the row-state automaton, or the AuditGate write gate. SubstrateLib is the retained orchestration layer of the four-package substrate split; depend on it only if you drive the verbs / row-state machine (today only LocusKit does). For value types, kernels, or ML primitives, depend on SubstrateTypes / SubstrateKernel / SubstrateML directly. Trigger this when adding a SubstrateLib import, writing through AuditGate, or reasoning about verb/row-state mechanics.
---

# substrate-lib — the substrate orchestration layer

## When this skill applies

An agent is about to:
- Add a `SubstrateLib` dependency (Swift `Package.swift` or Rust `Cargo.toml`)
- Write a mutation through the substrate (every write goes through `AuditGate`)
- Work with the nine verbs or the `RowStateAutomaton` state machine
- Decide whether SubstrateLib or a sub-package is the right dependency

## The one rule

SubstrateLib is **retained** as the orchestration layer (four-package
split, 2026-05-29 addendum) — it is NOT deprecated. But depend on it
**only if you drive the verbs / row-state machine / write gate**. If you
only need a value type, a kernel, or an ML primitive, depend on the
precise sub-package instead.

## What lives in SubstrateLib (and only here)

| Symbol | Use |
|---|---|
| `Verbs` | The nine substrate verbs and their mechanics |
| `RowStateAutomaton` | `RowStateAutomaton.validate(from:on:targetingFields:)` — legal-transition + I-22 check |
| `AuditGate` | `try AuditGate.admit(verb:prior:writes:actor:hlc:)` — the only legitimate path to a mutation |

`AuditGate` lives here (not in SubstrateKernel) because it calls
`RowStateAutomaton`; it *consumes* `SubstrateKernel`'s `BitField` + `SHA256`.

## Where everything else lives (depend on these directly)

| If you wanted… | Depend on |
|---|---|
| `Fingerprint256`, `HLC` + `HLCGenerator`, `AuditEvent`, `LatticeAnchor`, `Row`, `NounType`, layout constants, `SimHash`, `Hamming`, `ORReduce`, `MatrixF/C/O/T`, `GSetAuditLog`, `RecallTypes` | `SubstrateTypes` |
| `PortableKernel`/`SimdKernel`, `HammingNN`, `BitField`, `SHA256` | `SubstrateKernel` |
| `MatrixDecay`, `BradleyTerry`, `FFT`, `NMF`, `AuditLogFold`, `PartialStateRecall`, `PairingHandshake`, `TierContribution*`, `DPORReduction`, … | `SubstrateML` |

## How to depend on it (verb-drivers)

```swift
.package(path: "../../libs/SubstrateLib"),
// targets dependencies: ["SubstrateLib"]
import SubstrateLib
```

```toml
substrate-lib = { path = "../../libs/SubstrateLib/rust" }
```

## Anti-patterns

1. **Depending on SubstrateLib for a value type / kernel / ML primitive.**
   Those moved to the sub-packages; SubstrateLib no longer re-exports them.
   Depend on `SubstrateTypes` / `SubstrateKernel` / `SubstrateML` directly.
2. **Writing to the audit log without `AuditGate.admit`.** Bypasses I-22
   enforcement, the seal, and the per-mode `sealed` bit. The gate is the
   only authoring point.

## What to read

`packages/libs/SubstrateLib/AGENTS.md` for the AuditGate write-path
reference. The three sub-packages each have their own `AGENTS.md`/`SKILL.md`.
