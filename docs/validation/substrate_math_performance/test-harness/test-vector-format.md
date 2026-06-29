---
status: in_progress
created: 2026-05-16
last_updated: 2026-06-20
---

# Substrate Test Vector Format Specification

Format for cross-language conformance test vectors used by the
mootx01 substrate reference implementations. Both the Swift and Rust
ports generate vectors in this format and validate against
vectors in this format. CRC bit-identity between languages is
the conformance gate.

**Format version: 1**

## Goals

1. **Self-describing.** A vector file carries enough metadata
   that a validator can route it to the right primitive,
   identify the cookbook section it tests, and recognize format
   drift.
2. **Deterministic.** Same primitive, same seed, same harness
   version ⇒ bit-identical vector file. Re-running the generator
   produces a file the OS sees as identical (modulo
   `generated_at`).
3. **Cross-language.** Both Swift and Rust must produce the same
   file from the same primitive + seed. JSON keys and number
   formats are constrained to a canonical form (see § Canonical
   serialization below).
4. **Human-readable.** Engineers should be able to inspect a
   failing vector case by reading the JSON.
5. **Bit-identity gating via binary CRC.** JSON is for humans;
   CRC32 is computed over a canonical binary serialization of
   the OUTPUT values (see § CRC computation below). The CRC is
   the actual conformance check; the JSON is the audit trail.

## Directory layout

```
substrate_math_performance/
├── test-harness/
│   ├── swift/      Swift generator + validator sources
│   ├── rust/       Rust generator + validator sources
│   ├── vectors/    Generated vector files; one per primitive
│   ├── test-vector-format.md       This spec
│   ├── primitive-walkthrough-SimHash.md   Worked example
│   └── primitive-catalog.md        Live catalog with CRCs
└── ...
```

Each primitive owns one vector file. Currently committed:

```
vectors/
  anomaly.json
  audit_log_fold.json
  bitwise.json
  bradley_terry.json
  fft.json
  fingerprint.json
  hamming.json
  hamming_nn.json
  hlc.json
  info_theory.json
  lattice.json
  nmf.json
  or_reduce.json
  pairing_handshake.json
  partial_state_recall.json
  simhash.json
  temporal_compression.json
  tier_contribution.json
```

For the live catalog with CRCs and source file cross-references,
see `primitive-catalog.md`.

## File schema

```json
{
  "format_version": "1",
  "primitive": "simhash",
  "cookbook_section": "§3.6",
  "generator": {
    "language": "swift",
    "harness_version": "1.0.0",
    "reference_file": "SubstrateTypes/Sources/SubstrateTypes/SimHash.swift"
  },
  "seed": "0xCAFEBABE",
  "generated_at": "2026-05-16T20:00:00Z",
  "case_count": 100,
  "output_crc32": "0xABCD1234",
  "cases": [
    { "id": "case_000", "description": "...", "inputs": {...}, "expected_output": {...} },
    { "id": "case_001", "description": "...", "inputs": {...}, "expected_output": {...} }
  ]
}
```

### Top-level fields

| Field | Type | Required | Description |
|---|---|---|---|
| `format_version` | string | yes | `"1"` for this spec. Bumped on incompatible changes. |
| `primitive` | string | yes | Lowercase snake_case name. Must match a known primitive registered with the harness. |
| `cookbook_section` | string | yes | The `§N.N` reference from the cookbook. Audit trail. |
| `generator` | object | yes | Provenance of this file. See below. |
| `seed` | string | yes | Hex-encoded 64-bit seed used by the case generator. Always `"0x..."` lowercase. |
| `generated_at` | string | yes | ISO 8601 UTC timestamp. Informational only; not part of CRC. |
| `case_count` | integer | yes | `len(cases)`. Sanity check for partial-file detection. |
| `output_crc32` | string | yes | Hex-encoded CRC32 over the canonical binary serialization of all case outputs (in case order). `"0x"` prefix, 8 hex digits, lowercase. The conformance gate. |
| `cases` | array | yes | Test cases. See below. |

### Generator object

| Field | Type | Required | Description |
|---|---|---|---|
| `language` | string | yes | `"swift"` or `"rust"`. The language whose scalar reference produced this file. |
| `harness_version` | string | yes | Semver of the generator binary. Bumped when generator logic changes. |
| `reference_file` | string | yes | Filename of the reference implementation, for audit trail. |

### Case object

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | `case_NNN` where NNN is the zero-padded case index. |
| `description` | string | yes | Short human-readable description. Not part of CRC. |
| `inputs` | object | yes | Primitive-specific input payload. Schema per primitive (see primitive walkthroughs). |
| `expected_output` | object | yes | Primitive-specific output payload. Schema per primitive. CRC-validated. |

### Per-primitive payload schemas

Each primitive defines its own `inputs` and `expected_output`
schema. The schemas are documented inline with the primitive's
reference implementation and in
`primitive-walkthrough-SimHash.md` (worked example).

## Type encodings

JSON cannot represent some types portably. The harness uses
these encodings:

