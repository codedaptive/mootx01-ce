# Run conditions

- Local date: 2026-07-22 (UTC artifacts crossed into 2026-07-23)
- Repository: `mootx01-ce`, branch `develop/1.0.x`
- Commit: `b3fcd1dc59b3fc022a55eda8ece54d1ac9135c99`
- Host: Mac mini `Mac16,10`
- CPU: Apple M4, arm64, 10 physical / 10 logical cores
- Memory: 24 GiB
- OS: macOS 27.0, build 26A5388g
- Swift: 6.4 development toolchain (`swift-driver 1.167`)
- Rust: 1.97.0 stable (Homebrew)
- Rust kernel set: scalar only; no pinned nightly toolchain was installed
- Swift kernel registrations measured: scalar, SIMD, NEON, Metal
- Product: release build `mootx01 1.0.34 (2026-07-20)`
- Product isolation: resident loopback HTTP daemon, temporary data directory,
  temporary estate deleted after the run
- Product dataset: one warmup write plus 120 measured writes
- Retrieval gauntlet harness: `codedaptive/mootx01-ee/tools/mcp-benchmarker` at
  `fb0e77796efe9560860fb323c6def60988efb11e`, with a temporary two-file
  MOOT-only execution change; generator, scorer, query arguments, and guard
  unchanged
- Retrieval gauntlet dataset: seed `20260611`, 200 queries, 1,040 records,
  40 queries in each T1–T5 tier, four distractors per needle
- Retrieval gauntlet execution: product MCP stdio, temporary named estate,
  normal background drain/governor activity enabled; full query grid reused the
  already loaded and dreamed estate from its successful validation pass
- Retrieval gauntlet comparator: MemPalace was not rerun; historical values are
  context only and current superiority is not evaluable
- Stress/top-K/ML timing: 50 ms warmup + 200 ms measurement per cell
- Catalog/FDC timing: 30 ms warmup + 120 ms measurement per cell
- Benchmark mode: full; no `--quick`

The machine was not placed in a controlled thermal laboratory state and normal
desktop background activity was not disabled. Kernel tables therefore publish
best observed steady-state values; product data retains every raw sample and
publishes percentiles.
