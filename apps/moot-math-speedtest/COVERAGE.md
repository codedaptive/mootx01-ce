# Cookbook math coverage

Coverage was re-audited on 2026-08-20 against the canonical registry in
`docs/validation/substrate_math_performance/test-harness/primitive-catalog.md`
and the current tree on `bench/harness` (EE 1.1 line) at `7c98d337c`,
after the W2.5 activation waves (M1 Jaccard, S4-C decayed projections,
S8 QID-adjacency) landed. Previous audit: 2026-07-22 against
`develop/1.0.x` at `b3fcd1dc`.

## Result

- **31/31 conformant primitives are in `catalog-bench`** for both Swift and
  Rust (29 at the prior audit, plus `jaccard` and `qid_adjacency`,
  canonicalized 2026-08-20). A timed run cannot begin until the canonical
  vectors pass.
- **29/29 of the prior-audit set produced full-run measurements** in the
  published Apple M4 bundle; `jaccard` and `qid_adjacency` cells enter at
  the next published run.
- **95/95 operation-specific `ml-bench` cells** are covered (86 at the
  prior audit, plus `qid_adjacency_distance` n∈{100,1k,10k} and the GLK
  `matrix_decayed_co_occurrence`/`matrix_rebuild_temporal_decayed` cells
  at entries∈{1k,10k,100k}), including `community_detection`, whose
  production reference is live but whose canonical vector harness is
  still pending. The decayed-projection cells time the production S4-C
  maintenance pass through a GeniusLocusKit dependency — the one place
  this benchmark reaches above the substrate libs, on purpose.
- The `topk-bench` sweep gained a `--metric jaccard` variant
  (`jaccard_top_k`, scalar brute-force — the production serving path;
  no kernel op exists by design).
- The recent deterministic classifier v4 additions are covered separately by
  `fdc-bench`: full encode, anchor encode without novelty recording, semantic
  candidate generation, and semantic decision over five input classes.
- The shipped product is covered separately by `product-bench.py`; it measures
  resident loopback MCP requests and does not substitute microbenchmarks for
  product latency.
- Adversarial product retrieval is covered by the historical gauntlet retest
  (`benchmarks/`): 200 queries across lexical, semantic,
  temporal, split-fact, and scatter tiers over 1,040 records. Its current
  result is MOOT-only.

## Coverage map

| Cookbook area | Canonical primitives | Broad validation timing | Focused timing |
|---|---|---:|---|
| Exact fingerprint core | `simhash`, `hamming`, `jaccard`, `or_reduce`, `bitwise`, `fingerprint`, `fnv`, `bit_field_masked_equals`, `merkle_commitment` | Swift + Rust | stress, top-K (hamming + jaccard variants) |
| Time and coordinate math | `hlc`, `lattice`, `qid_adjacency`, `partial_state_recall`, `temporal_compression`, `moment_summary`, `shingle_similarity` | Swift + Rust | ML where applicable |
| Statistical/learning math | `anomaly`, `info_theory`, `bradley_terry`, `matrix_decay`, `field_presence_matrix_f`, `sampling` | Swift + Rust | ML sweep |
| Matrix and graph math | `fft`, `nmf`, `eigenvalue_centrality`, `association_rule_mining`, `formal_concept_analysis` | Swift + Rust | ML sweep; community detection included in ML; S4-C decayed projections timed via the GLK maintenance-pass cells |
| Federation and audit | `tier_contribution`, `pairing_handshake`, `audit_log_fold`, `hamming_nn` | Swift + Rust | top-K for Hamming NN |
| Deterministic classification | classifier v4, deterministic data, semantic model | n/a: not a canonical-vector primitive | FDC suite |
| Actual product | capture/file, relevance search, precise recall, status, ping | n/a | isolated resident MCP suite plus 200-query adversarial retrieval gauntlet |

`catalog-bench` parses each vector file before timing, then measures production
math, expected-output comparison, and CRC accumulation over the in-memory
canonical cases. Its
`ns_per_case_min` is useful for broad regression detection, but it is not a
claim about the isolated arithmetic cost. The stress, top-K, ML, and FDC suites
provide operation-shaped measurements where such a claim is needed.

## Remaining evidence gaps

The coverage audit found no missing canonical cookbook primitive in the
benchmark. It did find claims that need different workloads:

| Claim | Current status | Evidence still needed |
|---|---|---|
| Float-NN metrics l2/dot (M2 unlock) | Deliberate gap | Null-by-construction until an unnormalized float provider ships (Part E); cells activate with Part E |
| Distillation-stage math (CorefStage, trailer scanner, TypedDecayWeighting) | Out of scope here | Deterministic per-item pipeline stages; fdc-bench covers classifier v4 only. A distill-bench suite is a separate ruling if wanted |
| One-predicate bitmap filter at 1M rows | Unverified | Product/substrate benchmark with a materialized 1M-row bit-slice |
| Full working-set scan around 1 ms | Unverified | Defined row schema, row count, projection, and cold/hot-cache runs |
| iPhone capture P99 | Unverified on device | Physical iPhone run of the product-boundary workload |
| 1M-row product recall | Unverified | Seeded 1M-row estate; current product run has 120 measured writes |
| Cold-path 1M-row budgets | Not established by the current ML grid | Scale-specific data generators and full-pass measurements |

Those gaps are recorded as gaps rather than inferred from smaller inputs.