| Logical type | JSON encoding | Example |
|---|---|---|
| `u8`, `u16`, `u32`, `u64` | hex string `"0x..."`, lowercase, no padding except for fixed-width fields | `"0xdeadbeef"` |
| `i8`, `i16`, `i32`, `i64` | decimal integer (JSON number) | `-42` |
| `f64` | hex string of the IEEE-754 bit pattern in LE byte order, `"0x..."`, exactly 16 hex digits | `"0x0000000000001040"` (= 4.0) |
| `bool` | JSON boolean | `true` |
| `Option<T>` | `null` for None, T-encoded for Some | `null` or `"0x1234"` |
| `Vec<T>` / array | JSON array of T-encoded values | `["0x01", "0x02"]` |
| `Fingerprint256` | hex string `"0x..."`, exactly 64 hex digits (32 bytes LE) | `"0x000...01"` |
| `HLC` | hex string `"0x..."`, exactly 32 hex digits (16 bytes LE wire form: 8 bytes i64 physical_time, 4 bytes i32 logical_count, 4 bytes i32 node_id) | `"0x00f04cbcc11900000000000001000000"` |
| UUID (RowID) | hex string `"0x..."`, exactly 32 hex digits (16 bytes LE) | |

f64 must be hex-encoded because JSON number parsing is not
specified to round-trip every f64 value bit-exactly. Hex encoding
of the IEEE-754 bit pattern guarantees lossless transport.

## Canonical serialization

Two distinct canonical forms are used.

### JSON canonical form (for file content)

The vector file as written to disk uses these rules:
- Keys in objects are sorted lexicographically.
- Two-space indentation, Unix line endings (`\n`).
- Numbers in JSON-standard form (no leading zeros, no trailing
  decimals, no `+` sign, no leading `+`).
- Hex strings always lowercase with `"0x"` prefix.
- Trailing newline at end of file.

This makes vector files diff-friendly and minimizes spurious
churn in version control.

### Binary canonical form (for CRC computation)

The CRC32 in `output_crc32` is computed over a binary
serialization of the OUTPUTS only, in case order, with NO
DELIMITERS. The binary encoding per logical type:

| Logical type | Binary encoding |
|---|---|
| `u8` | 1 byte LE |
| `u16` | 2 bytes LE |
| `u32` | 4 bytes LE |
| `u64` | 8 bytes LE |
| `i8`..`i64` | LE two's complement, same width |
| `f64` | 8 bytes IEEE-754 LE |
| `bool` | 1 byte (`0x00` or `0x01`) |
| `Option<T>` | 1 byte tag (`0x00` None, `0x01` Some) + T encoding if Some |
| `Vec<T>` / array | 4 bytes u32 LE length + concatenated T encodings |
| `Fingerprint256` | 32 bytes (wire_bytes from the reference) |
| `HLC` | 16 bytes (wire_bytes from the reference: 8 phys + 4 log + 4 node, all LE) |
| UUID | 16 bytes LE |
| String | 4 bytes u32 LE length + UTF-8 bytes |

Within a case, the output fields are serialized in alphabetical
key order. Across cases, the serializations are concatenated in
case order (case_000, case_001, ...).

This binary form is opaque; engineers debugging a CRC mismatch
read the JSON and inspect individual fields, not the binary.

## CRC computation

Algorithm: CRC-32/ISO-HDLC (the standard zlib/IEEE-802.3 CRC32).

| Property | Value |
|---|---|
| Polynomial | `0xEDB88320` (reversed `0x04C11DB7`) |
| Initial value | `0xFFFFFFFF` |
| Input reflection | `true` (byte-reversed input) |
| Output reflection | `true` |
| Output XOR | `0xFFFFFFFF` |

This is the default `crc32` everywhere: Python `zlib.crc32`,
Rust `crc32fast`, Swift via raw implementation (see
`swift/Sources/CrcUtil.swift`). The harness ships its own
implementation in each language for zero-dependency builds.

Stored as `"0x"` + 8 lowercase hex digits in `output_crc32`.

## Validation procedure

A validator reads a vector file and:

1. Parses JSON. Rejects on schema violation (missing required
   field, unknown primitive, wrong format_version).
2. Iterates cases in order. For each case:
   - Runs the local-language reference implementation on
     `inputs`.
   - Compares the reference output to `expected_output` field by
     field. Field comparison uses the canonical-binary encoding
     for f64 (no FP tolerance — bit-identity required).
   - On mismatch: emits a structured error pointing at the
     primitive, case ID, field, expected vs actual hex.
3. After all cases pass: re-computes the CRC32 over the
   canonical binary serialization of all outputs and compares to
   `output_crc32`. Mismatch indicates either a generator bug or
   a non-canonical input file.
4. Emits `PASS` (exit 0) or `FAIL` (exit 1) for CI consumption.

A vector file generated in Swift validates in Rust and vice
versa. CI runs both validators on both languages' vector files
and fails on any mismatch. The four-way matrix is:

| Vector file generated in | Validated by Swift | Validated by Rust |
|---|---|---|
| Swift generator | must PASS | must PASS |
| Rust generator | must PASS | must PASS |

The two data rows × two validator columns encode the four named
cells: Swift-gen/Swift-validate, Swift-gen/Rust-validate,
Rust-gen/Swift-validate, Rust-gen/Rust-validate. All four cells green ⇒ the primitive is conformant. Any cell
red ⇒ either the spec is ambiguous (both generators disagree on
expected output) or one of the implementations has a bug.

## Stability promise

Format version 1 is stable. Any change that breaks vector files
generated before the change requires bumping `format_version`
and a migration note in this document. Adding optional fields
(with default behavior identical to omission) is non-breaking
and does not require a version bump.

The seed parameter is part of the conformance contract: vector
file produced by `gen-vectors --primitive simhash --seed
0xCAFEBABE` is reproducible bit-for-bit (in canonical binary
form) by any implementation that follows this spec. The
`generated_at` timestamp is excluded from CRC.

