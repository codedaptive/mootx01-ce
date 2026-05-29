// SubstrateLibExports.swift
//
// Phase 6 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
//
// Re-export migrated SubstrateTypes + SubstrateKernel + SubstrateML
// symbols so downstream consumers (the 10 kits) don't need to update
// their imports during the per-symbol migration. When a downstream
// kit does `import SubstrateLib` it transparently gets every type,
// kernel, and ML algorithm that's been moved into the new packages.
//
// After the atomic swap at the end of the refactor, consumers
// re-point their `Package.swift` from `SubstrateLib` to
// `SubstrateTypes` / `SubstrateKernel` / `SubstrateML` directly
// and this file goes away with the legacy package.

@_exported import SubstrateTypes
@_exported import SubstrateKernel
@_exported import SubstrateML
