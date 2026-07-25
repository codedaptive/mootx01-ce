# Cookbook math coverage

Coverage was audited on 2026-07-22 against the canonical registry in
`docs/validation/substrate_math_performance/test-harness/primitive-catalog.md`
and the current cookbook on `develop/1.0.x` at `b3fcd1dc`.

## Result

- **29/29 conformant primitives are in `catalog-bench`** for both Swift and
  Rust. A timed run cannot begin until the canonical vectors pass.
- **29/29 produced full-run measurements** in the published Apple M4 bundle.
- **86/86 operation-specific SubstrateML cells** are covered by `ml-bench`,
  including `community_detection`, whose production reference is live but
  whose canonical vector harness is still pending.
- The recent deterministic classifier v4 additions are covered separately by
  `fdc-bench`: full encode, anchor encode without novelty recording, semantic
  candidate generation, and semantic decision over five input classes.
- The shipped product is covered separately by `product-bench.py`; it measures
  resident loopback MCP requests and does not substitute microbenchmarks for
  product latency.
- Adversarial product retrieval is covered by the historical EE gauntlet retest:
  200 queries across lexical, semantic, temporal, split-fact, and scatter tiers
  over 1,040 records. Its current result is MOOT-only; MemPalace was not rerun.

## Coverage map

| Cookbook area | Canonical primitives | Broad validation timing | Focused timing |
|---|---|---:|---|
| Exact fingerprint core | `simhash`, `hamming`, `or_reduce`, `bitwise`, `fingerprint`, `fnv`, `bit_field_masked_equals`, `merkle_commitment` | Swift + Rust | stress, top-K |
| Time and coordinate math | `hlc`, `lattice`, `partial_state_recall`, `temporal_compression`, `moment_summary`, `shingle_similarity` | Swift + Rust | ML where applicable |
| Statistical/learning math | `anomaly`, `info_theory`, `bradley_terry`, `matrix_decay`, `field_presence_matrix_f`, `sampling` | Swift + Rust | ML sweep |
| Matrix and graph math | `fft`, `nmf`, `eigenvalue_centrality`, `association_rule_mining`, `formal_concept_analysis` | Swift + Rust | ML sweep; community detection included in ML |
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
| One-predicate bitmap filter at 1M rows | Unverified | Product/substrate benchmark with a materialized 1M-row bit-slice |
| Full working-set scan around 1 ms | Unverified | Defined row schema, row count, projection, and cold/hot-cache runs |
| iPhone capture P99 | Unverified on device | Physical iPhone run of the product-boundary workload |
| 1M-row product recall | Unverified | Seeded 1M-row estate; current product run has 120 measured writes |
| Cold-path 1M-row budgets | Not established by the current ML grid | Scale-specific data generators and full-pass measurements |

Those gaps are recorded as gaps rather than inferred from smaller inputs.
