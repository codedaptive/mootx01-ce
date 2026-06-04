# SubstrateValidator — field validators of the substrate libs

Two standalone compiled applications — one **Swift** (primary), one **Rust** —
that link the real shipping libraries (`packages/libs/*`) and validate them
against the committed conformance vectors. Unlike the test-harness (a dev tool
that generates/validates vectors), these are shippable artifacts that answer, on
any machine: *does this compiled binary faithfully implement the cookbook, agree
across backends and languages, and has its source drifted since it was stamped?*

```
validation-app/
  swift-app/   Swift executable (primary)   — links packages/libs Swift + glref
  rust/        Rust [[bin]]                  — links packages/libs Rust
  cross_lang_compare.py                      — subsystem 3 (cross-language)
```

(The Swift dir is `swift-app/`, not `swift/`, because SwiftPM derives a
path-dependency's identity from its directory name, which would collide with the
harness's `test-harness/swift`.)

## The six subsystems

| # | subsystem | Rust | Swift |
|---|---|---|---|
| 1 | conformance vs committed CRCs | ✅ 24/24 | ✅ 24/24 **+ glref 24/24** |
| 2 | backend A/B (byte-identical across kernels) | scalar≡simd | scalar≡simd≡bnns≡metal |
| 3 | cross-language (swift==rust==committed) | ✅ 24/24 | ✅ |
| 4 | timing (ns/call per primitive) | ✅ | ✅ `--time` |
| 5 | source↔cookbook structural audit | ✅ `--audit` | ✅ `--audit` |
| 6 | source-CRC drift | ✅ (build.rs) | ✅ `--stamp`/`--drift` |

**Swift is the primary validator and does the (B)+2 dual check:** every primitive
is validated against *both* the shipping `packages/libs` Swift impl *and* the
glref reference, and their agreement is reported. That dual check found a real
shipping bug (see below) that the glref-only harness could not.

## Build & run

```bash
# Rust (pinned nightly via rust-toolchain.toml — the harness forces simd-nightly)
cd rust && cargo build --release
./target/release/substrate-validator          # conformance + backend A/B + timing
./target/release/substrate-validator --json    # machine report
./target/release/substrate-validator --audit    # source↔cookbook (advisory)

# Swift (primary)
cd swift-app && swift build -c release
./.build/release/substrate-validator           # 3-way: lib vs glref vs committed
./.build/release/substrate-validator --backends # scalar/simd/bnns/metal byte-identical
./.build/release/substrate-validator --time      # ns/call per primitive
./.build/release/substrate-validator --audit      # source↔cookbook (advisory)
./.build/release/substrate-validator --stamp      # record lib-source CRC
./.build/release/substrate-validator --drift       # detect drift since stamp

# Cross-language (builds + runs both, asserts swift-lib == rust-lib == committed)
python3 cross_lang_compare.py
```

Exit code is nonzero on any conformance failure, backend disagreement, cross-lang
disagreement, or drift. `--audit` is advisory and always exits 0.

## How it works

The apps depend on the test-harness library crate/package, which carries the
canonical `CanonicalBinaryEncoder` + CRC-32/ISO-HDLC and the per-primitive
descriptors — so the byte mechanism is identical to the harness and the apps
reproduce the committed CRCs by construction. Each primitive's lib-side validator
decodes the committed vector inputs, calls the **shipping** lib, canonical-encodes
the output, and compares the CRC to the committed `output_crc32`.

## Caveats (honest limits)

- **Subsystem 5 is advisory/heuristic.** The source↔cookbook audit checks
  token/constant coverage (does the source reference the cookbook §'s magic
  constants and operations); it is **not** a semantic-equivalence proof. The real
  correctness gates are subsystem 1 (CRC) and subsystem 3 (cross-language). The
  Swift and Rust audits use different strictness; DRIFT/SKIP rows are usually
  token artifacts, not real divergence.
- **Float / higher-math primitives** (fft, nmf, eigenvalue_centrality, …) are
  byte-exact only on the **generation platform** — the committed vectors store
  IEEE-754 bit patterns and ADR-001 forbids cross-platform float bit-identity.
  Integer federation-core primitives are portable.
- **Swift drift uses an explicit `--stamp`** rather than a build-time stamp:
  SwiftPM's build-plugin sandbox cannot hash a sibling package's source at build
  time, so there is no clean `build.rs` equivalent. `--stamp` is the
  release/build-time stamp point; drift = "since last stamp".

## Bug found by the (B)+2 dual check

`SubstrateTypes.RowBitmaps` / `BitVector216` (Swift) **silently drops row fields
10, 11, 22, 23, 34, 35** — it packs 12 fields × 6 bits = 72 bits into a 64-bit
`Int64` and overshifts. glref and the Rust lib are correct (closure-based). The
`field_presence_matrix_f` Swift validator routes around `BitVector216` (drives
`MatrixF`'s subscript directly) to compute the canonical value. Fix mission:
`docs/_internal/missions/MISSION_FIX_ROWBITMAPS_BITVECTOR216_2026-05-31.md`.