## Vector regeneration log

This section records events that legitimately invalidate
previously-published vector CRCs. Each entry names the
primitive, the date, the reason, and the old and new CRC.

### 2026-05-17 - simhash - real reference wire-up

The initial simhash vector file (CRC `0xcafd725b`) was generated
against a byte-identical stub reference (`reference_simhash`),
used to validate the harness conformance machinery before the
real reference implementations were assembled as a Swift package
and Rust crate.

With both the Swift reference package (macOS 14+) and the Rust
reference crate now building cleanly and
publishing their `SimHash.block(over:family:)` /
`simhash::block(v, family)` entry points, the harness primitives
were rewired to delegate to the real impls. The harness still
parameterizes cases by a `u64` `hyperplane_seed`; both languages
expand that 64-bit seed to a 32-byte byte array via the canonical
SplitMix64-avalanche expansion (matching `pairing.rs::expand_seed_to_32`
and `PairingHandshake.swift::expandSeedTo32`), then call
`HyperplaneFamily::generate` and `simhash::block`.

A cross-language asymmetry was found and fixed during this
regeneration pass: `HyperplaneFamily::generate` computed
`(u64::MAX as f64 * density) as u64` for the active-bit
threshold. At `density = 1.0`, `Double(UInt64.max)` rounds up
beyond `UInt64.max` representable range; Swift trapped, Rust
saturated. Both ports now treat `density >= 1.0` as "every bit
active" without the floating-point round-trip, restoring
bit-identical cross-language behavior.

- Old CRC (stub-derived): `0xcafd725b`
- New CRC (real reference): `0xf44ea16a`
- Vector cases: 32 (unchanged)
- Seed: `0xCAFEBABEDEADBEEF` (unchanged)
- Four-way conformance: Swift gen + Swift validate, Swift gen +
  Rust validate, Rust gen + Swift validate, Rust gen + Rust
  validate. All four PASS.

This is the only legitimate way the simhash CRC may change.
A future CRC change requires another entry in this log and the
reason it does not violate the stability promise.

### 2026-05-17 - hamming - batched-case extension

The `SubstrateKernel` trait (Rust) and protocol (Swift) gained
three batched op signatures with loop-based default impls:
`hamming_distance_batch`, `simhash_block_batch`, `or_reduce_batch`.
Default impls preserve byte-for-byte equivalence with sequential
pair-at-a-time loops, so the trait extension is non-breaking and
every conformer gets correct batched behavior automatically.

The `hamming` primitive vector was extended to cover the batched
path. Eight new cases were appended after the existing 32
pair-at-a-time cases, one per `batch_size` in
`{0, 1, 2, 4, 8, 16, 32, 64}`. Batched cases test the all-blocks
variant of `hamming_distance_batch` (the batched API has no
per-call blocks_bitmask; the existing pair cases retain mask
coverage).

Batched-case canonical binary encoding: u32 LE length prefix
followed by N u32 LE distances. The length prefix is the
distinguishing byte stream prefix that keeps batched and pair
encodings disjoint within the same vector file.

Four-way conformance verified: Swift gen × Swift validate, Swift
gen × Rust validate, Rust gen × Swift validate, Rust gen × Rust
validate. All four PASS. Full 18-primitive sweep still passes.
Rust reference unit tests: 142/142 pass.

- Old CRC (pair-only): `0xf0e157b7`
- New CRC (pair + batched): `0xce4deb85`
- Vector cases: 32 → 40 (32 pair + 8 batched)
- Seed: `0xCAFEBABEDEADBEEF` (unchanged)

The `simhash` and `or_reduce` primitives receive the same
extension; their CRCs change when that lands and are logged in
their own entries below.

### 2026-05-17 - simhash - batched-case extension

The `simhash` primitive vector was extended to cover the batched
path, mirroring the prior `hamming` extension. Eight new cases
were appended after the existing 32 pair-at-a-time cases, one
per `batch_size` in `{0, 1, 2, 4, 8, 16, 32, 64}`. Each batched
case fixes one family (block_index, hyperplane_seed, density,
input_bit_length) and feeds N input vectors of identical
word_count through `simhash_block_batch`. Output is `[u64]` of
block values.

This schema (one family, many inputs) matches the architectural
shape used by an AMX-via-BNNS backend: one hyperplane matrix
applied to a batch of input vectors via `BNNSDirectApplyFullyConnectedLayerBatch`.
The scalar default impl loops over `simhash_block`; the
conformance contract is byte equality with that loop in at-rest
LE form.

Batched-case canonical binary encoding: u32 LE length prefix
followed by N u64 LE block values. The length prefix keeps
batched and pair byte streams disjoint.

Four-way conformance verified. Full 18-primitive sweep still
passes.

One validator bug was found and fixed during this regeneration:
Swift's `validateBatchedCase` initially passed the raw 8-byte
`hyperplane_seed` to `HyperplaneFamily.generate(seed:)`, which
requires the 32-byte expanded seed. The generate path already
called `expandSeedTo32`; the validate path was missing it.
Corrected to match.

- Old CRC (pair-only): `0xf44ea16a`
- New CRC (pair + batched): `0xddd18e12`
- Vector cases: 32 → 40 (32 pair + 8 batched)
- Seed: `0xCAFEBABEDEADBEEF` (unchanged)

The `or_reduce` primitive receives the same extension next.

