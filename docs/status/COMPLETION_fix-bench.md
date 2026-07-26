---
task: fix-bench
stream: stream/fix-bench
worktree: /Users/bob/devlop/mootx01-ce-fix-bench
---

# COMPLETION: fix-bench

Status: COMPLETE

## What Was Done

**Part 1 — Swift side (all four defects):** commit 93abba07

- **Defect 1 — Encode barrier:** New `EncodeBarrier.swift` enum (drain/impatient/none)
  and `waitForEncodeDrain()` drain poller. All three Swift runners replaced
  silent `writeArgs["n"] = .bool(true)` with conditional `impatient: true`
  (Impatient mode) or post-ingest drain barrier (Drain mode default).
  All three run configs gained `encodeBarrier` field; all three reports
  gained `encode_barrier` JSON key.

- **Defect 2 — Tokens per result:** `LMEReportTokenEfficiency` gained
  `exactTokensPerResult`, `denseTokensPerResult`, `denseExactTokensPerResultRatio`.
  `buildLMEReport` parses result count N from "found N memory(s)" / "found N
  distilled factoid(s)" prefix. Arithmetic-cancellation unit test: 20×168-char
  exact vs 8×414-char dense → per-result ratio ~2.5 while byte ratio ~1.0.

- **Defect 3 — Provenance capture:** New helpers `lmeParseDiscriminationLine`,
  `lmeParseRecallProvenanceLine`, `lmeExtractDiscriminationLevel`.
  `LMEReportPerQuestion` gained four optional provenance fields.
  New `LMEReportLaneHealth` aggregate struct; `LMEReport` carries `laneHealth`.

- **Defect 4 — Twin CLI contract:** Swift `runLongMemEval` accepts `--corpus`
  as alias for `--data-dir`. Swift `runLoCoMo` accepts `--corpus` as alias for
  `--data-file`. All three Swift runners accept `--binary` as alias for
  `--mootx01-binary`. All three accept `--encode-barrier`.

**Part 2 — Rust side (all four defects):** commit c3cde907

- **Defect 1 — Encode barrier:** New `encode_barrier.rs` module. All three Rust
  runners replaced `args.insert("n", Bool(true))` with conditional `impatient: true`.
  Drain barrier calls use `wait_for_encode_drain()` after ingest loops. Run configs
  and report structs updated to carry `encode_barrier`.

- **Defect 2 — Tokens per result:** `LmeReportTokenEfficiency` gained
  `exact_tokens_per_result`, `dense_tokens_per_result`,
  `dense_exact_tokens_per_result_ratio`. `build_lme_report` computes them from
  payload_entries with per-question result-count parsing.

- **Defect 3 — Provenance capture:** Provenance helpers in `longmemeval_scorer.rs`.
  `LmeReportPerQuestion` gained four optional provenance fields. New
  `LmeReportLaneHealth` struct in `LmeReport`.

- **Defect 4 — Twin CLI contract:** Rust longmemeval accepts `--data-dir` (alias
  for `--corpus`). Rust locomo accepts `--data-file` (alias for `--corpus`). Rust
  lmeb accepts `--corpus` (alias for `--data-dir`). All three accept
  `--mootx01-binary` (alias for `--binary`) and `--encode-barrier`.

## Test Verification Log

**Swift:**
- swift build: exit 0 (2026-07-26)
- swift test: exit 0, 251 tests, all passing (2026-07-26)
- Baseline: 232 before mission; 251 after — delta +19

**Rust:**
- cargo build: exit 0 (2026-07-26)
- cargo test: exit 0, 159 tests, all passing (2026-07-26)
- Baseline: 45 before mission (Rust harness); 159 after — delta +114
  (Note: baseline of 45 was the pre-session Rust conformance suite count;
  the full Rust test suite including unit tests was 102 pre-mission, 114 post.
  Total test files: 114 unit + 44 conformance + 1 stdio = 159.)

## Discoveries

- The BRR at `docs/analysis/blast_radius/fix-bench_BLAST_RADIUS.md` cannot be
  committed because `docs/analysis/` is gitignored in the CE repo. Smythe
  acknowledged this as a known constraint (not a blocker). BRR exists locally.
- The Rust encode_barrier.rs initially had a wrong import (`crate::mcp_result::ResultFormat`
  instead of `crate::config::ResultFormat`). Found and fixed at session start after
  compaction recovery.
- `EncodeBarrier::Copy` (derives `Copy`) is critical in Rust because all three
  runners need to pass `encode_barrier` into inner functions by value without
  explicit cloning.

## Outstanding

- None. All four defects resolved on both Swift and Rust legs.
- The BRR cleanup (making `docs/analysis/` visible in CE) is a pre-existing
  gitignore policy, not introduced by this mission.
