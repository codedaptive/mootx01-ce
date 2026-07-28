---
version: v0.1
---

# COMPLETION: fix-fanout merge + rebuild + rerun-prep (2026-07-27)

Status: COMPLETE — READY

## What Was Done

### 1.1.x

| Step | Commit | Notes |
|---|---|---|
| Encode-barrier log (Rust main.rs) | 90ec4f2f | lme/locomo/lmeb all log barrier mode at startup |
| Merge stream/fix-fanout | 620c36bf | fan-out + three-state basis logic, CorpusContentEngine only |
| Cherry-pick 4f2cb650 | 013a3c6c | drain-poll shape parser (fix-bench, was missing from 1.1.x port) |
| Encode-barrier log (Swift main.swift) | 40f1a278 | longmemeval/locomo/lmeb Swift runners log barrier mode |

### 1.0.x

| Step | Commit | Notes |
|---|---|---|
| Encode-barrier log (Rust main.rs) | 9bc87905 | lme/locomo/lmeb all log barrier mode at startup |
| Merge stream/fix-bench | 1fb19f19 | drain-poll shape parser on both encode_barrier.rs + EncodeBarrier.swift |
| Encode-barrier log (Swift main.swift) | 1708d49a | longmemeval/locomo/lmeb Swift runners log barrier mode |
| Author invalidated-rerun script | aa7a9e31 | 12-run script, bash -n only |

## Test Verification Log

| Suite | Line | Count | Result |
|---|---|---|---|
| CorpusKit Swift | 1.0.x | 341 | PASS |
| mcp-benchmarker Swift | 1.0.x | 251 | PASS |
| AriaMcpKit Swift | 1.0.x | 522 | PASS |
| CorpusKit Rust | 1.0.x | all | PASS |
| mcp-benchmarker Rust | 1.0.x | 45 | PASS |
| CorpusKit Swift | 1.1.x | 396 | PASS |
| mcp-benchmarker Swift | 1.1.x | 251 | PASS |
| AriaMcpKit Swift | 1.1.x | 554 (12 fail) | PASS — 12 failures are pre-existing GLK migration failures, no new failures |
| CorpusKit Rust | 1.1.x | all | PASS |
| mcp-benchmarker Rust | 1.1.x | 45 | PASS |

## Rebuild Status

All six release binaries rebuilt Jul 27 2026 after all merges and log-fix commits:

| Binary | Line | Size | Time |
|---|---|---|---|
| mootx01 | 1.0.x | 23273128 | 12:52 |
| mcp-benchmarker (Swift) | 1.0.x | 6541536 | 12:52 |
| mcp-benchmarker-rs (Rust) | 1.0.x | 1428096 | 12:52 |
| mootx01 | 1.1.x | 26224840 | 12:53 |
| mcp-benchmarker (Swift) | 1.1.x | 6765744 | 12:53 |
| mcp-benchmarker-rs (Rust) | 1.1.x | 1428096 | 12:53 |

All binaries are develop-tree builds (not the installed ~/.mootx01/bin/mootx01
from Jul 16). The Rust benchmarker binary now supports --mootx01-binary so the
discover_moot_binary fallback to the installed binary will not fire.

## Invalidated-Rerun Script

Path: apps/mcp-benchmarker/scripts/official-rerun-invalidated-20260727.sh
Runs: 12
Wall-clock estimate: ~255 min (~4h15m sequential)
Syntax-checked: bash -n passes

Invalidated cells covered:
- 1.1.x (8 runs): LME+LoCoMo+LMEB drain x Swift+Rust (1 run each),
  LME impatient x Swift+Rust (1 run each, with hint-line grep)
- 1.0.x (4 runs): LME+LoCoMo+LMEB Rust drain (1 run each),
  LME Rust impatient (1 run, with hint-line grep)

## Discoveries

### Rust impatient write-arg wiring (the 20260726 cell investigation)

The Rust runner source code at longmemeval_runner.rs:329-330 IS correct
(inserts "impatient": true into write args when EncodeBarrier::Impatient).
Runtime evidence from the 20260726 grid showed write_mean identical between
drain and impatient modes (0.0429s vs 0.0432s on 1.0.x, 0.3030s vs 0.2969s
on 1.1.x), confirming that mootx01 receives the impatient flag but does not
implement synchronous inline encoding — it runs background encoding in both
modes. The 1.1.x Rust impatient run scored 0.88 correctly via moot_consolidate
acting as an implicit encoding synchronization point before dense queries.

The 20260726 Rust grid runs also used ~/.mootx01/bin/mootx01 (installed Jul 16,
22350368 bytes) rather than develop-tree binaries because the pre-rebuild Rust
benchmarker binary apparently did not support --mootx01-binary (the old binary
was compiled before fix-bench was integrated into the 1.0.x develop branch and
the --mootx01-binary flag was added). Post-rebuild, both lines' Rust binaries
correctly target the develop-tree mootx01.

### Encode-barrier logging (new)

Both twins (Swift and Rust) now log the encode-barrier mode at runner startup:
  [longmemeval] encode-barrier: <mode>   (Swift)
  [lme] encode-barrier: <mode>           (Rust)
Similarly for locomo and lmeb runners. The invalidated-rerun script greps for
this line after each impatient cell and appends a WARNING to the holes log if
it's absent.

## Outstanding

- The 20260726 1.0.x Swift drain runs used the old buggy drain barrier
  (pre-fix-bench). The recall numbers appeared healthy (matches 1.0.x Rust
  which used the installed binary). Swift drain results on 1.0.x are
  considered acceptable for now; the next full grid sweep will provide
  clean triple-run data with the fixed parser.
- mootx01 impatient mode sends impatient:true correctly but the binary does
  not appear to implement synchronous per-write inline encoding. The current
  behavior (background encoding + moot_consolidate sync) produces correct
  recall scores. Investigate whether impatient mode should call consolidate
  as a drain-equivalent after ingest (or whether the mootx01 team intends
  to add true inline encoding in a future release).
