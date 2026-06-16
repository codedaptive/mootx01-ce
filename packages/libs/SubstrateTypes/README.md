# SubstrateTypes

Layer 1 — pure data types of the four-package SubstrateLib split.

**Status:** built; four-package split mid-migration (per
`docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
Phase 6 and the 2026-05-29 addendum). Symbols here hold real code;
remaining symbols are still resident in `SubstrateLib`, which is
RETAINED as the orchestration package (the four-package end-state),
not deleted. A temporary `@_exported` re-export keeps downstream kits
compiling until consumers re-point precisely.

## What lives here

Pure shape: structs, enums, layout constants. Zero compute, zero transcendentals, zero I/O. Any kit that just needs to talk substrate-shape (e.g. ConvergenceKit) depends only on this.

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

Swift (SPM):       `.package(path: "../SubstrateTypes")`
Rust  (Cargo):     `{ path = "../../SubstrateTypes/rust" }`

## Layout

```
SubstrateTypes/
├── Package.swift                          (Swift SPM)
├── Sources/SubstrateTypes/                          (Swift sources)
├── Tests/SubstrateTypesTests/                     (Swift tests)
└── rust/
    ├── Cargo.toml                         (Rust crate)
    └── src/lib.rs
```

## Build status during refactor

`SubstrateLib` is RETAINED as the orchestration package of the
four-package end-state (it holds the verb mechanics and the row-state
automaton, which fit none of Types/Kernel/ML; see the 2026-05-29
addendum). The migration re-points the downstream consumers to the
appropriate one(s) of SubstrateTypes's siblings and removes the
temporary `@_exported` re-export shim — it does NOT delete
`SubstrateLib`.

## License

MIT OR Apache-2.0 (matches `SubstrateLib`).
