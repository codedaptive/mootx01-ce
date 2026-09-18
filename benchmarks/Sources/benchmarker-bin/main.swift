import mcp_benchmarker

// main.swift — the thin executable shell for the core benchmarker. All CLI
// logic lives in the library target (CLI.swift) so extension subpackages
// and the test target can build on the same code; this file only forwards the
// process arguments.
await benchmarkerMain(Array(CommandLine.arguments.dropFirst()))
