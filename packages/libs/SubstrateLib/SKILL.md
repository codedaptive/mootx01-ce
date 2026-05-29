---
name: substrate-lib-legacy-redirect
description: Use this skill when an agent encounters a reference to the deprecated SubstrateLib monolith — an old import line, an old `use` statement, a doc cross-reference, or any code that points at `packages/libs/SubstrateLib/`. The skill redirects to whichever of the three successor packages (SubstrateTypes, SubstrateKernel, SubstrateML) actually owns the symbol. Trigger this any time an agent is about to add or maintain a SubstrateLib import.
---

# substrate-lib-legacy-redirect — don't import the deprecated monolith

## When this skill applies

An agent is about to:
- Add `.package(path: "../SubstrateLib")` to a Swift `Package.swift`
- Add `substrate-lib = { path = "..." }` to a Rust `Cargo.toml`
- Write `import SubstrateLib` or `use substrate_lib::...`
- Maintain code that already does any of the above

## The one rule

The `SubstrateLib` package is deprecated. Its symbols moved to three
successors. Don't import the monolith; import the specific
successor(s) you need.

## Redirect table

| If you wanted… | Import |
|---|---|
| `Fingerprint256`, `HLC`, `Row`, `RowLite`, `LatticeAnchor`, `AuditEvent`, layout constants, enums, `MatrixF/C/O/T` (storage) | `SubstrateTypes` |
| `SimHash`, Fingerprint256 ops (distance / OR / AND / XOR / prototype), `HammingNN`, `SimdKernel`, `AuditGate`, `HLCGenerator`, SHA-256 seal | `SubstrateKernel` |
| `MatrixDecay`, `MomentSummary`, `BradleyTerry`, `Anomaly`, `InfoTheory`, `TemporalCompression`, `PartialStateRecall`, `FFT`, `NMF`, `EigenvalueCentrality`, `AuditLogFold`, `TierContribution`, `PairingHandshake` | `SubstrateML` |

## How to migrate an import

Swift, before:
```swift
.package(path: "../../libs/SubstrateLib"),
// targets dependencies: ["SubstrateLib"]

import SubstrateLib
```

Swift, after — depend on the subset you actually use:
```swift
.package(path: "../../libs/SubstrateTypes"),
.package(path: "../../libs/SubstrateKernel"),
// targets dependencies: ["SubstrateTypes", "SubstrateKernel"]

import SubstrateTypes
import SubstrateKernel
```

Rust, before:
```toml
substrate-lib = { path = "../../libs/SubstrateLib/rust" }
```

```rust
use substrate_lib::{Fingerprint256, simhash::SimHash};
```

Rust, after:
```toml
substrate-types  = { path = "../../libs/SubstrateTypes/rust" }
substrate-kernel = { path = "../../libs/SubstrateKernel/rust" }
```

```rust
use substrate_types::Fingerprint256;
use substrate_kernel::simhash::SimHash;
```

## What to read

`packages/libs/SubstrateLib/AGENTS.md` for the full redirect mapping
and rationale. The three successor packages each have their own
`AGENTS.md` and `SKILL.md` documenting what lives there.
