# SubstrateLib (legacy)

> **This package is deprecated.** Its symbols have migrated to three
> successor packages — `SubstrateTypes`, `SubstrateKernel`,
> `SubstrateML`. If you are looking for a substrate primitive, this
> is not where it lives anymore.

## If you came here looking for a symbol

| You wanted… | Now in |
|---|---|
| `Fingerprint256`, `HLC`, `Row`, `RowLite`, `LatticeAnchor`, `AuditEvent`, layout constants, enums, `MatrixF/C/O/T` (storage only) | `../SubstrateTypes/` |
| `SimHash`, `Fingerprint256` ops (distance / OR / AND / XOR / prototype), `HammingNN` top-K, `SimdKernel`, `AuditGate`, `HLCGenerator`, SHA-256 seal | `../SubstrateKernel/` |
| `MatrixDecay`, `MomentSummary`, `BradleyTerry`, `Anomaly`, `InfoTheory`, `TemporalCompression`, `PartialStateRecall`, `FFT`, `NMF`, `EigenvalueCentrality`, `AuditLogFold`, `TierContribution`, `PairingHandshake` | `../SubstrateML/` |

Each successor package has its own `AGENTS.md` describing the
symbols and usage. Start there.

## Why this exists at all

Until 2026-05-28, this was the published substrate surface. The
three-package split (cookbook v1.0 §20, I-30) separates pure types
from hot-path bit operations from cold-path learning. The split
makes the build graph match the layering: a kit that only
serializes rows depends only on `SubstrateTypes`; the harness
gate's six Tier-1 atomics depend only on `SubstrateKernel`; the
dreaming daemon's 15+ ML primitives depend on `SubstrateML`.

## Don't add new code here

If you have a new primitive to land:

- Pure data (struct, enum, layout constant)? → `../SubstrateTypes/`
- Hot-path bit operation, gate, clock, seal? → `../SubstrateKernel/`
- Learning algorithm, graph algorithm, projection? → `../SubstrateML/`

Each successor's `AGENTS.md` lists what belongs there and what
doesn't.

## If you're maintaining a downstream kit

The 9 downstream consumers that historically imported
`SubstrateLib` should be re-pointed to whichever of the three
successors they actually need. See the per-symbol table above for
mapping.

In Swift, replace:
```swift
.package(path: "../../libs/SubstrateLib"),
// targets: dependencies: ["SubstrateLib"]
```
with the subset you actually use:
```swift
.package(path: "../../libs/SubstrateTypes"),
.package(path: "../../libs/SubstrateKernel"),
// targets: dependencies: ["SubstrateTypes", "SubstrateKernel"]
```

In Rust, replace:
```toml
substrate-lib = { path = "../../libs/SubstrateLib/rust" }
```
with the subset you use:
```toml
substrate-types  = { path = "../../libs/SubstrateTypes/rust" }
substrate-kernel = { path = "../../libs/SubstrateKernel/rust" }
```

## Conformance through the transition

The 22 cross-language-pinned conformance vectors continue to pass
across both the legacy `SubstrateLib` and the three-package
successor — verified four-way on every gated primitive before the
symbol was removed from this package. See
`../../../docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md`
for the canonical index and the four-way verification commands.

## Related docs

- `../../../docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md`
  — the agentic discovery index for all 22 conformance-gated
  primitives, with the canonical Swift API, Rust API, and CRCs.
- `../../../docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md`
  §20 — the package-split rationale.

## License

MIT OR Apache-2.0.
