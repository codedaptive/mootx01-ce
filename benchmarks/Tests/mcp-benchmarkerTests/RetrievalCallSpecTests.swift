import Testing
import Foundation
@testable import mcp_benchmarker

// RetrievalCallSpecTests — unit tests for the retrieval seam parsing logic.
//
// These tests cover `retrievalCallSpec(from:)`, the testable helper that
// `retrievalCallSpecFromEnvironment()` delegates to. The seam CALL itself
// (retrieveThroughSeam hitting a live MCP tool) is integration-testable only;
// the manual repro for call-time failure is documented in RetrievalCallSpec.swift.
//
// Regression coverage for D-2026-08-20-A: a malformed MOOT_BENCH_RETRIEVAL_ARGS
// must throw rather than silently drop its arguments or fall back to the default
// door. An invalid-args seam is a misconfigured run; recording the unit under
// default-door results would produce a mislabeled cell.

@Suite("RetrievalCallSpec — seam parsing")
struct RetrievalCallSpecTests {

    // MARK: — no tool → nil (seam inactive)

    @Test("no MOOT_BENCH_RETRIEVAL_TOOL returns nil (seam inactive)")
    func noToolReturnsNil() throws {
        let spec = try retrievalCallSpec(from: [:])
        #expect(spec == nil, "absent tool must return nil, not a spec")
    }

    @Test("empty MOOT_BENCH_RETRIEVAL_TOOL returns nil")
    func emptyToolReturnsNil() throws {
        let spec = try retrievalCallSpec(from: ["MOOT_BENCH_RETRIEVAL_TOOL": ""])
        #expect(spec == nil, "empty tool string must be treated as absent")
    }

    // MARK: — valid tool, no args

    @Test("tool set without args returns a spec with empty extraArgs")
    func toolOnlyReturnsSpecWithNoArgs() throws {
        let spec = try retrievalCallSpec(from: [
            "MOOT_BENCH_RETRIEVAL_TOOL": "moot_recall_precise",
        ])
        guard let s = spec else {
            Issue.record("expected non-nil spec when tool is set")
            return
        }
        #expect(s.tool == "moot_recall_precise")
        #expect(s.extraArgs.isEmpty, "no MOOT_BENCH_RETRIEVAL_ARGS → empty extraArgs")
    }

    @Test("empty MOOT_BENCH_RETRIEVAL_ARGS is treated as absent (no args)")
    func emptyArgsIsTreatedAsAbsent() throws {
        let spec = try retrievalCallSpec(from: [
            "MOOT_BENCH_RETRIEVAL_TOOL": "moot_memory_search",
            "MOOT_BENCH_RETRIEVAL_ARGS": "",
        ])
        guard let s = spec else {
            Issue.record("expected non-nil spec")
            return
        }
        #expect(s.extraArgs.isEmpty, "empty MOOT_BENCH_RETRIEVAL_ARGS → empty extraArgs")
    }

    // MARK: — valid tool + valid JSON object args

    @Test("tool + valid JSON object args returns spec with extraArgs")
    func toolWithValidArgsReturnsSpec() throws {
        let argsJSON = #"{"ordering":"byRelevanceDesc","limit":20}"#
        let spec = try retrievalCallSpec(from: [
            "MOOT_BENCH_RETRIEVAL_TOOL": "moot_memory_search",
            "MOOT_BENCH_RETRIEVAL_ARGS": argsJSON,
        ])
        guard let s = spec else {
            Issue.record("expected non-nil spec")
            return
        }
        #expect(s.tool == "moot_memory_search")
        // Verify the two keys parsed.
        #expect(s.extraArgs["ordering"] != nil, "ordering key must be present")
        #expect(s.extraArgs["limit"] != nil, "limit key must be present")
    }

    // MARK: — D-2026-08-20-A regression: invalid args must throw, not silently fallback

    @Test("invalid MOOT_BENCH_RETRIEVAL_ARGS (non-JSON string) throws MCPError")
    func invalidArgsNonJsonThrows() {
        // An args value that is not JSON at all must be rejected at parse time
        // so the run never reaches the MCP call with silently-dropped args.
        #expect(throws: MCPError.self) {
            _ = try retrievalCallSpec(from: [
                "MOOT_BENCH_RETRIEVAL_TOOL": "moot_recall_precise",
                "MOOT_BENCH_RETRIEVAL_ARGS": "not-json",
            ])
        }
    }

    @Test("invalid MOOT_BENCH_RETRIEVAL_ARGS (JSON array, not object) throws MCPError")
    func invalidArgsJsonArrayThrows() {
        // A JSON array is syntactically valid JSON but not a key-value object.
        // The spec requires an object; an array is rejected to prevent silent
        // argument loss (the array elements would be unreachable as named args).
        #expect(throws: MCPError.self) {
            _ = try retrievalCallSpec(from: [
                "MOOT_BENCH_RETRIEVAL_TOOL": "moot_memory_search",
                "MOOT_BENCH_RETRIEVAL_ARGS": #"["byRelevanceDesc"]"#,
            ])
        }
    }

    @Test("invalid MOOT_BENCH_RETRIEVAL_ARGS (JSON string scalar) throws MCPError")
    func invalidArgsJsonStringThrows() {
        #expect(throws: MCPError.self) {
            _ = try retrievalCallSpec(from: [
                "MOOT_BENCH_RETRIEVAL_TOOL": "moot_recall_precise",
                "MOOT_BENCH_RETRIEVAL_ARGS": #""byRelevanceDesc""#,
            ])
        }
    }

    @Test("error from invalid args names the required-object constraint")
    func invalidArgsErrorNamesConstraint() {
        do {
            _ = try retrievalCallSpec(from: [
                "MOOT_BENCH_RETRIEVAL_TOOL": "moot_recall_precise",
                "MOOT_BENCH_RETRIEVAL_ARGS": "frontier_k:bad",   // not valid JSON
            ])
            Issue.record("expected throw, got success")
        } catch let e as MCPError {
            // The error message must mention the variable name so the operator
            // knows which env var to fix.
            #expect(e.description.contains("MOOT_BENCH_RETRIEVAL_ARGS"),
                    "error must name the bad variable; got: \(e.description)")
        } catch {
            Issue.record("expected MCPError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: — Manual repro note for call-time seam failure
    //
    // A syntactically valid but server-rejected args value (e.g.
    // frontier_k:"bad" where the tool expects an integer) cannot be tested
    // at the unit level because it requires a live mootx01 MCP session.
    //
    // Manual repro (requires a running harness):
    //   MOOT_BENCH_RETRIEVAL_TOOL=moot_memory_search \
    //   MOOT_BENCH_RETRIEVAL_ARGS='{"frontier_k":"bad"}' \
    //   mcp-benchmarker longmemeval --variant s --data-dir <corpus> \
    //     --mootx01-binary <binary> --limit 1
    //
    // Expected: run fails with an error naming the unit (question ID) and the
    // seam args (tool=moot_memory_search, extraArgs=["frontier_k": "bad"]).
    // Pre-fix behavior: unit was recorded with rankings from the default door
    // (moot_memory_search with no override args) — a mislabeled cell.
}
