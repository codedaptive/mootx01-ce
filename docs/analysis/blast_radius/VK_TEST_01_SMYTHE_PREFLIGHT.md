# Smythe Pre-flight — VK-TEST-01

**Verdict: GREEN. Terrain clear. Proceed.**
**Date:** 2026-05-31 · Spawned by Bilby (separate agent, read-only)

## Status

- **Blast radius:** verified. 4 test files, 30 test methods, Tests/ directory clean.
- **Prior art:** none conflicting. No swift-testing imports in VectorKitTests/ (only in
  `.build/checkouts` — transitive deps, irrelevant).
- **Environment:** Package.swift swift-tools-version:6.0. No `Testing` dep declared.
  No-op confirmed — Testing ships with the toolchain. No Package.swift change required.
- **Dependencies:** all satisfied. EngramLib, SubstrateML, SubstrateTypes, PersistenceKit,
  PersistenceKitInMemory — all declared and resolved.

## Blockers

None.

## Premise corrections (for BRR + completion report)

- **PC-1** — Rust test count is wrong. Mission says 0 `#[test]`; reality is **23**
  (8 in `simhash_provider_tests.rs`, 15 in `vector_store_tests.rs`). Does NOT block —
  Rust out of scope, parity preserved by keeping all 30 methods. Record and proceed.
- **PC-2** — "Read First" source descriptions are stale (pre-2026-05-19 refactor). Count
  (7) correct; descriptions are flavor. No execution impact.
- **PC-3** — "30 assertions" = 30 test *methods*. Actual `XCTAssert*`/`XCTFail` call count
  is **61** (EmbeddingProvider 5, FloatSimHash 14, VectorStore 34, CapturePathBenchmark 8).
  Preserve all 61 assertion calls.

## Part 2 — source types lacking peer suites (confirmed)

1. `VectorKitError` (enum, 4 cases, Equatable) → add `VectorKitErrorTests.swift`
2. `VectorMatch` (struct, Comparable + Equatable; only indirect coverage) → add `VectorMatchTests.swift`
3. `StoredVector` (struct, Equatable; only indirect coverage) → add `StoredVectorTests.swift`
4. `VectorKit.swift` — module-doc only, no public type, no suite needed.

## Conversion notes

- `testInferenceFailurePropagates`: `XCTFail`-in-`catch` → `#expect(throws: InferenceError.self)`.
  Preserves semantics exactly.
- `CapturePathBenchmarkTests` static helpers (`freshStore`, `captureCorpus`, `percentiles`,
  `nanoseconds`, `report`) and nested `PercentileTriplet` struct port directly into the
  `@Suite struct` body.
