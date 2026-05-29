# SubstrateKernel

Layer 2 — bandwidth-bound bit operations + write gate + clock maker of the four-package SubstrateLib split.

**Status:** built; four-package split mid-migration (per
`docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
Phase 6 and the 2026-05-29 addendum). Symbols here hold real code;
remaining symbols are still resident in `SubstrateLib`, which is
RETAINED as the orchestration package (the four-package end-state),
not deleted. A temporary `@_exported` re-export keeps downstream kits
compiling until consumers re-point precisely.

## What lives here

The hot path. SimHash, Hamming, OR-reduce, Fingerprint256 ops, SimdKernel, HammingNN top-K, AuditGate, HLCGenerator, SHA-256 seal. Tier-1 of the conformance harness lives here.

See `docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md` §6 for
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

Swift (SPM):       `.package(path: "../SubstrateKernel")`
Rust  (Cargo):     `{ path = "../../SubstrateKernel/rust" }`

## Layout

```
SubstrateKernel/
├── Package.swift                          (Swift SPM)
├── Sources/SubstrateKernel/                          (Swift sources)
├── Tests/SubstrateKernelTests/                     (Swift tests)
└── rust/
    ├── Cargo.toml                         (Rust crate)
    └── src/lib.rs
```

## Build status during refactor

`SubstrateLib` is RETAINED as the orchestration package of the
four-package end-state (it holds the verb mechanics and the row-state
automaton, which fit none of Types/Kernel/ML; see the 2026-05-29
addendum). The migration re-points the downstream consumers to the
appropriate one(s) of SubstrateKernel's siblings and removes the
temporary `@_exported` re-export shim — it does NOT delete
`SubstrateLib`.

## License

MIT OR Apache-2.0 (matches `SubstrateLib`).
