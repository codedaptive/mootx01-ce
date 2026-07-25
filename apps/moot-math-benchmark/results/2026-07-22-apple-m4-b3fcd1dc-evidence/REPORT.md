# Apple M4 evidence bundle

This bundle is the raw evidence behind
[`../../PERFORMANCE.md`](../../PERFORMANCE.md). It contains full, non-quick
Swift and Rust runs for the 29-primitive catalog, deterministic classifier v4,
86-cell ML sweep, exact kernel stress tests, Hamming top-K, and a resident
black-box `mootx01` product run. It also contains the current MOOT-side retest
of the historical EE adversarial retrieval gauntlet.

Headline results:

- 29/29 canonical primitives passed and were timed in both ports.
- Product file-memory P99: 23.753 ms over 120 measured writes.
- Product precise-recall P99: 11.794 ms over 80 calls at 120 rows.
- Product relevance-search P99: 56.274 ms over 80 calls at 120 rows.
- Adversarial gauntlet `precise:text+temporal`: 30.1 ms mean / 42.6 ms P95,
  f@1 0.23 and f@10 0.71 over 200 queries at 1,040 records.
- Adversarial gauntlet `precise:text+assembly`: f@10 0.85 overall and 0.75 on
  the split-fact tier; 32.2 ms mean / 49.0 ms P95.
- Swift SIMD Hamming top-K K=10/N=1,048,576: 655.250 µs minimum;
  the 100 µs cookbook target is not met.

See [`RUN_CONDITIONS.md`](RUN_CONDITIONS.md) before citing any number. JSON
files contain the complete measurements; `product.json` includes every raw
latency sample and the product binary SHA-256. `gauntlet-moot-1.0.34.json`
contains every per-query score and latency; `gauntlet-provenance.json` pins the
binary, harness, corpus, and artifact hashes.