### 2026-05-17 - or_reduce - batched-case extension

The `or_reduce` primitive vector was extended to cover the
batched path, completing the batched-kernel rollout. Eight new cases
were appended after the existing 32 pair-at-a-time cases, one
per `batch_size` in `{0, 1, 2, 4, 8, 16, 32, 64}`.

The batched schema is shape-different from the pair schema. A
pair case reduces ONE cohort of fingerprints to ONE result. A
batched case reduces M independent cohorts in a single call,
producing M results. To keep cases deterministic, each batched
case fixes an `inner_count` (the per-cohort size, cycling
through `{1, 2, 4, 8}`) and produces `batch_size` cohorts of that
size. The kernel's `or_reduce_batch` returns `batch_size`
reduced fingerprints.

Batched-case canonical binary encoding: u32 LE length prefix
followed by N Fingerprint256 (each as 4 u64 LE = 32 bytes).

Four-way conformance verified. Full 18-primitive sweep still
passes. Rust reference unit tests: 142/142 pass.

- Old CRC (pair-only): `0xf5c60f3f`
- New CRC (pair + batched): `0x4ee84d73`
- Vector cases: 32 → 40 (32 pair + 8 batched)
- Seed: `0xCAFEBABEDEADBEEF` (unchanged)

The conformance harness now exercises the batched
path of all three batched kernel ops (`hamming_distance_batch`,
`simhash_block_batch`, `or_reduce_batch`). A stress-test binary
produces per-(op, batch_size) latency tables that feed the
learned dispatcher.

### 2026-05-17 - stress-test binary

New `stress-test` binary in both ports (`rust/src/bin/stress_test.rs`
and `swift/Sources/StressTest/main.swift`). Measures per-(op,
batch_size, mode) latency for the three batched kernel ops
against the scalar kernel. Two modes per (op, batch_size):

- `batched`: the trait/protocol's batched method (currently the
  default impl, since no override exists yet).
- `sequential`: explicit caller-side loop calling the
  pair-at-a-time op once per item.

Batch sizes: `{1, 2, 4, 8, 16, 32, 64, 128, 256}`. Warmup 50ms,
measurement budget 200ms per cell. Output is structured JSON
with iterations, ns_per_call_min, ns_per_call_mean,
ns_per_call_stddev for each cell, plus platform metadata
(arch, os) and provenance (language, kernel, harness_version,
seed).

The stress-test does NOT participate in the conformance gate
and its results are NOT committed to the repo (they are
hardware-specific and stale on first compile on a different
machine). The JSON schema IS committed so consumers (the future
learned dispatcher) have a stable contract.

Usage:
```
cargo run --release --bin stress-test -- --out /tmp/stress-rust.json
.build/release/stress-test --out /tmp/stress-swift.json
```

Observation on first run (Apple M-series, scalar kernel):
batched and sequential modes are within measurement noise while
the default batched impl IS a loop. The infrastructure is in
place to detect the gap once specialized backends override the
batched methods.

Full 18-primitive conformance sweep still passes. Rust
reference unit tests: 142/142 pass. Both Swift and Rust ports
build clean.

The batched trait extension is shipped, the conformance harness
validates it across language and across the 18 existing
primitives, and the measurement infrastructure is ready to
consume specialized backends.

### 2026-05-17 - multi-primitive buildout

During the multi-primitive buildout (Tier 1 through Tier 3
primitives), the test harness expanded from 4 primitives to 18,
and the cross-language conformance gate surfaced nine real
correctness bugs in the Swift reference implementation. Each is
recorded below with its symptom, root cause, and the fix that
landed.

**Bugs found and fixed.**

1. **HyperplaneFamily.generate density boundary.** Both ports
   computed `UInt64(Double(UInt64.max) * density)` for the
   active-bit threshold. At `density >= 1.0`, Swift trapped on
   the `UInt64(...)` conversion; Rust saturated with a 1-in-2^64
   asymmetry. Both ports now treat `density >= 1.0` as the
   degenerate "every bit active" case without round-tripping
   through Double.

2. **EigenvalueCentrality bipartite oscillation.** Pure power
   iteration oscillates on bipartite graphs (eigenvalues come in
   ±λ pairs, and the iteration switches sign each step). Both
   ports now apply a Perron-Frobenius shift `y = A*x + SHIFT*x`
   with SHIFT = 1.0. Same eigenvectors, shifted spectrum, no
   oscillation.

3. **CommunityDetection triangle merge (Rust test only).** The
   triangle test for Louvain phase 1 asserted an unreachable
   merge; phase 2 graph aggregation is intentionally deferred to
   a later release per cookbook §7.3. The Rust test now asserts
   the canonical labeling invariant only.

4. **BradleyTerry observe multi-loser update.** Swift's
   `observe()` overwrote `theta[obs.winnerID]` on each loser
   iteration using the snapshot `winnerTheta`, so only the LAST
   loser's contribution made it to the winner. Multi-loser
   observations were silently mis-handled. Swift now uses an
   accumulating `winnerNew` pattern matching Rust.

5. **TierContribution wire format LE/BE mismatch.** Swift's
   `encode()` emitted the aggregate fingerprint via
   `aggregate.toBytes()` (which is little-endian, the
   Fingerprint256 wire format), while the rest of the 64-byte
   federation wire format used `UInt32BE`/`UInt64BE`. Rust used
   BE consistently. Swift now writes all four aggregate blocks
   as BE u64s, matching Rust. Decode mirrors. Old behavior would
   have produced 32 LE bytes where receivers expected 32 BE
   bytes — silent federation corruption.

