# Benchmark result inventory

This directory contains raw, reviewable benchmark evidence. It is not a
leaderboard and it does not contain a single product score.

## Tracked result sets

| Result directory | Hardware | Languages | Coverage | JSON files |
|---|---|---|---|---:|
| `2026-05-18-apple-m5-max` | Apple M5 Max | Swift, Rust | Hamming, SimHash, OR-reduce; Swift top-K | 7 |
| `2026-05-22-apple-m5-max` | Apple M5 Max | Swift, Rust | Top-K cross-port baseline | 2 |
| `2026-05-29-apple-m5-max` | Apple M5 Max | Swift, Rust | Hamming, SimHash, OR-reduce, top-K, SubstrateML | 10 |
| `2026-05-29-apple-m5-max-88788de-crosslang` | Apple M5 Max | Rust, Go, Python | Hamming, SimHash, OR-reduce, top-K | 12 |

The inventory describes what is present. It does not imply that runs from
different dates or conditions are directly comparable.

## Coverage status

| Area | Present | Still needed |
|---|---|---|
| Maintained ports | Swift and Rust on Apple M5 Max | More Apple generations and non-Apple Rust hardware |
| Additional languages | Go and Python kernel evidence | Repeat runs and maintained-port status decisions |
| Hot-path kernels | Hamming, SimHash, OR-reduce, top-K | Broader x86_64/aarch64 platform matrix |
| Cold-path math | Swift/Rust SubstrateML on Apple M5 Max | Additional hardware and repeated-run variance |
| Memory quality | None | Versioned corpus, queries, expected evidence, scoring, latency, and cost |

## Reading a result

Before citing a number, verify:

1. `schema_version`, operation, language, and hardware tag;
2. commit and toolchain provenance where the schema carries them;
3. full versus quick timing;
4. identical seed and sweep cell;
5. run conditions in `RUN_CONDITIONS.md`, `SUBMISSION.md`, or
   `system-report.txt`;
6. a matching conformance result for optimized kernels.

If any item is unavailable, describe the result as preliminary.

## Adding a result set

Use [`../submit-results.sh`](../submit-results.sh) for the maintained Swift and
Rust ports. The generated directory should contain the JSON outputs, a system
report, and a completed submission note. Follow the schema in
[`../SCHEMA.md`](../SCHEMA.md) and the experimental protocol in
[`../METHODOLOGY.md`](../METHODOLOGY.md).

Aggregation should preserve links to the raw files. Never replace the evidence
with an unattributed summary number.
