# MOOTx01 1.0.35 — Final Benchmark Report

Version: v1.0
Status: final — the measurement record of the 1.0.x line at its closing
release (v1.0.35, measurement-frozen per CHANGELOG).

## Results

All cells: 50-question samples, seed 20260725, LongMemEval variant `s`,
scratch estates, background encoding with the lane-evidence drain
barrier, both harness implementations (Swift and Rust twins,
conformance-locked on shared vectors).

| Benchmark | Metric | Swift | Rust | Protocol |
|---|---|---|---|---|
| LongMemEval (s) | Recall-any@5 | 0.86 | 0.88 | documented client protocol (`--exact-strategy auto`) |
| LongMemEval (s) | MRR | 0.675 | 0.719 | same |
| LoCoMo | any@5 | 0.240 | 0.207 | N=3 mean, exact-only runner |
| LMEB | nDCG@10 | 0.465 | 0.464 | N=3 mean |

Run-to-run LME spread across the weekend's valid cells was 0.82–0.92
any@5; per-cell deltas under 0.06 should be read as noise. The 30
abstention questions are excluded per upstream methodology.

## Methodology

- **Documented client protocol**: the harness drives the program the way
  its own tool descriptions instruct a client to behave —
  `ordering: byRelevanceDesc`, escalating to `moot_recall_precise` when
  the response reports low discrimination. Legacy bare-search cells were
  also measured (0.82–0.92 band) and are superseded by the
  protocol-driven cells as the headline numbers.
- **Sample size**: 50 questions per run, seed-deterministic
  (seed 20260725). Full-set runs were not part of the 1.0.x record; any
  external comparison should state the sample size prominently.
- **Isolation**: every question provisions a scratch estate under
  `/tmp/lme-bench-*`; ingest via live MCP `moot_file_memory`, query via
  live MCP; drain barrier requires lane evidence before queries run.
- **Twins**: the Swift and Rust harness implementations must agree on
  shared conformance vectors; both twins' numbers are reported wherever
  both ran.
- **All benchmarks run are reported**, including the weak LoCoMo cells
  (hard open-domain-heavy sample; reported as measured).

## Known-and-kept 1.0.x traits

Annotated in code and deliberately unchanged on this frozen line:
distillation factoids supersede within their own lineage chains while
the change-blind chunked corpus index keeps originals searchable. The
1.1.x line redesigns this area; 1.0.x ships as measured.

## Artifact index (this directory)

- `20260728-lme-strategy/` — the strategy-comparison grid; source of the
  headline LME documented-protocol cells.
- `20260728-lme-uncontaminated/` — first post-ordering-fix LME cells.
- `20260728-full-matrix/` — the full-matrix grid run.
- `20260727-invalidated-rerun/` — drain-grid cells; LoCoMo/LMEB cells
  valid, LME cells superseded by the ordering fix.
- `20260726-official-rerun/` — overnight quiet grid; source of the
  LoCoMo and LMEB N=3 means.
- `20260726-official-quietrun/` — companion quiet-run grid.
- `FINDINGS-2026-07-26-token-efficiency.md` — token-efficiency two-arm
  findings (byte-ratio artifact analysis).
- Diagnostic smoke reports (`*_DIAGNOSTIC_SMOKE_*.md`) and per-mission
  completion notes (`COMPLETION_LME-*.md`).

Reproduce: `apps/mcp-benchmarker` — fetch scripts download the public
datasets from their original sources (never redistributed); one command
per benchmark; seed-deterministic.
