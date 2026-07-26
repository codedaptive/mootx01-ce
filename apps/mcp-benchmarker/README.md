# mcp-benchmarker

LME (LongMemEval) benchmarking harness for MOOTx01 — Swift and Rust twin runners
covering longmemeval, token-efficiency (LME-03), LoCoMo (LME-04), and LMEB (LME-06).

## Subcommands

Eleven subcommands (see `mcp-benchmarker help` for full usage):

- `longmemeval` — run LongMemEval-S/M/oracle benchmark via live mootx01
- `lmeb` — run LMEB retrieval benchmark
- `locomo` — run LoCoMo benchmark
- `gauntlet` — run retrieval gauntlet against a corpus
- `gauntlet-corpus` — generate a gauntlet corpus
- `transfer` — migrate data between two MCP memory servers
- `benchmark` — manifest-replay verification
- `serve` — transparent passthrough MCP proxy
- `pressure` — write-concurrency load test
- `quality` — embedding quality scan
- `report` — render a JSON report

## PORT_NOTES — develop/1.1.x delta from develop/1.0.x

These notes document every change made when porting the `apps/mcp-benchmarker`
tree from the merged `develop/1.0.x` state (post LME fan-in) to `develop/1.1.x`.

### Date ported

2026-07-26

### Source

Merged from `develop/1.0.x` after the LME fan-in of three streams:
- `stream/lme-locomo` (LME-04 LoCoMo runner)
- `stream/lme-lmeb` (LME-06 LMEB runner)
- `stream/lme-tokeneff` (LME-03 token efficiency arm + FINDINGS)

### Delta 1 — inline encoding barrier: `n` → `impatient` (REQUIRED)

**Scope:** six runner files (3 Swift, 3 Rust)

**Why:** AriaMcpKit in 1.1.x renamed the `moot_file_memory` inline-encoding
parameter from `n` to `impatient`. The semantic is identical: `true` means
"inline-encode before returning." Without this rename the benchmarker silently
skips encoding and every recall query returns zero results.

**Files changed:**

| File | Line changed |
|---|---|
| `Sources/mcp-benchmarker/LongMemEvalRunner.swift` | `writeArgs["n"]` → `writeArgs["impatient"]` |
| `Sources/mcp-benchmarker/LoCoMoRunner.swift` | `writeArgs["n"]` → `writeArgs["impatient"]` |
| `Sources/mcp-benchmarker/LMEBRunner.swift` | `writeArgs["n"]` → `writeArgs["impatient"]` |
| `rust/src/longmemeval_runner.rs` | `"n"` → `"impatient"` in `args.insert(...)` |
| `rust/src/lmeb_runner.rs` | `"n"` → `"impatient"` in `args.insert(...)` |
| `rust/src/locomo_runner.rs` | `"n"` → `"impatient"` in `args.insert(...)` |

All four tool names (`moot_file_memory`, `moot_memory_search`,
`moot_recall_distilled`, `moot_consolidate`) are unchanged in 1.1.x.

**Verification:** confirmed in
`packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift` —
`let impatient = try optionalBool(args["impatient"], argument: "impatient") ?? false`

### No other deltas

No other AriaMcpKit API changes affected the benchmarker. IntellectusLib
and ObserverSink API surfaces referenced in benchmarker code are
compatible without changes.

### Build + test status on 1.1.x

- `swift build`: exit 0 (warnings only, pre-existing)
- `swift test`: exit 0, 232 tests (baseline 232)
- `cargo build`: exit 0
- `cargo test`: exit 0, 143 tests (lib 98 + conformance 44 + stdio_client 1)
- `--limit 2 longmemeval` smoke: exit 0, guard healthy: 2/2, recall-any@10 0.50, dense/exact ratio 0.798 (2026-07-26)

