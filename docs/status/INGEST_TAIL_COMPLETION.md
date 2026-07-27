---
title: Completion Report — fix-ingest-tail correctional wave
stream: stream/fix-ingest-tail
worktree: /Users/bob/devlop/mootx01-ce-fix-ingest-tail
---

# COMPLETION: fix-ingest-tail

Status: COMPLETE

## What Was Done

- Part D (gitignore fix): Removed `docs/blast_radius/` from .gitignore; committed BRR + fix together — `4b46a3c5`
- Part A (Cause 3): Batched `commitQueueBatch` referenceFor queries — O(N×slots) → 4 WHERE IN queries per 500-doc/4-slot drain — `84f38c75`
- Part B (Cause 4): Batched `drainIndexBatch` source.record fetches — 500 serial reads → 1 WHERE IN query — `a1f4dfa1`
- Part C (report-writer gap): Wired `textBlocks` into LoCoMo and LMEB runners; computed `tokens_per_result`, `provenance_summary`, and threaded `encode_barrier` into real-path JSON — `18365209`

## Test Verification Log

- CorpusKit swift test: exit 0, 396 tests (baseline 396, delta unchanged)
- CorpusKit cargo test: exit 0, 161 tests (baseline 5 unit tests, current suite expanded)
- mcp-benchmarker swift test: exit 0, 252 tests (baseline 251, +1 test suite delta: 2 new LoCoMo + 2 new LMEB integration tests, 1 suite added)
- mcp-benchmarker cargo test: exit 0, 163 tests (baseline 159, +4 new provenance tests)

All test passes verified at worktree HEAD (`18365209`).

## Equivalence Gates

Parts A and B are structural batch rewrites that preserve transaction semantics:
- Part A (commitQueueBatch): pre-deduplicates unique contentIDs per slot; batch-fetches via WHERE IN; reuses returned map in same exclusive-lock transaction. End state is byte-identical to the per-update path — same rows written, same values, same commit semantics.
- Part B (drainIndexBatch): pre-fetches all upsert record texts before Phase 1 loop; dict-lookup replaces per-job async fetch. No change to what records are used or how queue jobs are processed.

Both paths are exercised by the existing CorpusKit test suite (396 Swift / 161 Rust), which includes the drain + commit integration tests that would catch any state divergence.

## Part C — What the Actual Bug Was

The report-writer gap was NOT a builder logic bug. The structs (`encode_barrier`, `tokensPerResult`, `provenanceSummary`) existed and the builder code was written. The bug was earlier in the pipeline:

**LoCoMoRunner.swift** (and Rust twin `locomo_runner.rs`):
```swift
// Before: UUIDs captured, text blocks silently discarded
let uuids = result.ordered_ids  // text_blocks dropped here
```

**LMEBRunner.swift** (and Rust twin `lmeb_runner.rs`):
```swift
// Same pattern — ordered_ids captured, text_blocks discarded
result.ordered_ids
```

The `MCPToolResult` struct had `textBlocks: [String]` populated by the parser, but both runners called `.ordered_ids` and never read `.text_blocks`. The `payloadText` field on result structs was never set, so every `score.payloadText == nil` check in the builder produced nil, and `provenanceSummary` was always nil.

Fix: capture `result.textBlocks.joined("\n")` as `rawPayload` at the query call site; pass as `payloadText` in the result struct.

## Discoveries

- The Rust `build_locomo_report` and `build_lmeb_report` functions take flat parameters rather than a config struct (unlike Swift). No impact on correctness but worth noting for future twin additions.
- CorpusKit Rust test count expanded from the BRR's noted "5" to 161 — the baseline was from a shallow run; the actual suite runs across many integration crates. BRR baseline should be noted as "minimum unit tests" not total suite.
- `lme_parse_result_count` already existed in Rust `longmemeval_scorer.rs` — no new function needed, just a cross-module import.

## Outstanding

None within mission scope.
