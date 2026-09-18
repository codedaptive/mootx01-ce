# AI Knowledge for the Rust Benchmark Twin

This crate is the required Rust behavioral twin of the Swift benchmark
instrument. It uses the same protocols and committed conformance vectors. It is
not a separate benchmark definition and must not invent port-specific metrics,
defaults, normalization, or report fields.

Cargo output is directed by `CARGO_TARGET_DIR` beneath `BENCH_WORK_ROOT`. Build
and test through the parent Makefile. A shared behavior change is complete only
when both ports and the applicable cross-port vectors agree.
