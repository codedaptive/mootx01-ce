---
title: CVK-WB8 Completion Report
version: v0.1
status: COMPLETE
date: 2026-07-17
---

# Completion Report: CVK-WB8
# Gate perf benchmarks behind MOOT_PERF_BENCH lane flag

Status: COMPLETE

## What Was Done

- **Merge**: Fast-forwarded worktree to include commit 3cbdc4f5 (CVK-WB4 changedColumns wave B merge). Confirmed 226 tests passing baseline before any changes.
- **Convention discovery**: Found existing perf-gating pattern in `GeniusLocusKit/Tests/EncodeDrainNearRealtimeTests.swift` — `.enabled(if: ProcessInfo.processInfo.environment["GLK_LATENCY_TESTS"] == "1", ...)` on the `@Suite` declaration alongside `.serialized`. Matching pattern in `scripts/moot-test` (`run_glk_latency` + `glk-latency` case) and `Makefile` (`test-glk-latency` target).
- **Implementation** — commit f481afdc:
  - `CVK_ICLOUD_P4M5_PerfTests.swift`: Added `.enabled(if: ProcessInfo.processInfo.environment["MOOT_PERF_BENCH"] == "1", "...")` to all four suites (Q1, Q2, Q3, Q5). Updated file header to document the gate, the run command, and the cross-reference to `make test-perf-bench`.
  - `scripts/moot-test`: Added `run_perf_bench()` function (mirrors `run_glk_latency`; sets `MOOT_PERF_BENCH=1 swift test --no-parallel --filter Q1... Q2... Q3... Q5...`); added `perf-bench) run_perf_bench ;;` to the case dispatch.
  - `Makefile`: Added `test-perf-bench` target (calls `$(TEST_RUNNER) perf-bench`); updated `.PHONY` list; added documenting comment block mirroring the `test-glk-latency` block.
  - `TRACKED_FOLLOWUPS.md`: Item 8 marked DONE (CVK-WB8).

## Test Verification Log

### Baseline (pre-change, post-merge)
- Command: `cd packages/kits/ConvergenceKit && swift test`
- Exit code: 0
- Pass count: 226 tests in 42 suites
- Notable: Q5-10k test ran for 76.8s, total bundle 78.1s

### Default mode (post-change — benchmarks gated)
- Command: `cd packages/kits/ConvergenceKit && swift test`
- Exit code: 0
- Pass count: 226 tests in 42 suites, **2.05s total**
- Benchmark suites: skipped (MOOT_PERF_BENCH not set)

### Gated mode (MOOT_PERF_BENCH=1)
- Command: `MOOT_PERF_BENCH=1 swift test --no-parallel --filter Q1StormResistanceTests --filter Q2CoalescingTests --filter Q3PerWriteOverheadTests --filter Q5SideTableTests`
- Exit code: 0
- Pass count: 11 tests in 4 suites, ~79s total
- Q5-10k: 76.5s (expected — this is the slow benchmark)

## Convention Established

`MOOT_PERF_BENCH=1` is the repo-wide env flag for perf-benchmark suites in Swift.
Pattern:
```swift
@Suite("Suite Name",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOOT_PERF_BENCH"] == "1",
                "Perf benchmark suite — run with MOOT_PERF_BENCH=1 or `make test-perf-bench`"))
```
Precedent: `GLK_LATENCY_TESTS` for GeniusLocusKit latency suites (same mechanism, same tooling shape).
Future kits: add `.enabled(if:)` to benchmark suites + add a `--filter BenchmarkSuiteName` line in `run_perf_bench()` in `scripts/moot-test`.

## CI Note

`develop-daily-test.yml` runs `make test-full`, which calls `$(TEST_RUNNER) full` → `unit + product + validation + glk-latency`. ConvergenceKit is in the `unit` scope (under `packages/`). The daily CI sweep does NOT set `MOOT_PERF_BENCH`, so benchmarks are skipped there too. No CI file edits needed — the `.enabled(if:)` gate handles it transparently.

## Discoveries

- No Package.swift change required. The `.enabled(if:)` swift-testing trait gates suites at the runner level without needing a separate test target or conditional compilation.
- All four benchmark suites were already `.serialized` (added in the original P4-M5 mission per the flake doctrine). The only missing piece was the env gate.
- `scripts/moot-test` `run_glk_latency` uses `--filter` alongside the env var. The filter is load-bearing: without it, non-benchmark suites in the same package would run too. The env var is what the Swift `.enabled(if:)` check reads; the `--filter` is what the test runner uses to limit scope to known benchmark suite names.

## Outstanding

- Item 5 (outbox secondary index + readSyncHLC batch-read) remains open; Scorandum Q5 finding is now clearly documented in the test output.
- Items 9, 10, 11 remain open (Rust fieldLevelLWW parity, Federation durable outbox, SyncValueBox depth limit).
