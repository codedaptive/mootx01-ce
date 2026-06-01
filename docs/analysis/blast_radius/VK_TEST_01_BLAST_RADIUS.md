# Blast Radius Report — VK-TEST-01

**Mission:** VectorKit library test leg — convert XCTest → swift-testing, fill per-type gaps
**Stream:** stream/vk-vectorkit-test-leg
**Tier:** net-new / test-only (no production source modified — no edit cap; conversion is in-place rewrite of test files)
**Date:** 2026-05-31
**Author:** Bilby

---

## Classification summary

This is a **TEST-ONLY** mission. No production source symbol is modified, removed,
renamed, or deprecated. The "blast radius" of a framework conversion is confined to the
test target itself: the symbols being changed are XCTest test-method declarations, which
are referenced by nothing outside their own files (the XCTest runtime discovers them by
reflection; swift-testing discovers `@Test` by macro). There are therefore **zero
MUST_UPDATE call sites in production code**.

Baseline test suite at mission start: `swift test` exit 0, **30 XCTest methods, all
passing** (XCTest runner). The swift-testing runner reports "0 tests in 0 suites" — this
is the exact condition the mission targets.

## Symbols touched

| Symbol class | Detail | Classification |
|---|---|---|
| XCTest test methods (30) across 4 files | `func testX()` → `@Test func x()` | IN-SCOPE (test target only) |
| `XCTAssert*` / `XCTFail` calls (61 total) | → `#expect` / `#require` / `#expect(throws:)` | IN-SCOPE (preserve all 61) |
| `XCTestCase` subclass decls (4) | → `@Suite struct` | IN-SCOPE (test target only) |
| `import XCTest` (4) | → `import Testing` | IN-SCOPE (test target only) |
| New peer suites (Part 2) | `VectorKitErrorTests`, `VectorMatchTests`, `StoredVectorTests` | NET-NEW (test target only) |
| `Package.swift` | swift-testing dep | INTENTIONALLY_LEFT — no change needed (see below) |

## Grep verification — no production references to test symbols

Test method names and `XCTestCase` subclass names appear **only** in their own test
files. No `Sources/**`, no other package, no docs reference them. Conversion is
self-contained.

## Package.swift — INTENTIONALLY_LEFT (no change)

swift-testing (the `Testing` module) ships with the Swift 6.x toolchain (verified Swift
6.3.2 on this host) and requires **no** package-manifest dependency. Smythe confirmed:
no `Testing` dependency declared, none needed; the swift-testing runner is already active
(baseline shows the "0 tests in 0 suites" swift-testing run alongside the XCTest run).
This matches the `no-op-pkg-confirmed` precedent from SK-TEST-01 and ENGRAM-TEST-01.
The mission's Package.swift row is explicitly conditional ("additive swift-testing dep
**only if absent**"); the dependency mechanism is absent because it is unnecessary, so
the file is left untouched.

## Files MUST NOT modify (confirmed untouched)

- `packages/kits/VectorKit/Sources/**` — released production code. Git diff of Sources/
  will be empty at mission end (verified by self-review + Adams).
- `packages/kits/VectorKit/rust/**` — out of scope.
- `docs/validation/**` — off-limits conformance harness.
- Any other package.

---

## Premise corrections (spec-vs-reality) — NON-BLOCKING

Surfaced during recon; independently confirmed by Smythe pre-flight (GREEN).

### PC-1 — Rust leg test count is wrong (mission says 0; reality is 23)

Mission Context states: *"Its Rust leg has 0 `#[test]` functions (no Rust test parity to
mirror)."* **Reality: 23 `#[test]` functions** — 8 in `rust/tests/simhash_provider_tests.rs`,
15 in `rust/tests/vector_store_tests.rs`. The existing Swift test files' own comments say
they mirror these Rust tests ("Mirror of the Rust simhash_provider_tests", "Symmetric to
the Rust `embed_batch_default_impl_handles_mixed_empty_and_non_empty`").

**Assessment — does NOT block, does NOT rescope.** Rust is explicitly out of scope. The
conversion preserves every Swift assertion, which *keeps Swift↔Rust parity intact* — it
does not create or break it. "No Rust parity step" is satisfied by not touching Rust and
not running a new Rust verification; it does not depend on the (incorrect) claim that Rust
has no tests. Recurrence of the `mission-prose-wrong-on-rust` pattern previously seen in
ENGRAM-TEST-01. Recorded; proceed as written.

### PC-2 — "Read First" source descriptions are stale

Mission describes the 7 sources as "EmbeddingProvider, CoreML adapters, sqlite-vec HNSW,
BM25, Metal cosine, model/version tagging." Actual post-2026-05-19 kit-graph-refactor
sources: `EmbeddingProvider.swift`, `FloatSimHashEmbeddingProvider.swift`,
`StoredVector.swift`, `VectorKit.swift`, `VectorKitError.swift`, `VectorMatch.swift`,
`VectorStore.swift`. **Count (7) is correct; descriptions are stale documentation
flavor.** No impact on execution.

### PC-3 — "30 assertions" actually means 30 test *methods*; assertion *calls* = 61

The mission's phrase "preserving EVERY assertion" alongside "30 XCTest methods" conflates
two counts. There are **30 test methods** and **61 `XCTAssert*`/`XCTFail` calls**
(EmbeddingProvider 5, FloatSimHash 14, VectorStore 34, CapturePathBenchmark 8). The
verification-log target "registers non-zero (>= 30)" correctly counts `@Test` functions.
**Preservation obligation: all 61 assertion calls AND all 30 methods.** Captured so
Adams can verify against the right number.

---

## RESCOPE_REQUIRED items

**None.** No symbol classifies as RESCOPE_REQUIRED. Blast radius is fully contained in the
VectorKit test target. Proceeding to implementation.
