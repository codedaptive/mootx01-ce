---
name: substrate-conformance-harness
description: Use this skill when an agent has changed a substrate primitive that is conformance-gated (any of the 22 listed in HARNESS_REFERENCE_v1.0_2026-05-28.md §2), is about to promote a new primitive into the gate, or needs to run the four-way Swift+Rust byte-identity check. Covers the workflow for adding a 23rd primitive (11 steps from HARNESS_REFERENCE §5), running validation, and interpreting CRC mismatches. Trigger this any time the harness CI might go red, or when adding new gated math.
---

# substrate-conformance-harness — keep the 22 primitives byte-identical

## When this skill applies

An agent is about to:
- Change the implementation of a conformance-gated primitive (any
  of the 22 listed in `HARNESS_REFERENCE_v1.0_2026-05-28.md` §2)
- Promote a new primitive into the gate (adding the 23rd)
- Investigate a CRC mismatch in CI
- Port the substrate to a new platform or backend

## The one rule

Every gated primitive runs **four-way**: Swift gen × Swift validate,
Swift gen × Rust validate, Rust gen × Swift validate, Rust gen ×
Rust validate. All four cells must PASS at the same CRC. If any
fails, the languages have drifted.

## Verify a single primitive

From this directory (`docs/validation/substrate_math_performance/test-harness/`):

```bash
cd swift
swift build
.build/debug/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF
.build/debug/validate-vectors ../vectors/<name>.json

cd ../rust
cargo build --release
target/release/validate-vectors ../vectors/<name>.json

target/release/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF --out /tmp/x.json
../swift/.build/debug/validate-vectors /tmp/x.json
target/release/validate-vectors /tmp/x.json
```

Expected: all four `validate-vectors` invocations report `PASS` at
the canonical CRC for that primitive (see `HARNESS_REFERENCE_v1.0_2026-05-28.md`
§2 for the table).

## Verify the full gate

```bash
cd swift
for v in ../vectors/*.json; do
  name=$(basename "$v" .json)
  swift_result=$(.build/debug/validate-vectors "$v" 2>&1 | tail -1)
  rust_result=$(../rust/target/release/validate-vectors "$v" 2>&1 | tail -1)
  printf "%-30s swift=%s  rust=%s\n" "$name" "$swift_result" "$rust_result"
done
```

All 22 primitives must show `PASS` on both sides.

## Add a new primitive to the gate (the 23rd)

The 11-step workflow lives in `HARNESS_REFERENCE_v1.0_2026-05-28.md` §5.
Summary:

1. Write the Swift reference in the appropriate substrate package
   (SubstrateTypes/Sources/SubstrateTypes/<Name>.swift for data
   + algebra; SubstrateKernel/.../<Name>.swift for hardware
   kernels; SubstrateML/.../<Name>.swift for dreaming algorithms;
   SubstrateLib/.../<Name>.swift for orchestration). See
   `primitive-catalog.md` for the per-primitive mapping.
2. Write the Rust mirror at the matching `rust/src/<name>.rs`
   under the same package (or `rust/glref-rust-<name>.rs` under
   SubstrateLib for legacy SubstrateLib primitives)
   (or the appropriate successor package once migration is done).
3. Write the Swift harness primitive at
   `test-harness/swift/Sources/Harness/Primitives/<Name>Primitive.swift`.
   Use `MatrixDecayPrimitive.swift` as a template for transcendental
   primitives, or `FieldPresenceMatrixFPrimitive.swift` for integer-only.
4. Write the Rust harness primitive at
   `test-harness/rust/src/primitives/<name>.rs`. Mirror Swift's
   structure, schema, and case generation. **Iteration order MUST
   match** — floating-point summation is not associative.
5. Register in three places:
   - `test-harness/swift/Sources/Harness/Primitives/PrimitiveRegistry.swift`
   - `test-harness/rust/src/primitives/mod.rs` (the `pub mod <name>;`)
   - `test-harness/rust/src/primitives/registry.rs` (use + descriptor)
6. Build both legs clean: `cargo build --release` and `swift build`.
7. Run four-way conformance (see above).
8. Commit the Swift-generated vector at `vectors/<name>.json` — it's
   the canonical artifact.
9. Update `primitive-catalog.md` with the new tier row and CRC.
10. Update `test-vector-format.md` regen log with a dated entry.
11. Update `.github/workflows/geniuslocus-conformance.yml` (7 places
    that iterate the primitive list).

## If CI goes red — diagnosing a CRC mismatch

Run the four cells individually and note which fail:

- **Swift gen × Swift validate FAIL** → Swift gen has a bug, OR the
  on-disk vector was overwritten with a bad version.
- **Swift gen × Rust validate FAIL but the others pass** → Rust's
  reading of the schema disagrees with Swift's writing. Check JSON
  field names and types.
- **Rust gen × Rust validate FAIL** → Rust generator and Rust
  validator disagree on the algorithm. Usually means one was
  recently changed.
- **Rust gen × Swift validate FAIL** → Rust generator drifted from
  the Swift reference. Compare loop iteration order, intermediate
  rounding, libm calls.

The legacy `audit_log_fold` case taught us: substrate-lib added an
`event_id` field that the Rust harness didn't construct. Build
failure surfaced before CRC drift. Per-symbol additions to
substrate types require updates to harness constructors.

## What to read

- `HARNESS_REFERENCE_v1.0_2026-05-28.md` (in `docs/engineering/`) —
  the 22 primitives indexed by name with file paths and CRCs.
- `primitive-catalog.md` (this directory) — operator-facing,
  machine-readable per-primitive catalog.
- `test-vector-format.md` (this directory) — canonical JSON +
  binary CRC format spec plus full regen log.
- `primitive-walkthrough-SimHash.md` (this directory) — worked
  example of promoting a primitive end-to-end.
