# SubstrateTypes

Pure substrate data types. The shape every kit speaks. Zero compute,
zero transcendentals, zero I/O — if it does any of those, it lives
in `SubstrateKernel` or `SubstrateML` instead.

## When to use this package

Use this when you need to **hold** or **serialize** a substrate row
but not operate on it. Typical consumers: storage adapters (PersistenceKit,
ConvergenceKit mapping to CloudKit), wire-format encoders, code that
needs to declare a `Row` field in a struct.

If you need to *compute* a fingerprint, distance, or fold an audit
log, you want `SubstrateKernel` or `SubstrateML`.

## DON'T reinvent these — they're here

| You need… | Use |
|---|---|
| A 256-bit four-block fingerprint container | `Fingerprint256` |
| The hybrid logical clock as a value | `HLC` |
| A row's content-tier reference | `LatticeAnchor` |
| The on-the-wire shape of an audit event | `AuditEvent` (struct only) |
| A full noun row | `Row` (production) or `RowLite` (harness) |
| A noun-type tag | `NounType` |
| A row state value | `RowStateValue` |
| Population stats matrix containers | `MatrixF` / `MatrixC` / `MatrixO` / `MatrixT` |
| Bitmap layout constants | `BlockMask`, `RowBitmaps`, `BitVector216` |
| A half-open time interval | `TimeRange` |
| Mutation kind tag | `MutationKind` |
| Federation scope tag | `PairingScope` |
| Generated-by class | `GeneratedByClass` |

These are the types. The verbs that operate on them live elsewhere.

## Importing

Swift `Package.swift`:
```swift
dependencies: [
    .package(path: "../SubstrateTypes"),
],
targets: [
    .target(name: "YourKit", dependencies: ["SubstrateTypes"]),
],
```

Then in source:
```swift
import SubstrateTypes

let fp = Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
let hlc = HLC(physicalTime: now, logicalCount: 0, nodeID: 1)
```

Rust `Cargo.toml`:
```toml
[dependencies]
substrate-types = { path = "../../SubstrateTypes/rust" }
```

Then in source:
```rust
use substrate_types::{Fingerprint256, HLC, Row, AuditEvent};

let fp = Fingerprint256 { block0: 0, block1: 0, block2: 0, block3: 0 };
let hlc = HLC { physical_time: now, logical_count: 0, node_id: 1 };
```

## Wire format helpers

`Fingerprint256` and `HLC` carry deterministic wire encodings.
Always use the named methods — never roll your own byte layout.

```swift
let bytes: [UInt8] = fp.wireBytes      // 32 bytes
let parsed = try Fingerprint256(wireBytes: bytes)

let hlcBytes: [UInt8] = hlc.wireBytes  // 16 bytes LE
```

```rust
let bytes: [u8; 32] = fp.wire_bytes();
let parsed = Fingerprint256::from_wire_bytes(&bytes)?;

// HLC wire bytes are 8 LE phys + 4 LE log + 4 LE node = 16 bytes
```

> **Gotcha (Swift+Rust API asymmetry).** Rust's `HLC` does not yet
> expose a `wire_bytes()` method on the type itself — the encoding
> is computed inline in callers and in the harness. If you need
> HLC wire encoding from Rust, encode `physical_time` (i64 LE) +
> `logical_count` (i32 LE) + `node_id` (i32 LE) inline.

## What does NOT belong in this package

Any algorithm. Any transcendental. Any I/O. Any SIMD. Any matrix
update that does math on the cells. If you're tempted to add one,
you want `SubstrateKernel` or `SubstrateML` instead — see those
packages' `AGENTS.md`.

## Conformance

This package's types appear in conformance-gated primitives across
both `SubstrateKernel` and `SubstrateML`. The struct layouts and
wire encodings are PART of the conformance contract — changing a
field order, adding a field, or altering the wire encoding will
break the harness gate for every dependent primitive.

If you need to extend a type, follow the field-extension protocol:
add at the end, never reorder, and update the wire encoding tests.

## Related docs

- `../../../docs/engineering/HARNESS_REFERENCE.md` §6.1
  — what lives here.
- `../../../docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`
  §2 (data model), §3 (fingerprint), §5 (audit log).

## License

MIT OR Apache-2.0.
