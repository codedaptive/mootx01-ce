# Blast Radius Report — FIX-HARNESS-20260727

**Baseline:** swift test 265 passed, exit 0 (apps/mcp-benchmarker, 2026-07-27);
cargo test exit 0, all suites ok (apps/mcp-benchmarker/rust, 2026-07-27).
**Codegraph:** unavailable in this session — grep-only blast radius (rg, gitignore-aware).
**Mission:** Two harness fixes, delivered together on stream/fix-bench
(fast-forwarded to develop/1.0.x @ 6e320455 before work began):

- **Fix 1 — plaintext scratch estates.** Scratch estates are created encrypted
  by default; every fresh `mootx01 serve` resolves keys via macOS keychain and
  every rebuild invalidates the binary's ad-hoc signature → keychain prompt
  flood. Runners drop mootx01's encryption opt-out marker (`no-encrypt`, per
  `EstateKeyProvider.encryptionOptOutMarkerName`, written into the scratch data
  dir = the estate file's parent dir) before serve launch, so the estate is
  created plaintext (`newPlaintextByOptOut` posture). Default for scratch;
  `--no-plaintext-scratch` opts back into encrypted. Recorded in report JSON as
  run-level `estate_encryption`.
- **Fix 2 — drain-barrier fresh-estate race.** First `moot_drain_status` poll
  can precede corpus-lane wiring; `"drains: none"` parses (correctly) as idle
  and the barrier returns before encoding starts. Verified in GeniusLocusKit
  DrainStatus.swift: the `corpus_encode` lane exists iff `corpusKits[handle]`
  is wired and never deregisters. Fix: split parse result `.idle` into
  `.idle` (Shape B, lane listed, all idle → trust) and `.noLanes` (Shape A →
  accept only after a grace window: ≥4 consecutive noLanes polls AND ≥2.0 s
  elapsed, logged honestly). Outcome struct replaces the Bool return; per-unit
  report key `drain_lane_observed`.

**Scope boundary:** apps/mcp-benchmarker ONLY (both twins) + this report +
completion report. apps/mootx01 and packages/kits are read-only reference.
The 12-run benchmark was killed (per orchestrator); no contention constraint
remains, builds still nice -n 19.

---

## Symbol 1: `lmeScratchDir` / `loCoMoScratchDir` / `lmebScratchDir` (Swift), `lme_scratch_dir` / `locomo_scratch_dir` / `lmeb_scratch_dir` (Rust)
**Change class:** signature (add `posture` parameter, no default — compiler finds all call sites)
**Scope:** internal (Swift) / pub crate (Rust)

| File | Sites | Source | Classification |
|---|---|---|---|
| Sources/mcp-benchmarker/LongMemEvalRunner.swift | def :201; calls :312, :355 (factory closure), :362, :367 | grep | MUST_UPDATE |
| Sources/mcp-benchmarker/LoCoMoRunner.swift | def :129; call :233 | grep | MUST_UPDATE |
| Sources/mcp-benchmarker/LMEBRunner.swift | def :108; call :195 | grep | MUST_UPDATE |
| rust/src/longmemeval_runner.rs | def :173; call :364 | grep | MUST_UPDATE |
| rust/src/locomo_runner.rs | def :99; call :254 | grep | MUST_UPDATE |
| rust/src/lmeb_runner.rs | def :94; call :210 | grep | MUST_UPDATE |
| Tests / rust test modules calling the creators (to be confirmed by compiler) | — | compiler | MUST_UPDATE |

## Symbol 2: `estateCacheEntryURL` / `estate_cache_entry_url`
**Change class:** signature + semantic (posture component joins the run-key —
posture changes estate bytes, so it must partition the cache)
**Scope:** internal / pub

| File | Sites | Source | Classification |
|---|---|---|---|
| Sources/mcp-benchmarker/EstateCache.swift | def :108 | grep | MUST_UPDATE |
| Sources/mcp-benchmarker/LongMemEvalRunner.swift :345 | call | grep | MUST_UPDATE |
| Sources/mcp-benchmarker/LoCoMoRunner.swift, LMEBRunner.swift | calls | grep | MUST_UPDATE |
| Tests/mcp-benchmarkerTests/EstateCacheTests.swift | key-format tests | grep | MUST_UPDATE |
| rust/src/estate_cache.rs + 3 rust runners + rust tests | def + calls | grep | MUST_UPDATE |

