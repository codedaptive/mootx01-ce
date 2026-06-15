---
name: substrate-types
description: Use this skill when working with substrate row shape — declaring, serializing, or holding a row without computing on it. Covers Fingerprint256 (the 256-bit four-block container), HLC (hybrid logical clock value), Row / RowLite, LatticeAnchor, AuditEvent (struct shape), MatrixF/C/O/T (storage containers), layout constants (BlockMask, RowBitmaps, BitVector216), TimeRange, and substrate enums (MutationKind, PairingScope, GeneratedByClass, NounType, RowStateValue). Trigger this whenever an agent is about to declare a substrate struct field, define a CloudKit record, write a wire-format encoder, or stub out an audit event. Do NOT trigger for algorithms — those belong to SubstrateKernel or SubstrateML.
---

# substrate-types — pure shape for the substrate

## When this skill applies

An agent is about to:
- Declare a substrate-shaped field on a struct or class
- Serialize a row to or from CloudKit / disk / wire format
- Define a stub `AuditEvent`, `HLC`, or `Fingerprint256` for a test
- Add a new enum case to a substrate vocabulary
- Reference a layout constant (block widths, bit positions)

## The one rule

If your code computes anything on the data — a Hamming distance, a
fingerprint construction, a decay, a fold, a SHA-256 — you are in
the wrong package. This package holds shape only. The algorithms
live in `SubstrateKernel` (hot path) or `SubstrateML` (cold path).

## How to use

Swift:
```swift
import SubstrateTypes

let fp  = Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
let hlc = HLC(physicalTime: now, logicalCount: 0, nodeID: 1)
let row = Row(id: uuid, fingerprint: fp, /* ... */)
```

Rust:
```rust
use substrate_types::{Fingerprint256, HLC, Row};

let fp  = Fingerprint256 { block0: 0, block1: 0, block2: 0, block3: 0 };
let hlc = HLC { physical_time: now, logical_count: 0, node_id: 1 };
```

Package wiring:
```swift
// Package.swift
.package(path: "../SubstrateTypes"),
// targets dependencies: ["SubstrateTypes"]
```

```toml
# Cargo.toml
substrate-types = { path = "../../SubstrateTypes/rust" }
```

## What to read

`packages/libs/SubstrateTypes/AGENTS.md` for the full type-by-type
reference and code examples. `docs/engineering/HARNESS_REFERENCE.md`
§6.1 for the canonical breakdown of what lives here.
