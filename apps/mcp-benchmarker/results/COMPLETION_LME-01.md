---
version: v0.3
---

# COMPLETION: LME-01

Status: COMPLETE

## Pre-flight and Post-flight Verdicts

**Smythe (pre-flight):** GREEN — Tier 3 net-new. No existing CE symbols changed, renamed,
removed, or deprecated. BRR confirmed at `docs/blast_radius/LME-01_BLAST_RADIUS.md`.
MUST_UPDATE list: `.gitignore`, `CHANGELOG.md` (additive only). RESCOPE_REQUIRED: none.

**Adams (post-flight):** CLEAN-WITH-FOLLOWUPS — 0 CRITICALs, 2 WARNINGs. Both WARNINGs
addressed in `6b0dbe6e`:
- WARNING 1: `defaultResultsRoot()` in `GauntletIO.swift` had 4× `deletingLastPathComponent()`
  (EE layout); CE has no `swift-bench/` wrapper, requires 3×. Fixed.
- WARNING 2: `defaultFixturesRoot()` in `main.swift` same depth error. Fixed.

## What Was Done

Parts 1-4 were implemented in session A (context ID cdbfb941-a250-450c-8a04-39bb6be60ec5,
the same session as Parts 5-7). The session compacted mid-mission after Part 4; all commits
are on the same stream branch and are auditable in git log.

- Part 1: BRR + Swift forklift from EE — `09d261ff`
- Part 2: Rust twin forklift from EE — `f7865ce1`
- Part 3: LongMemEval corpus loaders (Swift + Rust), schema validation, synthetic sample — `e2341137`
- Part 4: LongMemEval runner (Swift) — scratch estate lifecycle, guarded teardown, longmemeval subcommand — `f5e51a50`
- Part 5: LME scorer (Swift) — conformance vectors, report wiring — `15160eaf`
- Part 6: Rust twin — longmemeval_scorer + longmemeval_runner + main.rs subcommand — `81563141`
- Part 7: Diagnostic smoke, corpus loader fix, .gitignore, CHANGELOG — `de33e3fd`
- Adams fix: addressed 2 post-flight WARNINGs (wrong deletingLastPathComponent depth × 2) — `6b0dbe6e`
- Correctness fix: wire n=true inline encoding in both runners — `44303d0f`

## Test Verification Log

- swift build (post n=true fix): exit 0, 1 pre-existing warning (unnecessary await in MCPClient.swift — out of scope)
- swift test (post n=true fix): exit 0, 183 tests in 36 suites, all passing
- cargo build (post n=true fix): exit 0
- cargo test (post n=true fix): exit 0, 92 tests (68 unit + 23 conformance + 1 stdio), all passing
- --limit 2 live smoke (Rust, pre-fix): exit 0, guard=healthy, recall_any@5=1.0 on both questions
- --limit 10 live smoke (Swift, pre-fix): exit 0, guard=healthy, 0 guard refusals, recall_any@10=0.70
- --limit 50 live smoke (Rust, pre-fix): exit 0, guard=healthy, 0 guard refusals, recall_any@10=0.88
- --limit 50 live smoke (Rust, post-fix n=true): exit 0, 50 questions, 0 guard_excluded — recall_any@5=0.78, recall_any@10=0.86, MRR=0.618, p50=1.52s, p95=2.17s
- --limit 50 live smoke (Swift, post-fix n=true): exit 0, 50 questions, 0 guard_excluded — recall_any@5=0.76, recall_any@10=0.90, MRR=0.621, p50=1.48s, p95=2.61s

Pre-fix numbers are documented in FINDINGS as a baseline comparison.
Post-fix v2 numbers are the valid baseline; see FINDINGS for full tables and per-question agreement analysis.

## Correctness Finding: Background Encoding Race (n=true Fix)

The `moot_file_memory` tool supports an `n: bool` parameter (documented in
`AriaMcpKit/Sources/AriaMCP/ToolProjection.swift`). When `n=true`, the memory is encoded
for semantic search INLINE before the write returns. When `n=false` (default), encoding is
background — the write returns immediately but the memory is not yet searchable.

Both LME runners previously omitted `n=true`. The ingest loop wrote all haystack turns with
background encoding, then issued the recall query. On any question where the encoding queue
had not fully drained before the query ran, the recall numbers were artificially low. All
pre-fix smoke numbers are suspect.

Fix applied in `44303d0f`:
- Swift: `writeArgs["n"] = .bool(true)` after the `constantArgs` loop in `LongMemEvalRunner.swift`
- Rust: `args.insert("n", JsonValue::Bool(true))` after the `constant_args` loop in `ingest_turn()` in `longmemeval_runner.rs`

The fix increases write latency (each write blocks on encoding) but guarantees the correctness
invariant: ingest → encode → query, with no race. Conformance tests (scoring math only) are
unaffected; they don't issue live MCP calls.

## Discoveries

- **has_answer field absent in real corpus**: the real HuggingFace longmemeval
  corpus turns don't have `has_answer`. Only our hand-authored synthetic sample
  has it. Fixed in both loaders: `#[serde(default)]` in Rust, `decodeIfPresent ?? false` in Swift.
- **docs_internal is a symlink to EE**: in the CE worktree, `docs_internal/`
  is a symlink pointing at `/Users/bob/devlop/mootx01-ee/docs_internal`. Any
  writes there go to EE. Only `docs/` (not `docs_internal`) should be written
  to from CE missions. Caught and corrected during Part 7.
- **Per-twin score divergence is expected**: Swift and Rust legs scoring the
  same questions against separate mootx01 instances produce different results
  because moot_memory_search ranking is non-deterministic at the embedding
  level. Conformance vectors verify the MATH is correct; live recall scores
  vary by run.
- **SplitMix64 shuffle is consistent**: same seed (20260725) → same question
  IDs in same order across both twins. GauntletRNG/SplitMix64 implementations
  are in sync.
- **Background encoding race**: moot_file_memory n=false (default) allows
  background encoding; a recall query issued after ingest completes may still
  miss un-encoded turns. LME harness must always use n=true.
- **CE deletingLastPathComponent depth is 3 not 4**: CE layout is
  `Sources/mcp-benchmarker/<file>` (3 levels to apps/mcp-benchmarker/). EE had
  an additional `swift-bench/` wrapper requiring 4 levels. Both path helpers
  corrected in Adams post-flight fix.

## Outstanding

- Full 500-question baseline run not in scope (takes ~4.5 hours single-threaded).
- LLM-judge QA accuracy scoring (answer quality beyond session retrieval) not in scope.
- Multi-session (`m`) and oracle variant smoke runs not in scope.
