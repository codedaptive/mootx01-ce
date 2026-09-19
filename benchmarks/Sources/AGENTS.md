# AI Knowledge for Swift Benchmark Source

`mcp-benchmarker/` is the Swift measurement implementation and
`benchmarker-bin/` is its thin executable entry point. The Swift leg is the
release measurement instrument.

Implement protocol semantics in the library, keep CLI parsing separate from
scoring, propagate MCP and transport failures, and emit per-question evidence
before summaries. All mutable paths arrive from the Makefile's external work
root. A change to shared behavior requires an equivalent Rust implementation
and literal conformance coverage.
