# concordance_audit

Mechanical completeness check for the Swift/Rust **concordance** discipline.

Every kit/lib under `packages/libs/*` and `packages/kits/*` ships a Swift port
and a Rust port that must agree. Each package's interface doc
(`docs/reference/<NAME>_INTERFACE*.md`) carries a `## Swift/Rust Concordance`
section: a table mapping each public contract concept Swift↔Rust. Drift creeps
back whenever a new public type is added on one side without a concordance row.
This tool detects that drift mechanically.

## What it does

Per package, the audit:

1. Finds the package's interface doc (`<UPPERCASEDNAME>_INTERFACE*.md`; if a
   package has multiple versioned docs, e.g. NeuronKit v0.8 / v0.85, it
   prefers the one carrying a concordance section, newest filename wins).
2. Parses **every** `Swift/Rust Concordance` section in that doc (some docs
   carry several — GeniusLocusKit has three) and collects the set of
   backtick-quoted identifier names mentioned anywhere in those tables.
3. Extracts **top-level public declarations** from the code:
   - Swift: `public struct|enum|protocol|class|actor|typealias <Name>` in
     `Sources/**` (column-0 anchored — nested members are out of scope).
   - Rust: `pub struct|enum|trait|type <Name>` in `rust/src/**`
     (top-level `pub` only; `pub(crate)` is excluded; `pub use|const|static`
     are not contract types and are excluded). A **PascalCase** `pub mod
     <Name>` is also matched: it is the sanctioned namespace-as-type idiom
     (a Swift caseless `enum` of constants ↔ a Rust `pub mod` of `pub const`s,
     e.g. SubstrateML `VizGraphSignals`). **Lowercase** `pub mod` (the normal
     Rust code-organization convention) is NOT contract surface and stays
     excluded — the uppercase initial is the discriminator.
4. Reports, per package, every public type present in CODE but ABSENT from the
   concordance table — the drift signal. Packages with **no** concordance
   section at all are reported separately.

It does **not** edit any docs. Closing the gaps is per-kit mission work.

## Running it

```sh
# Advisory report over the whole tree (always exits 0):
python3 packages/scripts/concordance_audit/concordance_audit.py

# Scope to one or more packages (used by Adams post-flight on changed kits):
python3 packages/scripts/concordance_audit/concordance_audit.py --package LocusKit --package VectorKit

# CI-gate mode: nonzero exit if any scanned package has gaps or no section:
python3 packages/scripts/concordance_audit/concordance_audit.py --strict

# Also audit top-level free functions (off by default — see philosophy):
python3 packages/scripts/concordance_audit/concordance_audit.py --include-fn
```

No dependencies beyond the Python 3 standard library. Paths resolve relative
to the repo root, so it can be run from anywhere.

## Concept, not every symbol — the philosophy

The rule being enforced is **"a new public contract _type_ must have a
concordance row,"** not "every public symbol must be itemized." The
concordance is keyed on the type/symbol *name* — the thing both ports must
agree on. So a type counts as documented if its bare name appears anywhere in
the concordance tables (Swift column, Rust column, or notes), which tolerates
the several table shapes in use (schema-table rows, type rows, signature rows).

Free functions (`pub fn`) are **opt-in** via `--include-fn`. The mission spec
wrote the Rust pattern as `... type fn?` — the `?` marks `fn` optional. Free
helper functions are a large, noisy surface (167 top-level `pub fn` in the
tree at time of writing) and dilute the type-contract signal, so the default
keys on types only. Swift free functions (`public func`) are never scanned —
Swift's contract surface for concordance purposes is its named types.

## The ignore-list

`ignore.txt` exempts names that legitimately **cannot** carry a concordance
row. Format is `Name | reason`, one per line. The policy is strict:

- **Platform-bound bindings** with no counterpart in the other port — e.g.
  CloudKit types (`ConvergenceKitCloudKit` is Swift-only; CloudKit is an Apple
  framework) and `MetalKernel` (Apple GPU; the Rust port uses scalar/BLAS/NEON).
- **Dev/test fixtures** that are not contract surface.

The ignore-list is **not** a way to silence real drift. A missing row for a
genuine cross-port contract type is real work for a per-kit mission, not an
ignore entry. Keep the list short; every entry must state why no row can exist.

## CI gate

The gate is live. `.github/workflows/concordance.yml` runs
`concordance_audit.py --strict` on every pull request that touches
`packages/**`, `docs/reference/*_INTERFACE*.md`, or this script directory.
A nonzero exit blocks merge. `cd packages && make concordance` runs the
same check locally before you push.
