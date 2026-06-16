---
status: in_progress
created: 2026-05-17
last_updated: 2026-06-14
---

# Primitive Walkthrough — SimHash

End-to-end worked example of adding a primitive to the substrate
reference test harness, using SimHash as the example. Read this
once before adding your second primitive.

## What "done" looks like

A primitive is harnessed when all four cells of the conformance
matrix pass:

| Vector file generated in | Validated by Swift | Validated by Rust |
|---|---|---|
| Swift generator | PASS | PASS |
| Rust generator | PASS | PASS |

The CRC32 over the canonical binary serialization of outputs is
identical between the Swift-generated and Rust-generated vector
files for the same seed. This is the "bit-identity gate".

## Worked example: SimHash

The SimHash primitive in this harness calls the real Swift and
Rust reference impls at
`packages/libs/SubstrateTypes/Sources/SubstrateTypes/SimHash.swift`
and `packages/libs/SubstrateTypes/rust/src/simhash.rs` via the
`SubstrateTypes` Swift package and the `substrate-types` Rust
crate respectively. SimHash lives in SubstrateTypes because
algebra-with-types belong with the data types, not the
orchestration layer.

### Step 1 — Decide the input and output schemas

For SimHash:

**Inputs:**
- `block_index` (u8, 0..3) — which 64-bit block this case targets
- `hyperplane_density` (f64) — density parameter for the planes
- `hyperplane_seed` (u64) — RNG seed for plane generation
- `input_bit_length` (u32) — number of bits in the input vector
- `input_vector_words` (array of u64) — the input vector itself

**Output:**
- `block_value` (u64) — the 64-bit SimHash output

These are the minimum fields needed to make a SimHash invocation
reproducible. The SimHash algorithm is deterministic given these
inputs.

### Step 2 — Implement the reference

The reference function takes the input fields and returns the
output fields. It must be DETERMINISTIC: same inputs produce the
same output, every time, on every platform, in both languages.

Current live body (Swift):

```swift
private static func referenceSimHash(inputWords: [UInt64],
                                      hyperplaneSeed: UInt64,
                                      blockIndex: UInt8,
                                      inputBitLength: Int,
                                      density: Double) -> UInt64 {
    let seedBytes = Self.expandSeedTo32(hyperplaneSeed)
    let family = HyperplaneFamily.generate(
        seed: seedBytes,
        blockIndex: Int(blockIndex),
        inputBitLength: inputBitLength,
        density: density)
    return SimHash.block(over: inputWords, family: family)
}
```

Current live body (Rust), produces the same bytes as Swift:

```rust
fn reference_simhash(
    input_words: &[u64],
    hyperplane_seed: u64,
    block_index: u8,
    input_bit_length: usize,
    density: f64,
) -> u64 {
    let seed_bytes = expand_seed_to_32(hyperplane_seed);
    let family = RealHyperplaneFamily::generate(
        &seed_bytes,
        block_index as usize,
        input_bit_length,
        density,
    );
    real_simhash::block(input_words, &family)
}
```

Both ports expand the u64 `hyperplane_seed` to a 32-byte byte
array via the canonical SplitMix64-avalanche expansion (matching
`pairing.rs::expand_seed_to_32` and
`PairingHandshake.swift::expandSeedTo32`) before constructing
the family. The expansion bridges the case schema to the family
constructor: the real `HyperplaneFamily` takes a 32-byte seed
while the harness parameterizes cases by a u64. This is a recorded
limitation of the case schema.

### Step 3 — Write the case generator

