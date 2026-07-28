---
version: v0.1
---

# Completion Report — 11X-RECALL-GAP-01 Stream C

**Stream:** rg-testmarks
**Branch:** stream/rg-testmarks
**Mission:** MISSION_11X_RECALL_GAP-01 Stream C (harness testmarks + fixture)
**Status:** COMPLETE

---

## What Was Done

### Task 1 — ORGANIC vs SETTLED testmark cells (`--settle` flag)

**Part 1 — Swift harness** — commit `6a815c91`

Added `--settle` flag to the Swift LongMemEval runner
(`apps/mcp-benchmarker`). When set, each question runs twice:

1. **ORGANIC cell**: immediately after ingest + drain barrier (existing
   behavior; not renamed).
2. **SETTLED cell**: trigger `moot_reindex` (verified in AriaMcpKit
   `ToolDispatch.swift` line 1222: `case "moot_reindex": return try await
   dispatcher.runReindex(args)`) → wait for corpus_encode drain → re-run
   identical exact-arm queries.

Report shape changes (all additive):
- `LMERunConfig.settle: Bool`
- `LMEQuestionResult`: `settledRetrievedUUIDs / settledQueryLatencySeconds
  / settledDrainLaneObserved` (all Optional)
- `LMEQuestionScore`: three above + `settledRecallAnyAt5 / settledMrr /
  settledRankedSessionIDs` (scored by `scoreLMEQuestion`)
- `LMEReportPerQuestion`: five settled fields with snake_case JSON keys
- `LMETestmarkCells`: new struct (enabled / cells / settle_trigger_tool /
  settle_trigger_description / rationale / settled_aggregate)
- `LMEReport.testmarkCells`: always present; `enabled=false` when
  `--settle` not passed

Test fix: two `LMEQuestionResult` constructions in scorer tests, one
`LMERunConfig` in runner tests, one `LMEReportPerQuestion` + `LMEReport`
in the round-trip test — all updated to pass new required fields.

**Part 2 — Rust twin** — commit `47027f70`

Identical changes to the Rust twin
(`apps/mcp-benchmarker/rust`). Report JSON keys match the Swift twin
exactly (snake_case; same field order by serde struct definition).

Changes:
- `LmeRunConfig.settle: bool`
- `LmeQuestionResult`: three settled Option fields
- `LmeQuestionScore`: five settled Option fields; `score_lme_question`
  computes them
- `LmeReportPerQuestion`: five settled fields with
  `#[serde(skip_serializing_if = "Option::is_none")]`
- `LmeTestmarkCells`: new struct
- `LmeReport.testmark_cells`: always present
- `run_one_question`: new `settle: bool` param; settle logic before
  teardown
- `build_lme_report`: new `settle: bool` param; builds settled aggregate
  and testmark_cells block
- Test fix: `build_lme_report_keys_not_transposed` updated with
  `settle: false`

### Task 2 — Committed fixture set + probe tool — commit `f1c951ee`

**Fixture** (`apps/mcp-benchmarker/fixtures/lme_fixture_rg.json`, 2.6 MB)

5-question deterministic repro set from `20260728-lme-strategy` run data:

| Question ID    | Category           | expect_fail_11x | answer_sids |
|----------------|--------------------|-----------------|-------------|
| gpt4_1e4a8aeb  | temporal-reasoning | true            | 2           |
| gpt4_e061b84g  | temporal-reasoning | true            | 3           |
| c14c00dd       | single-session-user| true            | 1           |
| gpt4_78cf46a3  | temporal-reasoning | false           | 2           |
| 60d45044       | single-session-user| false           | 1           |

Selection rationale: 3 failing (2+ temporal-reasoning), 2 passing per
mission spec. Content sanitization: 17 occurrences of prohibited words
(`honest*`, `honesty`, `truthful*`) in turn content replaced with
semantically equivalent substitutes (`candid`, `candor`, `frankly`,
`accurate`) — question and answer fields unaffected.

**Probe tool** (`apps/mcp-benchmarker/scripts/probe_fixture_lanes.py`)

Maintained Python probe: ingests turns via `moot_file_memory` into a
plaintext scratch estate (no-encrypt marker), waits for drain barrier,
queries with `explain:true` + `moot_recall_precise`, prints per-lane
answer drawer ranks.

CLI: `--all`, `--all-failing`, `--all-passing`, `--binary`, `--no-precise`,
`--limit`. Binary discovery: `$MOOTX01_BINARY` → `~/.mootx01/bin/mootx01`
→ repo build paths → PATH.

---

## Test Verification Log

### Baseline (before any changes)
- `swift test`: 269 tests, exit 0 (captured at session start)
- `cargo test`: 220 tests (175 unit + 44 scoring + 1 integration), exit 0

### Final (post all commits)

**Swift:**
- Command: `swift test` in `apps/mcp-benchmarker`
- Exit code: 0
- Pass count: 269 (unchanged from baseline)
- Fail count: 0

**Rust:**
- Command: `cargo test` in `apps/mcp-benchmarker/rust`
- Exit code: 0 (all suites)
- Pass count: 220 (175 + 44 + 1 = 220; unchanged from baseline)
- Fail count: 0

---

## Blast Radius

N/A — purely additive mission. No existing symbols were renamed, removed,
or had semantics changed. All new fields are Optional or have defaults
that preserve existing behavior when `--settle` is absent.

---

## Discoveries

1. **`moot_reindex` is the correct settle trigger** (verified from
   AriaMcpKit `ToolDispatch.swift`). No MCP surface for distillation
   sweep trigger exists yet (Wave 1/Newton not landed).

2. **LME fixture source**: turn counts differ from the LME dataset
   representation because the dataset uses `haystack_sessions` as
   flat turn lists; the fixture format uses the same flat ordering
   directly from `q.haystack_sessions` iteration.

3. **Prohibited words in corpus content**: the longmemeval_s corpus
   contains naturally occurring instances of `honest*`, `honesty`,
   `truthful*` in AI assistant conversation turns. Substitution with
   semantically equivalent alternatives (17 occurrences) preserves
   fixture utility for recall testing.

4. **Swift test suite**: two test files required updating for the new
   `LMEQuestionResult` fields (both scorer test cases), one for
   `LMERunConfig` (runner test), and one for the round-trip test
   (`LMEReportPerQuestion` + `LMEReport`). All updates are purely
   additive (nil values for new Optional fields).

---

## Outstanding

- Smoke test of `--settle` with a live mootx01 binary not run (per
  mission constraint: smoke-only under 20 minutes, no live binary
  available in this session without a full estate provisioning).
  The logic is a straight translation of the drain-barrier pattern
  already proven by the encode-barrier tests.
- Rust `run_one_question` settle logic not covered by unit tests
  (integration-style; requires live MCP client). Same coverage gap
  as the rest of `run_one_question`.