6. **HammingNN heap tie-breaking.** Both ports' top-K
   max-heaps may evict different items when distances tie at the
   eviction boundary. The harness works around this by using
   `k == cohort_size` so the heap returns all items, then
   applying a canonical `(distance ascending, id-bytes ascending)`
   sort. The underlying ports retain their nondeterministic
   boundary behavior; callers that need determinism on real data
   must apply the secondary sort themselves.

7. **PairingHandshake UUID string-vs-byte compare.** Swift's
   `PairingNonce.seedWith()` used `estateA.uuidString <
   estateB.uuidString` for canonical ordering. The Rust mirror
   compared raw 16-byte arrays. At byte values crossing
   hex-letter boundaries (e.g. 0x0F vs 0x10), ASCII string
   compare disagrees with byte compare: 'F' = 0x46 > '1' = 0x31,
   so string "0F..." sorts after "10...", but byte 0x0F < 0x10.
   Two estates pairing across this boundary would derive
   different shared seeds, generate incompatible hyperplane
   families, and produce nonsense Hamming distances across
   federation. Swift now compares raw bytes via fileprivate
   `lexLessOrEqual`, matching Rust.

8. **AuditEvent public init missing.** Swift's `AuditEvent`
   struct was declared `public` but had no explicit init, so the
   memberwise init was internal (Swift default). The harness
   could not construct AuditEvent values. An explicit `public
   init(...)` was added.

9. **AuditLogFold harness Int64 overflow.** The audit-log fold
   primitive constructed test events with `let adj = Int64(stateVal)
   | Int64(rng.next() & 0xFFFFFFFF_FFFFFF00)`. When the RNG
   produced a value with bit 63 set, the `Int64(UInt64)`
   conversion trapped. Now uses `Int64(bitPattern: UInt64)` which
   is a bit reinterpret, matching Rust's `as i64`.

Primitive vector files committed in this buildout (with CRCs):

| Primitive | CRC | Cookbook § |
|---|---|---|
| simhash | `0xf44ea16a` | §3.6 |
| hamming | `0xf0e157b7` | §8.2 |
| or_reduce | `0xf5c60f3f` | §8.5 |
| bitwise | `0x05230c95` | §8.6 |
| anomaly | `0x6c6fda4d` | §8.13 |
| hlc | `0x9303e020` | §5.2 |
| fingerprint | `0x4449238e` | §3.1 |
| lattice | `0x6c4e453f` | §8.3 |
| info_theory | `0x0cc08713` | §8.11 |
| bradley_terry | `0x601126c7` | §8.12 |
| partial_state_recall | `0xe8d3b221` | §8.8 |
| temporal_compression | `0xdc3144c0` | §8.14 |
| tier_contribution | `0x4b67bcb5` | §12.3 |
| fft | `0xeae5c063` | §8.10 |
| hamming_nn | `0xeac615f1` | §8.2 |
| pairing_handshake | `0x67bc56f8` | §12.2 |
| nmf | `0x300bf633` | §6.9 |
| audit_log_fold | `0xa747722e` | §5.3+§8.15 |

All 18 primitives pass the four-way cross-language conformance
gate (Swift gen → Swift validate, Swift gen → Rust validate,
Rust gen → Swift validate, Rust gen → Rust validate).

### 2026-05-28 - matrix_decay - new primitive promoted to gate

The `matrix_decay` primitive (cookbook §6.8) is promoted from the
"Pending future work" list in `primitive-catalog.md` into the
conformance gate. The Swift reference at
`SubstrateLib/Sources/SubstrateLib/MatrixDecay.swift` and the Rust
reference at `SubstrateLib/rust/src/matrix_decay.rs` expose the
canonical `apply(to:nowSeconds:)` entry point.

The harness uses 32 test cases:
- Cases 0..23: arbitrary dt sampled from the SplitMix64 stream,
  bounded to `[1 second, 3 × half_life]`. Decay factors are
  generally NOT powers of 1/2; cross-language bit-identity here
  depends on Swift `Foundation.exp()` and Rust `f64::exp()`
  resolving to the same libm. On Apple Silicon they both resolve
  to Darwin's `libsystem_m`, and the CRC matches; on other
  platforms this assumption must be re-verified.
- Cases 24..27: edge cases. dt = 0 (no-op), dt < 0 (backward time
  no-op), dt = exactly one half_life (factor = 0.5, bit-exact),
  dt = exactly two half_lives (factor = 0.25, bit-exact).
- Cases 28..31: additional arbitrary dt sampled cases for shape
  variety (3x3, 4x4, 2x5, 5x2).

Inputs schema: rows (u32), cols (u32), half_life_seconds (f64),
last_decay_time_seconds (i64), now_seconds (i64), initial_values
(array of f64).

Outputs schema: final_last_decay_time_seconds (i64), final_values
(array of f64).

Binary canonical encoding (alphabetical key order):
final_last_decay_time_seconds as i64 LE, followed by final_values
as u32 LE length prefix + N × 8 bytes f64 LE.

- New CRC: `0x7b12f93d`
- Vector cases: 32
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen × Swift validate (PASS),
  Swift gen × Rust validate (PASS), Rust gen × Swift validate
  (PASS), Rust gen × Rust validate (PASS). All four cells green.

