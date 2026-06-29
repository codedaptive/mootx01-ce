---
status: measured_first_pass
created: 2026-06-17
last_updated: 2026-06-17
phase: F
relates_to:
  - substrate mathematics treatment (maintainer-internal)
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
  - docs/validation/substrate_math_performance/test-harness/primitive-catalog.md
  - docs/validation/substrate_math_performance/bakeoffs/run_v1_1_bakeoffs.py
  - docs/validation/substrate_math_performance/V1_1_BAKEOFF_FINDINGS_2026-06-17.md
---

# v1.1 Implementation Bakeoffs

The v1.1 math migration added new primitives and new storage choices.
The conformance harness already answers "does this implementation
produce the right bytes?" This document names the new validation tests
that answer a different question: when two correct implementations are
available, which one should ship?

Each bakeoff produces a benchmark JSON plus a short decision record.
No candidate is eligible unless it first passes the existing
cross-language conformance gate or has an explicit reason why the gate
does not apply.

## Decision Rule

For every candidate:

1. Prove semantic correctness against the scalar/reference path.
2. Measure cold start, warm path, memory use, disk size, and rebuild
   cost on the same hardware tag.
3. Measure p50, p95, and p99 latency, not only the best run.
4. Include a small deterministic fixture and at least one large
   estate-shaped workload.
5. Pick the simplest implementation that satisfies the budget unless
   a more complex one wins by at least 20% on the load-bearing metric.

The 20% margin prevents churn over measurement noise.

## Current Implementation

The first executable pass is implemented in
`bakeoffs/run_v1_1_bakeoffs.py`.

```sh
python3 bakeoffs/run_v1_1_bakeoffs.py --scale quick
python3 bakeoffs/run_v1_1_bakeoffs.py --scale standard
```

The standard-scale run on `darwin-arm64` wrote:

- `benchmarks/results/20260617-darwin-arm64/v1_1_bakeoffs_standard.json`
- `V1_1_BAKEOFF_FINDINGS_2026-06-17.md`

This pass is deterministic and synthetic. It establishes the JSON
contract and first implementation decisions for B1 through B10; Phase D
estate-shaped corpus runs and production Swift/Rust backend replacements
can reuse the same result schema.

## Required Bakeoffs

### B1. Bitmap Predicate Storage Bakeoff

**Question.** What is the efficient database/runtime representation
for row predicates?

**Candidates.**

- SQLite row scan over the three `Int64` bitmap columns.
- SQLite indexed/generated-column predicates for common fields.
- mmap bit-slice files per `(column, field, bit)`.
- Compressed bitmap index, e.g. Roaring or WAH, if an in-tree
  implementation is available.

**Workloads.**

- 10K, 100K, 1M, and 10M synthetic rows.
- Single-bit predicate, multi-bit field equality, compound adjective +
  operational + provenance filter.
- Insert/update path, rebuild from SQLite, warm recall filter.

**Winner decides.** The production hot predicate layout and whether
bit-slice files are mandatory before claiming sub-100-microsecond
bitmap recall.

### B2. Dense Vector Storage and Frontier Bakeoff

**Question.** How should provider-owned Float32 vectors be stored and
read for nearest and farthest dense recall?

**Candidates.**

- SQLite BLOB per `(source_id, model_id)`.
- Provider-owned row-aligned mmap pages.
- In-memory index hydrated from compact binary pages.
- Any existing vector-store path already used by CorpusKit/VectorKit.

**Workloads.**

- Dimensions 64, 128, 384, and 768.
- 10K, 100K, and 1M vectorized sources.
- One provider, five-provider default ensemble, and per-provider
  farthest queries for anti-similarity.

**Metrics.** Write throughput, cold-open time, nearest/farthest
frontier latency at K=64/128/256, memory residency, disk bytes per
vector, and hydration join cost back to row ids.

**Winner decides.** Whether dense vectors stay as SQLite BLOBs or move
to provider-specific binary pages, and whether anti-similarity can run
on the same index as nearest recall.

### B3. FloatVecOps Backend Sweep

**Question.** Is the scalar FloatVecOps path good enough, or do we need
backend overrides?

**Candidates.**

- Scalar reference.
- Swift SIMD loop.
- Accelerate or BNNS, only if bit identity can be proven or the path is
  explicitly non-conformance.
- Rust portable SIMD / NEON.

**Workloads.** Norm, normalize, dot, and cosine at dimensions 64, 128,
384, 768, 1536, and batched 256 candidates.

**Winner decides.** Whether `FloatVecOps` remains scalar-only for v1.1
or gets a kernel-dispatched backend.

### B4. JacobiSVD / LSA Basis Build Bakeoff

**Question.** Which deterministic SVD configuration gives acceptable
LSA quality without exceeding the training budget?

**Candidates.**

- Current fixed-sweep one-sided Jacobi SVD at sweep counts 10, 20, 30,
  and 50.
- Incremental or blocked deterministic variants, if implemented.
- Rank choices 16, 32, 64, and 128.

**Workloads.** Term-document matrices from small, medium, and large
estate-shaped corpora with fixed tokenizer and TF-IDF formula.

**Metrics.** Build time, reconstruction error, cross-port bit identity,
query fold-in latency, top-K recall overlap against the full-rank or
curated baseline, and persisted basis size.

**Winner decides.** Default LSA rank and sweep count, plus whether the
current Jacobi implementation needs a blocked variant.

### B5. Association / Apriori / FCA Row-Replay Bakeoff

**Question.** What row-replay representation makes rule mining and
formal concepts practical?