The case generator uses `SplitMix64` seeded by the user-provided
`--seed` argument. SplitMix64 is bit-identical between languages
(verified: see Rust's `matches_swift_first_three_outputs` test).

For SimHash the generator produces 32 cases, cycling through the
four blocks (0, 1, 2, 3, 0, 1, 2, 3, ...) eight times. Each case
draws fresh `input_vector_words` and a fresh `hyperplane_seed`
from the RNG. Block 0 uses a 192-bit input vector (3 u64 words);
blocks 1-3 use 64-bit input vectors (1 u64 word).

The generator builds:
- The `inputs` JSON object (canonical, lex-sorted keys, hex-
  encoded values per type)
- The `expected_output` JSON object (the result of running the
  reference on those inputs)
- A `description` string for human debugging
- An `id` like `case_000`, `case_001`, ...

It then feeds the output values into the
`CanonicalBinaryEncoder` IN ORDER and computes the CRC32. The
CRC is stored in `output_crc32` at the top of the JSON file.

### Step 4 — Write the validator

The validator does the inverse: read the JSON, run the reference
on each case's inputs, compare to `expected_output`, feed actual
outputs into the encoder, re-compute CRC, compare to stored CRC.

Per-case mismatch: emit a structured diagnostic naming the
primitive, case ID, field, expected vs actual hex. CRC mismatch:
emit `CRC MISMATCH` and fail. All cases pass + CRC matches: emit
`PASS` and exit 0.

### Step 5 — Register the primitive

Swift, in `Sources/Harness/Primitives/PrimitiveRegistry.swift`:

```swift
public static let all: [PrimitiveDescriptor] = [
    SimHashPrimitive.descriptor,
    // FingerprintPrimitive.descriptor,    // NEW PRIMITIVE GOES HERE
    // HammingPrimitive.descriptor,
]
```

Rust, in `src/primitives/registry.rs`:

```rust
pub fn all_primitives() -> Vec<PrimitiveDescriptor> {
    vec![
        SimHashPrimitive::descriptor(),
        // FingerprintPrimitive::descriptor(),   // NEW PRIMITIVE GOES HERE
        // HammingPrimitive::descriptor(),
    ]
}
```

Both registries name the primitive `"simhash"` (lowercase
snake_case). The same string is the value of the `primitive`
field in the vector file. The validator routes by this string.

### Step 6 — Run the four-way conformance check

Generate from Swift, validate everywhere:

```sh
cd test-harness/swift
swift run gen-vectors --primitive simhash --seed 0xCAFEBABEDEADBEEF
# wrote ../vectors/simhash.json with CRC 0xf44ea16a

swift run validate-vectors ../vectors/simhash.json
# PASS

cd ../rust
cargo run --bin validate-vectors -- ../vectors/simhash.json
# PASS  (Rust reads Swift-generated file, runs Rust reference,
#        CRC and per-case values both match)
```

Generate from Rust, validate everywhere:

```sh
cargo run --bin gen-vectors -- --primitive simhash --seed 0xCAFEBABEDEADBEEF --out /tmp/simhash-rust.json
# wrote /tmp/simhash-rust.json with CRC 0xf44ea16a   (SAME CRC as Swift)

cargo run --bin validate-vectors -- /tmp/simhash-rust.json
# PASS

cd ../swift
swift run validate-vectors /tmp/simhash-rust.json
# PASS
```

All four cells green ⇒ primitive conformant.

### Step 7 — Commit the canonical vector file

The Swift-generated vector file at
`test-harness/vectors/<primitive>.json` is the on-disk source of
truth. Commit it. The Rust-generated file is a CI artifact and is
re-derived at validate time; it should NOT be committed (the CRC
match between Swift- and Rust-generated files is the proof of
bit-identity, not the on-disk persistence of both copies).

CI re-generates the Rust file at every PR and verifies the CRC
still matches the committed Swift file.

## What happens when the two languages disagree

If at any point the Swift CRC and the Rust CRC differ for the
same seed, one of three things is true:

1. The two reference implementations have diverged. Compare the
   functions side by side; find the line that differs.
2. The canonical binary encoder has drifted (e.g., one language
   forgot to LE-encode a u64). Inspect a single case's encoded
   bytes in both languages.
3. The cookbook section is ambiguous and both implementations
   are "correct" against different readings. Revise the cookbook
   section to remove the ambiguity, then re-run both
   implementations.

Case 3 is the main payoff of authoring both ports against shared
test vectors: a single-language implementation silently papers
over spec ambiguities, while two independent ports surface them
as CRC divergence in CI.

## Adding a new primitive — checklist

- [ ] Land Swift reference in the appropriate substrate package:
      `packages/libs/SubstrateTypes/Sources/SubstrateTypes/<Name>.swift`
      (data + algebra),
      `packages/libs/SubstrateKernel/Sources/SubstrateKernel/<Name>.swift`
      (hardware kernels),
      `packages/libs/SubstrateML/Sources/SubstrateML/<Name>.swift`
      (dreaming algorithms), or
      `packages/libs/SubstrateLib/Sources/SubstrateLib/<Name>.swift`
      (orchestration). See `primitive-catalog.md` for the
      per-primitive package mapping.
- [ ] Land Rust reference at the matching `rust/src/<name>.rs`
      under the same package.
- [ ] Decide input and output schema; document inline at top of
      the primitive harness file
- [ ] Implement `<Name>Primitive.swift` under
      `test-harness/swift/Sources/Harness/Primitives/`
- [ ] Implement `<name>.rs` under `test-harness/rust/src/primitives/`
- [ ] Register in Swift's `PrimitiveRegistry.swift`
- [ ] Register in Rust's `primitives/registry.rs`
- [ ] Run the four-way conformance check (see § 6 above)
- [ ] Commit the Swift-generated vector file under
      `test-harness/vectors/<name>.json`
- [ ] Update the CI matrix in the substrate conformance workflow
      under `.github/workflows/` (add the primitive to every step
      whose matrix iterates over primitives)
- [ ] Add the primitive to `primitive-catalog.md` with its CRC,
      reference section, and source-file paths

## Cross-language fixtures available to the harness

These are guaranteed bit-identical between Swift and Rust and
suitable for use in any primitive's case generator:

| Fixture | Source | Property |
|---|---|---|
| `SplitMix64` | `Harness/Core/SplitMix64.swift` and `harness/splitmix64.rs` | Same seed ⇒ same u64 stream. Verified in tests. |
| `CanonicalBinaryEncoder` | Same names | Same input ⇒ same bytes. |
| `CRC32` | Same names | Same bytes ⇒ same u32. |
| `HexCoding` / `hex` | Same names | Same bytes ⇒ same hex string. |
| `JSON canonical writer` | `Harness/Core/VectorFile.swift` and `harness/vector_file.rs` | Same `VectorFile` ⇒ same JSON bytes (modulo `generated_at`). |

Use these by import; do not re-implement them per primitive.