Catalog updated: `primitive-catalog.md` Tier 2 row added; "Pending
future work" entry removed. CI matrix iterator extended to 19
primitives.

### 2026-05-28 - eigenvalue_centrality - new primitive promoted to gate

The `eigenvalue_centrality` primitive (cookbook §7.2) is promoted
from the "Pending future work" list in `primitive-catalog.md` into
the conformance gate. The Swift reference at
`SubstrateML/Sources/SubstrateML/EigenvalueCentrality.swift` and
the Rust reference at `SubstrateML/rust/src/eigenvalue_centrality.rs`
implement power iteration with a
Perron-Frobenius shift (`xNext += SHIFT * x`, SHIFT = 1.0) that
breaks the ±λ oscillation bipartite graphs exhibit under raw
power iteration. The bipartite-shift fix was applied during the
multi-primitive buildout on 2026-05-17 (see the bug list
in the earlier multi-primitive entry).

The harness uses 32 test cases:
- Cases 0..3: edge cases. n=0 (empty), n=1 with self-loop,
  n=5 isolated (no edges, norm collapses, returns uniform
  1/sqrt(n)), symmetric triangle.
- Cases 4..7: symmetric star graphs at n=3, 5, 7, 9. Bipartite —
  the canonical test for the Perron shift.
- Cases 8..31: random sparse graphs from the SplitMix64 stream
  with n in [4, 29], edge counts roughly 1..4 × n, positive
  weights in (0.1, 5.1]. max_iterations cycles through {50, 200,
  500}; tolerance cycles through {1e-4, 1e-6, 1e-9}.

Cross-language bit-identity: this primitive uses `sqrt()`, which
IEEE-754 mandates be correctly-rounded across all conformant
libm implementations (unlike `exp()` in matrix_decay, which has
1-ULP wiggle room and required empirical verification). The
inner accumulation `x_next[j] += w * x[i]` proceeds in identical
loop order in both languages (outer loop over rows, inner loop
over adjacency in JSON-array push order), so the floating-point
reduction is order-deterministic. Convergence detection
`diff_sq.sqrt() < tolerance` fires at the same iteration in
both languages.

Inputs schema: n (u32), edges (array of {dst: u32, src: u32,
weight: f64}), max_iterations (u32), tolerance (f64).

Outputs schema: centrality (array of f64).

Binary canonical encoding (alphabetical key order, just one
output field): centrality as u32 LE length prefix + N × 8 bytes
f64 LE.

- New CRC: `0x1a9039ea`
- Vector cases: 32
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen × Swift validate (PASS),
  Swift gen × Rust validate (PASS), Rust gen × Swift validate
  (PASS), Rust gen × Rust validate (PASS). All four cells green.

Catalog updated: `primitive-catalog.md` Tier 3 row added (estate-
as-graph layer, sits with `nmf` and federation primitives);
"Pending future work" entry removed. CI matrix iterator extended
to 20 primitives.

### 2026-05-28 - moment_summary - new primitive promoted to gate

The `moment_summary` primitive (cookbook §8.7) is promoted from
the "Pending future work" list in `primitive-catalog.md` into
the conformance gate. The Swift reference at
`SubstrateML/Sources/SubstrateML/MomentSummary.swift` and the
Rust reference at `SubstrateML/rust/src/moment_summary.rs`
implement moment-summary as the OR-reduction
of fingerprints whose rows pass an `active_during(row, window)`
predicate.

A note on the catalog's prior "Swift Row / Rust RowLite type
mismatch" entry: this is NOT a substrate bug. It is a
deliberate API asymmetry — Swift's reference takes the full
production `Row` from SubstrateTypes/Sources/SubstrateTypes/Row.swift (which lacks a
capture_hlc field; that lives in the audit log in production),
while Rust's reference uses a lightweight `RowLite` struct that
carries only `fingerprint` and `capture_hlc`. The harness bridges
the asymmetry: it builds throwaway `Row` instances in Swift
(only the fingerprint field is consulted by the algorithm) and
resolves capture HLCs via an index-counter closure passed as the
predicate. The closure relies on `MomentSummary.summarize`'s
documented behavior of calling `activeDuring` once per row in
row order via `rows.filter`. The Rust harness builds `RowLite`
directly and uses `MomentSummary::captured_during`. Both ports
produce bit-identical output.

The harness uses 32 test cases:
- Case 0: empty rows -> zero fingerprint.
- Cases 1..3: single rows inside / outside window, plus a
  5-row all-in-window case.
- Cases 4..7: HLC boundary cases — row exactly at window.start
  (inclusive), exactly at window.end (inclusive), one unit
  before window.start (excluded), one unit after window.end
  (excluded). These exercise the closed-interval [start, end]
  semantics shared by both ports.
- Cases 8..31: random distributions with 1..16 rows, fingerprints
  and HLCs drawn from the SplitMix64 stream, and a window
  derived from RNG-supplied (start, offset).

Cross-language bit-identity: filtering is integer HLC comparison
(no float), OR-reduce is bitwise OR on Fingerprint256's four
u64 blocks. No transcendentals. Both ports iterate the rows
array in JSON-array order so the OR-reduce accumulates in
identical order.

Inputs schema: rows (array of {capture_hlc: HLC-32hex,
fingerprint: Fingerprint256-64hex}), window (object {end:
HLC-32hex, start: HLC-32hex}).

Outputs schema: summary (Fingerprint256, 64-hex).

Binary canonical encoding (alphabetical key order, single field):
summary as 32 wire bytes (4 × u64 LE).

