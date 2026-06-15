# SubstrateML

Layer 3 — learning + graph algorithms of the four-package SubstrateLib split.

**Status:** built; four-package split mid-migration (per
`docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
Phase 6 and the 2026-05-29 addendum). Symbols here hold real code;
remaining symbols are still resident in `SubstrateLib`, which is
RETAINED as the orchestration package (the four-package end-state),
not deleted. A temporary `@_exported` re-export keeps downstream kits
compiling until consumers re-point precisely.

## What lives here

Cold path / dreaming-driven. MatrixDecay, MomentSummary, BradleyTerry, Anomaly, InfoTheory, TemporalCompression, PartialStateRecall, FFT, NMF, EigenvalueCentrality, AuditLogFold, TierContribution, PairingHandshake. Tier-2 and Tier-3 of the conformance harness live here.

See `docs/engineering/HARNESS_REFERENCE.md` §6 for
the canonical breakdown of where each substrate primitive lives,
and cookbook v1.0 §20 for the rationale.

## Dependency graph

```
SubstrateTypes        (no deps)
       │
       ▼
SubstrateKernel       (depends on SubstrateTypes)
       │
       ▼
SubstrateML           (depends on SubstrateTypes + SubstrateKernel)
```

Swift (SPM):       `.package(path: "../SubstrateML")`
Rust  (Cargo):     `{ path = "../../SubstrateML/rust" }`

## Layout

```
SubstrateML/
├── Package.swift                          (Swift SPM)
├── Sources/SubstrateML/                          (Swift sources)
├── Tests/SubstrateMLTests/                     (Swift tests)
└── rust/
    ├── Cargo.toml                         (Rust crate)
    └── src/lib.rs
```

## Build status during refactor

`SubstrateLib` is RETAINED as the orchestration package of the
four-package end-state (it holds the verb mechanics and the row-state
automaton, which fit none of Types/Kernel/ML; see the 2026-05-29
addendum). The migration re-points the downstream consumers to the
appropriate one(s) of SubstrateML's siblings and removes the
temporary `@_exported` re-export shim — it does NOT delete
`SubstrateLib`.

## License

MIT OR Apache-2.0 (matches `SubstrateLib`).
