import Testing
import Foundation
@testable import mcp_benchmarker

// LMEAgenticSeamTests — unit tests for the lme-agentic answer-command JSON
// wire contract (the request/response shape documented in
// LMEAgenticRunner.swift's header).
//
// The seam is an external subprocess; these tests exercise the pure builders/
// parsers plus one real subprocess round-trip through a /bin/cat-style stub
// (stdin drained, canned JSON response on stdout). No live MCP, no estate,
// no fixture dataset.

@Suite("lme-agentic answer-cmd JSON round-trip")
struct LMEAgenticSeamTests {

    // The request builder must emit every documented field with the caller's
    // values, so an external command can rely on the shape sight-unseen.
    @Test("request JSON carries all documented fields")
    func requestShape() throws {
        let tools: [JSONValue] = [
            .object([
                "name": .string("moot_memory_search"),
                "description": .string("search the estate"),
            ]),
        ]
        let transcript: [JSONValue] = [
            .object([
                "role": .string("assistant"),
                "tool_call": .object([
                    "name": .string("moot_memory_search"),
                    "arguments": .object(["q": .string("swim coach")]),
                ]),
            ]),
            .object([
                "role": .string("tool"),
                "name": .string("moot_memory_search"),
                "content": .string("found 2 memories"),
            ]),
        ]
        let json = try lmeAgenticRequestJSON(
            model: "test-model-1",
            questionID: "q-001_abs",
            question: "Who coached the swim team?",
            questionDate: "2023-05-30",
            tools: tools,
            transcript: transcript,
            maxToolCallsRemaining: 7)

        let obj = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any]
        let root = try #require(obj)
        #expect(root["type"] as? String == "lme_agentic_request")
        #expect(root["version"] as? Int == 1)
        #expect(root["model"] as? String == "test-model-1")
        #expect(root["question_id"] as? String == "q-001_abs")
        #expect(root["question"] as? String == "Who coached the swim team?")
        #expect(root["question_date"] as? String == "2023-05-30")
        #expect(root["max_tool_calls_remaining"] as? Int == 7)
        let toolsArr = try #require(root["tools"] as? [[String: Any]])
        #expect(toolsArr.count == 1)
        #expect(toolsArr[0]["name"] as? String == "moot_memory_search")
        let transcriptArr = try #require(root["transcript"] as? [[String: Any]])
        #expect(transcriptArr.count == 2)
        #expect(transcriptArr[1]["role"] as? String == "tool")
        #expect(transcriptArr[1]["content"] as? String == "found 2 memories")
    }

    // Final-answer responses parse to .answer with the usage block summed by
    // the caller; a missing usage block parses to nil, not zeros.
    @Test("answer response parses with and without usage")
    func answerResponseParses() throws {
        let (step, usage) = try lmeAgenticParseResponse(
            #"{"answer":"blue","usage":{"prompt_tokens":7,"completion_tokens":3}}"#)
        #expect(step == .answer("blue"))
        #expect(usage == LMEAgenticUsage(promptTokens: 7, completionTokens: 3))

        let (bare, noUsage) = try lmeAgenticParseResponse(#"{"answer":"blue"}"#)
        #expect(bare == .answer("blue"))
        #expect(noUsage == nil)
    }

    // Tool-call responses parse to .toolCall; absent arguments default to {}.
    @Test("tool_call response parses; arguments default empty")
    func toolCallResponseParses() throws {
        let (step, _) = try lmeAgenticParseResponse(
            #"{"tool_call":{"name":"moot_recall_precise","arguments":{"q":"coach"}}}"#)
        #expect(step == .toolCall(
            name: "moot_recall_precise",
            arguments: ["q": .string("coach")]))

        let (noArgs, _) = try lmeAgenticParseResponse(
            #"{"tool_call":{"name":"moot_estate_status"}}"#)
        #expect(noArgs == .toolCall(name: "moot_estate_status", arguments: [:]))
    }

    // The one-of contract: neither key, or both keys, is a violation — a
    // silent default would misattribute a malformed turn as an abstention.
    @Test("responses violating the one-of contract throw")
    func contractViolationsThrow() {
        #expect(throws: (any Error).self) {
            _ = try lmeAgenticParseResponse(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try lmeAgenticParseResponse(
                #"{"answer":"x","tool_call":{"name":"moot_memory_search"}}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try lmeAgenticParseResponse("not json at all")
        }
    }

    // Full subprocess round-trip through a /bin/cat-style stub: the request
    // JSON is drained from stdin (cat > /dev/null) and a canned response JSON
    // is printed on stdout — proving the invoke seam delivers the request and
    // returns parseable stdout end to end.
    @Test("stub answer command round-trips request → response")
    func stubCommandRoundTrip() throws {
        let request = try lmeAgenticRequestJSON(
            model: "stub-model",
            questionID: "q-rt",
            question: "round trip?",
            questionDate: "2026-08-26",
            tools: [],
            transcript: [],
            maxToolCallsRemaining: 1)
        let stub = "cat > /dev/null; "
            + #"printf '%s' '{"answer":"round-tripped","usage":{"prompt_tokens":11,"completion_tokens":2}}'"#
        let raw = try lmeAgenticInvokeAnswerCmd(cmd: stub, requestJSON: request)
        let (step, usage) = try lmeAgenticParseResponse(raw)
        #expect(step == .answer("round-tripped"))
        #expect(usage == LMEAgenticUsage(promptTokens: 11, completionTokens: 2))
    }

    // The read-only filter forwards allowlisted entries verbatim and drops
    // everything else; moot_synthesize stays excluded on purpose (the
    // answering AI producing the hypothesis IS the arm).
    @Test("tool surface filter keeps read tools, drops writes and synthesize")
    func toolSurfaceFilter() throws {
        let listResult = JSONValue.object([
            "tools": .array([
                .object(["name": .string("moot_memory_search")]),
                .object(["name": .string("moot_file_memory")]),
                .object(["name": .string("moot_synthesize")]),
                .object(["name": .string("moot_recall_precise")]),
            ]),
        ])
        let surface = try lmeAgenticFilterToolSurface(listResult)
        let names = surface.compactMap { $0["name"]?.stringValue }
        #expect(names == ["moot_memory_search", "moot_recall_precise"])
    }
}
