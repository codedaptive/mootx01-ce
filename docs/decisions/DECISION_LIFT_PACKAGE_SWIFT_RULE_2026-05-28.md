---
status: decided
question: May a kit declare a dependency on another in-repo kit in its Package.swift / Cargo.toml?
authors: MOOTx01 maintainers
date: 2026-05-28
relates_to:
  - docs/concepts/TOPOLOGY.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
supersedes: none
context:
  - The kits compose bottom-up; a downstream kit that genuinely needs an upstream kit must be able to declare that dependency in its manifest.
  - A blanket "never edit Package.swift / Cargo.toml" rule blocked legitimate in-repo layering and is lifted here under controlled conditions.
---

# Lift the Package.swift / Cargo.toml dependency rule

## Context

The substrate is a stack of composable kits that depend bottom-up —
downstream depends on upstream, never the reverse. For one kit to
consume another in-repo kit, its build manifest (`Package.swift` for the
Swift port, `Cargo.toml` for the Rust port) must declare that
dependency. An earlier blanket prohibition on editing these manifests
prevented legitimate in-repo layering from being expressed at all.

## Decision

A kit MAY declare a dependency on another **in-repo** kit in its
`Package.swift` and `Cargo.toml` when a recorded architectural decision —
a cookbook section, an ADR, or a decision record — requires it. The two
ports move together: a dependency added on one side is added on the
other in the same change.

The constraints that remain in force:

- **External (third-party) dependencies stay prohibited** without
  explicit per-package approval. The zero-external-dependency doctrine
  for kits is unaffected; Metal is a system framework used for GPU
  compute, not a package dependency.
- **Layering must not invert.** A dependency always points upward
  (downstream → upstream). A manifest edit that would make an upstream
  kit depend on a downstream kit is rejected.
- **Cosmetic or stylistic edits** to these manifest files are out of
  scope; only dependency declarations backed by a recorded decision are
  in scope.

## Disposition

Decided. In-repo kit dependencies are declared in the manifests under the
constraints above; external dependencies and layering inversions remain
prohibited.

## Status

Decided — 2026-05-28.
