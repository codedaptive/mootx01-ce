---
title: Substrate Math Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing conformance, performance, reproduction, and evidence contract for substrate math kernels.
---

# Substrate Math

## Conformance contract

Canonical vectors pair fixed inputs with scalar-reference outputs. Every SIMD,
NEON, Metal, or other optimized kernel must reproduce the required output for
every vector. A kernel that fails conformance is not a performance candidate.

Where the vector contract requires bit identity, comparison is byte-exact.
Where a vector explicitly defines a numerical tolerance, the named tolerance
is part of the vector. The drift check compares the complete conformance output
with the stored baseline and fails on any unapproved movement.

## Performance surfaces

The suite separates four measurement surfaces:

- the catalog benchmark, including expected-output comparison and CRC;
- exact-kernel microbenchmarks for Hamming, SimHash, OR-reduce, and top-k;
- the focused graph and matrix suite for FFT, temporal compression,
  eigenvalue centrality, NMF, and community detection; and
- the end-to-end adversarial Gauntlet through the product retrieval stack.

Do not compare timing across these surfaces as though they measure the same
work. A result names the kernel, operation, input size, batch size, seed,
iterations, warmup and measurement budgets, port, hardware, date, and commit.

## Run procedure

Run the applicable binary from its Swift or Rust package:

```sh
cargo run --release --bin stress-test -- [flags]
swift run -c release stress-test [flags]
```

Use `topk-bench` for dedicated Hamming top-k measurement and `ml-bench` for the
focused graph and matrix suite. Before filing any timing result, run the vector
gate:

```sh
validate-vectors --kernel <name> <vectors>.json
```

Quick mode is a smoke mechanism only. Filed timing uses the full timing budget
on a quiet machine. A cell with fewer than 100 iterations is not filed.

## Evidence and publication

Conformance output, drift result, benchmark JSON, hardware tag, seed, commit,
and invocation flags travel together. Minimum steady-state kernel timing is
not presented as end-to-end product latency. Copy only human-accepted figures
from `../RESULTS_RECORD.md` into a public result register.
