---
version: v0.1
---

# COMPLETION: LME-01

Status: COMPLETE

## What Was Done

- Part 1: BRR + Swift forklift from EE — `09d261ff`
- Part 2: Rust twin forklift from EE — `f7865ce1`
- Part 3: LongMemEval corpus loaders (Swift + Rust), schema validation, synthetic sample — `e2341137`
- Part 4: LongMemEval runner (Swift) — scratch estate lifecycle, guarded teardown, longmemeval subcommand — `f5e51a50`
- Part 5: LME scorer (Swift) — conformance vectors, report wiring — `15160eaf`
- Part 6: Rust twin — longmemeval_scorer + longmemeval_runner + main.rs subcommand — `81563141`
- Part 7: Diagnostic smoke, corpus loader fix, .gitignore, CHANGELOG — `de33e3fd`

## Test Verification Log

- swift build: exit 0
- swift test: exit 0, 183 tests in 36 suites, all passing
- cargo build: exit 0
- cargo test: exit 0, 92 tests (68 unit + 23 conformance + 1 stdio), all passing
- --limit 2 live smoke (Rust): exit 0, guard=healthy, recall_any@5=1.0 on both questions
- --limit 10 live smoke (Swift): exit 0, guard=healthy, 0 guard refusals, recall_any@10=0.70
- --limit 50 live smoke (Rust): exit 0, guard=healthy, 0 guard refusals, recall_any@10=0.88

## Discoveries

- **has_answer field absent in real corpus**: the real HuggingFace longmemeval
  corpus turns don't have `has_answer`. Only our hand-authored synthetic sample
  has it. Fixed in both loaders: `#[serde(default)]` in Rust, `decodeIfPresent ?? false` in Swift.
- **docs_internal is a symlink to EE**: in the CE worktree, `docs_internal/`
  is a symlink pointing at `/Users/bob/devlop/mootx01-ee/docs_internal`. Any
  writes there go to EE. Only `docs/` and `docs_internal` top-level contents
  should be written to from CE missions. Caught and corrected during Part 7.
- **Per-twin score divergence is expected**: Swift and Rust legs scoring the
  same questions against separate mootx01 instances produce different results
  because moot_memory_search ranking is non-deterministic at the embedding
  level. Conformance vectors verify the MATH is correct; live recall scores
  vary by run.
- **SplitMix64 shuffle is consistent**: same seed (20260725) → same 10
  question IDs in same order across both twins. GauntletRNG/SplitMix64
  implementations are in sync.

## Outstanding

- Full 500-question baseline run not in scope (takes ~4.5 hours single-threaded).
- LLM-judge QA accuracy scoring (answer quality beyond session retrieval) not in scope.
- Multi-session (`m`) and oracle variant smoke runs not in scope.