**Candidates.**

- Direct `RowAttributeView` array with naive subset checks.
- Vertical bitsets per item.
- Trie/prefix-tree candidate counting for Apriori.
- Cached projection rows persisted between dreaming passes.

**Workloads.** Synthetic rows with controlled sparsity, plus a real
audit projection when available.

**Metrics.** Projection build time, MatrixO pairwise rule time,
Apriori time by `maxK`, FCA concept time, peak memory, emitted-rule
stability, and cache invalidation cost.

**Winner decides.** Whether row replay remains in-memory only or gets
a persistent derived projection/cache.

### B6. RandomWalk Exploratory Recall Bakeoff

**Question.** Should exploratory recall build adjacency on request or
consume a cached graph projection?

**Candidates.**

- Request-time `[RowId: [RowId]]` adjacency from GLK tunnels.
- Cached RowId adjacency.
- Dense integer adjacency plus RowId mapping.
- Producer-built GraphCache scores for the same graph.

**Workloads.** Sparse, medium, and dense tunnel graphs; steps 100,
1K, 10K; restart probabilities 0.05, 0.15, 0.30.

**Metrics.** Adjacency build time, walk time, memory, result stability,
and recall latency with and without cached graph state.

**Winner decides.** Default exploratory recall path and whether a graph
producer is required before exposing large-estate exploratory recall.

### B7. Q-ID Closure Artifact Bakeoff

**Question.** What artifact shape gives the best closure miss behavior
without wasting memory?

**Candidates.**

- Current JSON direct-edge map plus per-process memo.
- Precomputed closure table.
- Compact binary adjacency.
- SQLite adjacency table.

**Workloads.** Pinned artifact snapshots at small, medium, and full
sizes; hot hit set and cold miss set.

**Metrics.** Artifact size, load time, first closure latency, memo-hit
latency, memory footprint, and closure correctness.

**Winner decides.** Whether `QIDClosureEdges.json` remains direct-edge
JSON or moves to a compact/precomputed artifact.

### B8. HMM Novel-Token Tagger Validation

**Question.** Is the deterministic HMM fallback good enough versus
Apple NLTagger and the table-only fallback?

**Candidates.**

- WordClassTable only.
- WordClassTable plus HMM novel-token fallback.
- Apple NLTagger path, where available.

**Workloads.**

- MASC holdout tokens.
- Curated domain novel-token list.
- Mixed known/unknown token streams.

**Metrics.** Accuracy against held-out labels, agreement with Apple
NLTagger, disagreement clusters, throughput, and cross-port byte
identity for the HMM path.

**Winner decides.** Whether HMM is the default non-Apple fallback and
whether Apple acceleration needs provenance tagging or calibration.

### B9. RecallShape Anti-Similarity and Fusion Bakeoff

**Question.** What is the cost and recall effect of signed weights,
frontier overrides, and dense farthest lanes?

**Candidates.**

- Balanced unionBest.
- Signed weights only.
- Anti-similar dense lanes via farthest scan.
- Anti-similar dense lanes via index-supported farthest query.

**Workloads.** Curated query set with expected "similar", "not like
this", and "broad discovery" intents; five-provider dense ensemble.

**Metrics.** Overhead versus unshaped unionBest, candidate diversity,
K-overlap by shape, MMR interaction, p95 latency, and user-visible
result quality on sampled disagreement cases.

**Winner decides.** Which RecallShape presets are safe as defaults and
whether farthest queries need a specialized index.

### B10. Graph / Preference Producer Cadence Bakeoff

**Question.** How often should derived graph and preference caches
refresh?

**Candidates.**

- Fixed interval cadence.
- Event-count threshold cadence.
- Hybrid interval plus dirty-threshold cadence.
- On-demand rebuild, included only as a baseline to reject if it
  violates recall latency.

**Workloads.** Replay capture streams and recall-feedback streams with
quiet, normal, and bursty periods.

**Metrics.** Cache staleness, recall rank delta versus always-fresh,
CPU time, wakeups, write volume, and battery-mode behavior.

**Winner decides.** Default graph/preference producer cadences and the
dirty-threshold settings in the v1.1 manifest.

## Output Contract

Each bakeoff writes:

- `benchmarks/results/{date}-{hardware}/v1_1_bakeoffs_{scale}.json`
- `V1_1_BAKEOFF_FINDINGS_YYYY-MM-DD.md`

The generated findings must include candidates, hardware tag, command
shape, dataset hash, summary table, selected implementation, rejected
implementations, and whether follow-up production backend measurement is
required.

## Priority

Build in this order:

1. B1 Bitmap Predicate Storage Bakeoff.
2. B2 Dense Vector Storage and Frontier Bakeoff.
3. B9 RecallShape Anti-Similarity and Fusion Bakeoff.
4. B5 Association / Apriori / FCA Row-Replay Bakeoff.
5. B4 JacobiSVD / LSA Basis Build Bakeoff.
6. B10 Graph / Preference Producer Cadence Bakeoff.
7. B6 RandomWalk Exploratory Recall Bakeoff.
8. B7 Q-ID Closure Artifact Bakeoff.
9. B8 HMM Novel-Token Tagger Validation.
10. B3 FloatVecOps Backend Sweep.

B1 and B2 decide the storage architecture. B9 decides whether the new
recall controls are cheap enough to expose broadly. B5, B4, and B10
decide cold-path producer costs. B6-B8 are important but less likely to
force storage-layout changes. B3 is last because the scalar path is the
reference and is likely acceptable until B2 proves otherwise.
