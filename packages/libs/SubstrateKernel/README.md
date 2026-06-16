# SubstrateKernel

Layer 2 — bandwidth-bound bit operations of the four-package substrate split.

**Status:** built; four-package split complete (per
`docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
Phase 6 and the 2026-05-29 addendum). Consumers depend on this package
directly; the transitional `@_exported` re-export shim has been removed.
`SubstrateLib` is RETAINED as the orchestration package of the
four-package end-state (verbs, row-state automaton, AuditGate), not
deleted.

## What lives here

The hot path: SimHash, Hamming, OR-reduce, Fingerprint256 ops,
SimdKernel, HammingNN top-K, `BitField`, and `SHA256` (content-ID /
seal). Tier-1 of the conformance harness lives here.

The `AuditGate` write gate is **not** here — it lives in `SubstrateLib`
(the orchestration layer) because it validates against
`RowStateAutomaton`; it *consumes* this package's `BitField` and
`SHA256`. The HLC `HLCGenerator` clock-maker lives in `SubstrateTypes`
alongside the `HLC` value type.

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

## Substrate end-state

`SubstrateLib` is RETAINED as the orchestration package of the
four-package end-state (it holds the verb mechanics, the row-state
automaton, and the AuditGate write gate, which fit none of
Types/Kernel/ML; see the 2026-05-29 addendum). The migration re-pointed
every downstream consumer to the appropriate sibling(s) and removed the
temporary `@_exported` re-export shim — it did NOT delete `SubstrateLib`.

## License

MIT OR Apache-2.0 (matches `SubstrateLib`).
