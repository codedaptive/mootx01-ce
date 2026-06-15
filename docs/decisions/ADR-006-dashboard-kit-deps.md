---
status: decided
question: Should moot-mgr's Package.swift depend on LatticeLib, AriaLexiconLib, and CognitionKit to surface their capabilities in the dashboard?
authors: MOOTx01 maintainers
date: 2026-06-08
relates_to:
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
supersedes: none
context:
  - moot-mgr is the dashboard/control app for the mootx01 substrate
  - the dashboard needs to surface capabilities, the ARIA lexicon, and shipped NeuronKit capabilities
---

# ADR-006 — Add LatticeLib, AriaLexiconLib, and CognitionKit to moot-mgr Package.swift

## Decision

Add three in-repo package dependencies to `apps/moot-mgr/Package.swift`:

| Package | Path | Reason |
|---|---|---|
| `LatticeLib` | `packages/libs/LatticeLib` | Surface `FDC.isAvailable`, `FDC.dataVersion`, `LatticeLib.version` in the dashboard Capabilities/Configuration panel |
| `AriaLexiconLib` | `packages/libs/AriaLexiconLib` | Serve `/api/lexicon` endpoint returning the ARIA grammar (nouns, verbs, adjectives, acceptance matrix) as JSON — static, zero-overhead |
| `CognitionKit` | `packages/kits/CognitionKit` | Surface `shippedNeuronKitCapabilities.map(\.rawValue)` in `ServerPayload.capabilities` — compile-time constant; replaces a hardcoded placeholder row in the dashboard |

## Layering

moot-mgr is a top-level APP (not a kit). All three dependencies are kits or libs
(downstream→upstream). No layering inversion. This follows the same pattern as the
existing GeniusLocusKit dependency in moot-mgr.

## No external dependencies

All three are in-repo packages. No new third-party Swift packages are introduced.
The C-1 doctrine constraint (no external deps in kits) is not affected — moot-mgr
is an app, not a kit.

## Package-dependency doctrine

Per [`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md`](DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md),
kits and apps MAY declare dependencies on other in-repo packages when a recorded
architectural decision requires it. This ADR is that recorded decision for the three
dependencies above.
