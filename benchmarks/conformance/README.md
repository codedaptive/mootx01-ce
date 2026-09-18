# Cross-Port Conformance

AI systems should begin with [`AGENTS.md`](AGENTS.md).

This directory contains literal input/output vectors shared by the Swift and
Rust harness ports. The suites load the same files and must agree on parsing,
normalization, scoring, metric naming, and edge-case behavior before a release
claims twin parity.

Vectors are source fixtures, not benchmark datasets or run output. Add a vector
when a protocol rule can be expressed as deterministic input and expected
output. Do not place downloaded corpora, generated reports, or build products
here.