- New CRC: `0x6762440b`
- Vector cases: 32
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen × Swift validate (PASS),
  Swift gen × Rust validate (PASS), Rust gen × Swift validate
  (PASS), Rust gen × Rust validate (PASS). All four cells green.

Catalog updated: `primitive-catalog.md` Tier 2 row added next to
`matrix_decay`; "Pending future work" entry removed. CI matrix
iterator extended to 21 primitives.

### 2026-05-28 - field_presence_matrix_f - new primitive promoted to gate

The `field_presence_matrix_f` primitive (cookbook §6.1) is
promoted from the "Pending future work" list in
`primitive-catalog.md` into the conformance gate. The Swift
reference at `SubstrateTypes/Sources/SubstrateTypes/MatrixF.swift` and
the Rust reference at `SubstrateTypes/rust/src/matrix_f.rs`
implement F, the 36 × 6 = 216-cell population
statistic over (field, bit_position) presence. The `apply_row`
operation walks the 216 positions and adds `delta` to each cell
where `bit_presence(field, bit)` is true.

The catalog's prior pending-list note ("reaches into Substrate
state") was conservative. F has a clean stateless `apply_row`
API with a closure for the bit-presence pattern — no Substrate
or audit-log dependency at the primitive level. The harness
tests F in isolation as a sequence of (initial_state, ops) →
final_state transitions.

The harness uses 32 test cases:
- Case 0: zero matrix, no ops.
- Cases 1..3: single-op edge cases (all-bits-set with +1,
  all-bits-clear with +1 which is a no-op, +1 then -1 inverse
  pair).
- Cases 4..7: seeded non-zero initial state + single op at
  deltas {+1, -1, +100, -100}.
- Cases 8..15: seeded initial + three-op sequences mixing
  positive and negative deltas with two different patterns.
- Cases 16..31: random sequences of 1..12 ops on a seeded
  initial state, deltas drawn from [-199, +199].

Bit-presence pattern encoding: 216 bits packed LSB-first into
27 bytes (54 hex chars). Bit at position `field * 6 + bit` lives
in byte `pos / 8`, bit position `pos % 8`. Both languages decode
identically.

Cross-language bit-identity: integer-only. apply_row uses
wrapping_add in Rust (`cells[idx].wrapping_add(delta)`) and `&+=`
in Swift, which produce identical two's-complement results on
i64 overflow. The 216-iteration fixed loop visits positions in
identical (field, bit) order in both languages. No floats. No
transcendentals.

Inputs schema: initial_cells (array of i64, length 216),
operations (array of {bit_presence: 54-hex, delta: i64}).

Outputs schema: final_cells (array of i64, length 216).

Binary canonical encoding (alphabetical, single field):
final_cells as u32 LE length prefix (216) + 216 × 8 bytes i64 LE.

- New CRC: `0x2a051f09`
- Vector cases: 32
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen × Swift validate (PASS),
  Swift gen × Rust validate (PASS), Rust gen × Swift validate
  (PASS), Rust gen × Rust validate (PASS). All four cells green.

Catalog updated: `primitive-catalog.md` Tier 2 row added next to
`moment_summary`; "Pending future work" entry removed. CI matrix
iterator extended to 22 primitives.

With this promotion the pending list now contains ONLY
`community_detection` phase 2, which is explicitly deferred to
a later release per cookbook §7.3 (Louvain phase 2 graph
aggregation). All other previously-pending primitives are now
conformance-gated.

### 2026-05-28 - audit_log_fold - Rust harness AuditEvent constructor fix

The substrate's `AuditEvent` struct gained a new
`event_id: u128` field for federation idempotence (deterministic
content-ID over the wire fields, set by `audit_gate::content_id`).
The Rust harness's two `AuditEvent { ... }` struct-literal
constructions in `audit_log_fold.rs` (one in `generate`, one in
`validate_case`) did not supply this field, causing Rust harness
builds to fail with "missing field `event_id` in initializer".

Fix: added `event_id: 0` to both `AuditEvent`
constructions in `test-harness/rust/src/primitives/audit_log_fold.rs`.

CRC IMPACT: NONE. Verified by inspection that the fold algorithm
does not reference the `event_id` field — it consumes only verb,
before_bitmaps, after_bitmaps, hlc, and lattice anchors. The
fold's output state is therefore independent of event_id's
value. Confirmed empirically:
  - audit_log_fold vector on disk: CRC `0xa747722e` (pre-fix)
  - Rust regenerated post-fix:     CRC `0xa747722e` (unchanged)
  - Swift validate of disk vector: PASS
  - Rust  validate of disk vector: PASS (now works, previously
    failed at build time)

On the Swift side, `AuditEvent` now lives in its own type at
`SubstrateTypes/Sources/SubstrateTypes/AuditEvent.swift`
with `public let eventID: UUID`; the Rust mirror at
`SubstrateTypes/rust/src/audit_event.rs` uses
`event_id: u128`. The `audit_log_fold` CRC (`0xa747722e`) is
unaffected because the fold algorithm does not consume the field
in either port.

### 2026-05-28 - fnv - promotion to 23rd gated primitive