Note: key-format change invalidates existing cache entries once — acceptable,
the binary fingerprint already invalidates on every rebuild.

## Symbol 3: `restoreEstateCacheEntry` / `restore_estate_cache_entry`
**Change class:** signature (add `expectedPosture`) + semantic (marker/posture
mismatch after restore → warning + miss, never a silent wrong-posture estate)
**Scope:** internal / pub

Call sites: 3 Swift runners, 3 Rust runners, EstateCacheTests.swift,
estate_cache.rs tests — all MUST_UPDATE (compiler-enforced).

## Symbol 4: `LMERunConfig` / `LoCoMoRunConfig` / `LMEBRunConfig` (Swift), `LmeRunConfig` / `LoCoMoRunConfig` / `LmebRunConfig` (Rust)
**Change class:** field addition (`scratchPosture` / `scratch_posture`)
**Scope:** internal / pub

Every init site: main.swift (3 subcommand builders), rust/src/main.rs (3),
plus test files instantiating configs (known from LME-07: struct additions
break test inits — scan `rg "RunConfig(" Tests/ rust/`). All MUST_UPDATE.

## Symbol 5: `DrainParseResult` (both twins)
**Change class:** semantic (case split: `.idle` keeps Shape-B meaning; new
`.noLanes` takes over Shape A `"drains: none"`)
**Scope:** internal / pub

| File | Sites | Source | Classification |
|---|---|---|---|
| Sources/mcp-benchmarker/EncodeBarrier.swift | parse + switch in waitForEncodeDrain | grep | MUST_UPDATE |
| Tests/mcp-benchmarkerTests/EncodeBarrierTests.swift | parse-result assertions | grep | MUST_UPDATE |
| rust/src/encode_barrier.rs | parse + match + module tests (e.g. `drains_none_is_idle`) | grep | MUST_UPDATE |

## Symbol 6: `waitForEncodeDrain` / `wait_for_encode_drain`
**Change class:** signature (return Bool → outcome struct {converged,
laneObserved}) + semantic (grace-window acceptance of noLanes; post-lane
noLanes keeps polling; transport-death abort retained; unparseable-abort retained)
**Scope:** internal / pub

Call sites (currently discard the Bool): LongMemEvalRunner.swift :438,
LoCoMoRunner.swift :353, LMEBRunner.swift :294, and the three Rust runners.
All MUST_UPDATE — they now capture `laneObserved` into per-unit results.

## Symbol 7: result + report structs (additive fields)
**Change class:** field addition
`LMEQuestionResult` / `LoCoMoQuestionResult` / `LMEBQueryResult` (Swift) and
`LmeQuestionResult` / `LoCoMoQuestionResult` / `LmebQueryResult` (Rust):
new `drainLaneObserved: Bool?` / `drain_lane_observed: Option<bool>`.
Report structs (`LMEReport`, `LoCoMoReport`, `LMEBReport` + Rust twins +
per-question report rows): run-level `estate_encryption` key; per-unit
`drain_lane_observed` key (threaded exactly like the existing `cache_hit`).

Test files instantiating these structs (per LME-07 pattern): scan
`rg "QuestionResult(\|QueryResult(" Tests/ rust/` at implementation time;
every hit MUST_UPDATE with the new field defaulted nil/None.

## Symbol 8: CLI usage surfaces
`--no-plaintext-scratch` added to longmemeval/locomo/lmeb parsing + usage/help
text in main.swift and rust/src/main.rs. Conformance tests assert usage
surfaces match between twins (LME-06/FIX-BENCH pattern) — those assertions are
MUST_UPDATE if they enumerate flags.

### Summary
- MUST_UPDATE: ~30 sites across 16 files (both twins), all enumerated above;
  compiler enforces the signature-change subset.
- INTENTIONALLY_LEFT: scripts/official-rerun-*.sh — they invoke the runners
  with existing flags only; new flag is default-on plaintext, which is the
  desired behavior for those scripts, no edit needed. GauntletCLI scratch
  paths (MemPalace/legacy) — different provisioning path, not a mootx01 serve
  estate creation flow for these three runners' missions; out of the two fixes'
  stated scope.
- RESCOPE_REQUIRED: 0 sites.
