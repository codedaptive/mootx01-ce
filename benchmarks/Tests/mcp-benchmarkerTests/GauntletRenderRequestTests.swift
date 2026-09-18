import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletRenderRequestTests — pins the exact byte sequence that
// GauntletRunner.renderRequest produces.
//
// The assertion checks the STRING, not a round-trip parse. Parsing back to
// the same object is precisely the check that cannot see key-order
// non-determinism: two JSON strings with keys in different orders produce
// the same parsed object, so a parse-based assertion passes even on a broken
// encoder.
//
// Three or more argument keys are used in each test. A two-key map has only
// two orderings and a broken encoder passes half the time, which reads as a
// flake rather than a defect.

@Suite("renderRequest determinism")
struct GauntletRenderRequestTests {

    // ── exact byte sequence: three args ─────────────────────────────────────

    /// Three-key args whose natural insertion order differs from sorted order.
    /// A broken encoder (no .sortedKeys) would sometimes emit scoring before
    /// query, or query before limit, producing a different string.
    @Test("three-arg moot_memory_search emits arguments and keys in sorted order")
    func threeArgMemorySearch() {
        let args: [String: JSONValue] = [
            "scoring": .string("matrixAware"),
            "limit":   .number(20),
            "query":   .string("What is the archive level of Mirelle Station?"),
        ]
        let result = GauntletRunner.renderRequest(tool: "moot_memory_search", args: args)
        // Outer keys sorted: arguments < tool.
        // Inner keys sorted: limit < query < scoring.
        // JSONEncoder encodes Double 20 as "20" (no decimal).
        let expected = #"{"arguments":{"limit":20,"query":"What is the archive level of Mirelle Station?","scoring":"matrixAware"},"tool":"moot_memory_search"}"#
        #expect(result == expected,
                "renderRequest must produce a byte-identical string for identical inputs; got: \(result)")
    }

    // ── exact byte sequence: four args ──────────────────────────────────────

    /// Four-key args using moot_recall_precise. Verifies sorted keys at both
    /// the outer object level and the inner arguments object level.
    @Test("four-arg moot_recall_precise emits tool and argument keys in sorted order")
    func fourArgPreciseRecall() {
        let args: [String: JSONValue] = [
            "wing":     .string("Agentic Memory"),
            "ordering": .string("byRelevanceDesc"),
            "query":    .string("What did we decide about storage?"),
            "limit":    .number(5),
        ]
        let result = GauntletRunner.renderRequest(tool: "moot_recall_precise", args: args)
        // Inner keys sorted: limit < ordering < query < wing.
        // Outer keys sorted: arguments < tool.
        let expected = #"{"arguments":{"limit":5,"ordering":"byRelevanceDesc","query":"What did we decide about storage?","wing":"Agentic Memory"},"tool":"moot_recall_precise"}"#
        #expect(result == expected,
                "renderRequest must produce sorted keys at every nesting level; got: \(result)")
    }

    // ── idempotency ──────────────────────────────────────────────────────────

    /// Calling renderRequest three times with the same args yields the same
    /// string every time. A non-deterministic encoder would diverge on
    /// repeated calls. Uses five keys so each trial has 120 possible orderings.
    @Test("renderRequest is idempotent across repeated calls")
    func idempotentAcrossRepeatedCalls() {
        let args: [String: JSONValue] = [
            "z_key":   .string("last"),
            "a_key":   .string("first"),
            "m_key":   .number(42),
            "b_key":   .bool(true),
            "n_key":   .number(0),
        ]
        let first  = GauntletRunner.renderRequest(tool: "moot_memory_search", args: args)
        let second = GauntletRunner.renderRequest(tool: "moot_memory_search", args: args)
        let third  = GauntletRunner.renderRequest(tool: "moot_memory_search", args: args)
        #expect(first == second,
                "first and second call must produce identical strings; first=\(first) second=\(second)")
        #expect(second == third,
                "second and third call must produce identical strings; second=\(second) third=\(third)")
    }
}
