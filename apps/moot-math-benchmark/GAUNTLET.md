# Historical retrieval gauntlet retest

This is the current MOOT-side retest of the adversarial retrieval gauntlet in
`codedaptive/mootx01-ee/tools/mcp-benchmarker`. It uses the historical seed,
corpus generator, scoring rules, query depths, and degeneracy guard against the
released `mootx01 1.0.34` product.

The retest does **not** rerun MemPalace. Historical MemPalace values are context,
not a current head-to-head result, and the current report therefore records
superiority as `NOT EVALUABLE`.

## Workload

- Seed: `20260611`
- 200 ground-truth queries: 40 in each tier T1–T5
- 1,040 filed records: needles, split partners, and four adversarial
  distractors per needle
- Search depths: recall@1, recall@5, and recall@10; query limit 20
- Metrics: recall@k, MRR, completeness, distractor contamination, mean latency,
  and P95 latency
- Product path: MCP stdio through `mootx01 serve --db gauntlet`
- Isolation: named estate under a temporary `MOOTX01_DATA_DIR`
- Guard: healthy; three distinct corpus queries produced non-degenerate rankings

The five tiers test lexical collisions, semantic near-misses, superseded facts,
facts split across records, and facts scattered away from topical neighbours.

## Like-for-like aggregate comparison

The historical rows are from EE
`tools/mcp-benchmarker/results/20260611-gauntlet-v1/report-fast-correct-final.txt`,
tracked by commit `ba2485d18a58be08918c0aad11b9395f52a18897`.
Current rows are from the raw 1.0.34 report in this evidence bundle.

| Strategy | Run | f@1 | f@5 | f@10 | MRR | Complete | Contamination | Mean | P95 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| MemPalace | historical reference | 0.20 | 0.49 | 0.49 | 0.300 | 0.43 | 1.56 | 37.3 ms | 38.1 ms |
| `mootx01:raw` | historical MOOT | 0.12 | 0.40 | 0.58 | 0.251 | 0.74 | 1.82 | 148.6 ms | 168.2 ms |
| `mootx01:raw` | MOOT 1.0.34 | 0.12 | 0.42 | 0.56 | 0.251 | 0.65 | 1.76 | 146.7 ms | 181.6 ms |
| `precise:text` | historical MOOT | 0.14 | 0.43 | 0.69 | 0.275 | 0.70 | 2.22 | 203.1 ms | 215.3 ms |
| `precise:text` | MOOT 1.0.34 | 0.21 | 0.48 | 0.71 | 0.331 | 0.70 | 2.21 | 31.1 ms | 47.4 ms |
| `precise:text+temporal` | historical MOOT | 0.21 | 0.41 | 0.70 | 0.318 | 0.73 | 1.77 | 197.3 ms | 207.2 ms |
| `precise:text+temporal` | MOOT 1.0.34 | 0.23 | 0.48 | 0.71 | 0.341 | 0.74 | 1.74 | 30.1 ms | 42.6 ms |
| `precise:text+assembly` | historical MOOT | 0.14 | 0.54 | 0.86 | 0.333 | 0.82 | 2.18 | 208.1 ms | 217.8 ms |
| `precise:text+assembly` | MOOT 1.0.34 | 0.21 | 0.56 | 0.85 | 0.369 | 0.82 | 2.18 | 32.2 ms | 49.0 ms |
| `precise:weighted-all` | historical MOOT | 0.09 | 0.18 | 0.22 | 0.127 | 0.22 | 0.73 | 188.1 ms | 200.4 ms |
| `precise:weighted-all` | MOOT 1.0.34 | 0.26 | 0.41 | 0.54 | 0.335 | 0.68 | 1.52 | 31.1 ms | 43.7 ms |

On unchanged named compositions, mean precise-recall latency improved by
6.05×–6.55× and P95 improved by 4.44×–4.86×. Quality did not move uniformly:
`text`, `text+temporal`, and `text+assembly` improved at f@1 and MRR, while
`text+assembly` moved from 0.86 to 0.85 at f@10. Ordinary `moot_memory_search`
did not materially improve and its P95 increased from 168.2 ms to 181.6 ms.

## Current product findings

- `precise:weighted-all` is the aggregate f@1 winner at 0.26, MRR 0.335,
  31.1 ms mean, and 43.7 ms P95.
- `precise:text+assembly` has the best aggregate f@10 at 0.85 and is the only
  useful split-fact result: T4 f@5 0.40 and f@10 0.75.
- `precise:text+temporal` retains the intended temporal strength: T3 f@1 0.95,
  f@10 1.00, and MRR 0.975 at 29.9 ms mean / 42.6 ms P95.
- `precise:text+mmr` is a clear outlier at 1,634.1 ms mean and 3,787.9 ms P95.
  It should not be used as evidence that precise recall generally has
  interactive latency.
- The ordinary raw/RRF product path averages about 147 ms on this estate and
  completely misses the split-fact tier at the measured depths.

## Provenance and limitations

The EE harness was built at
`fb0e77796efe9560860fb323c6def60988efb11e`. Compared with the source immediately
before the historical report was tracked, the scorer is unchanged and the
corpus generator differs only in comments and its consolidated path. A
temporary two-file harness change added a target-only mode which suppresses
MemPalace startup, load, guard, and report columns; it did not change corpus
generation, MOOT writes, MOOT query arguments, scoring, or the MOOT degeneracy
guard. The source-native report records this as a dirty two-path checkout.

The tested binary SHA-256 is
`bc940718884951b1f4ec98779e8e3094b6d4993ca73ba97eb962c36d6817bb38`.
Corpus and artifact hashes are recorded in
[`gauntlet-provenance.json`](results/2026-07-22-apple-m4-b3fcd1dc-evidence/gauntlet-provenance.json).
The complete source-native results are available as
[`JSON`](results/2026-07-22-apple-m4-b3fcd1dc-evidence/gauntlet-moot-1.0.34.json)
and a [`rendered report`](results/2026-07-22-apple-m4-b3fcd1dc-evidence/gauntlet-moot-1.0.34.txt).

This remains a single-host, single-full-run result. The current full run reused
the estate created by a successful quick validation run, so its reported
latencies are query-phase measurements; corpus load and dream/reindex time are
not included. Normal product background drain/governor activity remained
enabled. No current claim about MemPalace superiority or regression is valid
until both products are rerun together under the same current conditions.

The controlled follow-up is specified in
[`MAC_M5_MAX_PERFORMANCE_COMPARISON_MISSION.md`](../../docs/engineering/MAC_M5_MAX_PERFORMANCE_COMPARISON_MISSION.md):
matched Mac mini M4 and MacBook Pro M5 Max runs with fixed hashes, fresh
estates, repeated measurements, phase timing, and paired analysis.