Fowler-Noll-Vo 1a was previously an internal helper inside
`SubstrateLib/.../FeatureExtractors.swift` (Swift `internal func
fnv64`) and `SubstrateML/rust/src/feature_extractors.rs` (Rust `pub fn
fnv64`). LocusKit, CorpusKit and substrate-internal callers each
rolled their own copy of the same algorithm. FNV-1a was
promoted to a public substrate atomic (`FNV.swift` /
`SubstrateTypes/rust/src/fnv.rs`) covering all three substrate-consumed entry
points: 64-bit, 32-bit, and 16-bit fold. Every kit-local FNV-1a
implementation was retired and redirected to the new public API.

With the implementations consolidated, FNV-1a was promoted into
the conformance gate as the 23rd primitive. The harness primitive
covers all three entry points via an `op` field in the case
schema (`0` = hash64, `1` = hash32, `2` = hash16); the input is
a deterministic-ASCII string built from the SplitMix64 RNG.
Output is a u64 hex-encoded in HexCoding.u64 (little-endian byte
order), zero-extended for hash32/hash16 cases.

A minor encoding gotcha surfaced and was fixed during initial
four-way validation: the first cut of `parse_u64` (both ports)
treated the hex as big-endian numeric, but the existing
`HexCoding.u64` convention is little-endian byte hex (byte 0 =
LSB), matching how every other gated primitive encodes u64. The
fix on the Swift side calls `HexCoding.decode` and reassembles
LE; the Rust side decodes via `decode_hex` and does the same. A
new `encode_u64_le` helper on the Rust side mirrors
`HexCoding.u64` exactly.

- New CRC: `0x275fd2bf`
- Vector cases: 32
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen + Swift validate, Swift gen +
  Rust validate, Rust gen + Swift validate, Rust gen + Rust
  validate. All four PASS at `0x275fd2bf`.
- New tier-1 entry — the primitive catalog and the cookbook
  (§18.2) were updated, and the primitive was added to the CI
  conformance matrix.

Reference paths:
- Swift reference: `SubstrateTypes/Sources/SubstrateTypes/FNV.swift`
- Rust reference: `SubstrateTypes/rust/src/fnv.rs`
- Harness Swift: `FNVPrimitive.swift`
- Harness Rust: `src/primitives/fnv.rs`

### 2026-06-20 - merkle_commitment - NT-P0 content-integrity contract

The `merkle_commitment` primitive was added as the NT-P0
content-integrity extension to the I-27 seal surface. It pins the
canonical byte contract for:

- leaf payloads over drawer UUID, NFC UTF-8 content, and optional
  VectorKit sidecar vectors;
- interior roots over sorted child roots;
- tombstone roots;
- the empty subtree root;
- keyed commitments over canonical leaf payloads.

The reference implementations live in SubstrateKernel and call the
in-repo SHA-256 primitive. Keyed commitments reuse the existing
GrantHKDF / hkdf HMAC implementation; this primitive does not add a
second HMAC construction. The typed 32-byte data wrappers
(`ContentHash`, `MerkleRoot`, `KeyedCommitment`) live in
SubstrateTypes, preserving the I-30 package split.

The committed fixture has six semantic cases:

1. leaf hash with zero vectors;
2. leaf hash with vector records sorted by `(model_id, vector_index)`;
3. interior root with children sorted by raw UUID bytes;
4. tombstone hash;
5. empty root;
6. keyed commitment with key version.

The seed field is `0xefbeaddebebafeca`, the harness-standard
little-endian encoding of numeric seed `0xCAFEBABEDEADBEEF`. The
cases are canonical hand-selected contract cases rather than
randomized estate-shaped cases; the seed is retained for the
shared vector-file schema and CI invocation consistency.

- New CRC: `0x2476cee9`
- Vector cases: 6
- Seed: `0xCAFEBABEDEADBEEF`
- Four-way conformance: Swift gen + Swift validate, Swift gen +
  Rust validate, Rust gen + Swift validate, Rust gen + Rust
  validate. All four PASS at `0x2476cee9`.

Reference paths:
- Swift reference: `SubstrateKernel/Sources/SubstrateKernel/MerkleCommitment.swift`
- Rust reference: `SubstrateKernel/rust/src/merkle_commitment.rs`
- Swift typed wrappers: `SubstrateTypes/Sources/SubstrateTypes/ContentHash.swift`
- Rust typed wrappers: `SubstrateTypes/rust/src/content_hash.rs`
- Harness Swift: `MerkleCommitmentPrimitive.swift`
- Harness Rust: `src/primitives/merkle_commitment.rs`

## Per-primitive registration

The harness ships a registry mapping primitive name → generator
function + validator function in each language. Adding a new
primitive requires:

1. Land Swift + Rust reference implementations under the
   appropriate substrate package: `Substrate{Types,Kernel,ML,Lib}`
   (Swift `Sources/`, Rust `rust/src/`).
2. Register the primitive in
   `test-harness/swift/Sources/Harness/Primitives/PrimitiveRegistry.swift`
   and `test-harness/rust/src/primitives/registry.rs`.
3. Run `swift run gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF`
   and `cargo run --bin gen-vectors -- --primitive <name> --seed
   0xCAFEBABEDEADBEEF`. Both must produce vector files with
   identical CRCs.
4. Run both validators on both files. All four cells must pass.
5. Commit the Swift-generated vector file (canonical;
   Rust-generated is a CI artifact). The Swift-generated file
   is the on-disk source of truth.
6. Add the primitive to the CI conformance matrix (one entry per
   matrix step).
7. Update `primitive-catalog.md` with the new entry,
   including its CRC, cookbook section, and source-file paths.

See `primitive-walkthrough-SimHash.md` for the worked example.
