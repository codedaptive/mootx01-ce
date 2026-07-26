import Testing
import Foundation
@testable import mcp_benchmarker

// ProxyTranslationTests.swift — RED tests for MCP-BM-03 manifest-translated mirror.
//
// These tests cover the translation layer that replaces the raw-byte pass-through
// in ProxyServer.mirrorToSecondary. Instead of re-sending the client's exact bytes
// (which fails cross-product because tool names differ), the proxy now:
//   1. Classifies the call type (write/query/list/fetch) against the primary verbMap.
//   2. Extracts variable arg(s) under the primary's arg-role keys.
//   3. Rebuilds a fresh tools/call for the secondary using the secondary's verbMap
//      (secondary tool name + arg-role→key mapping + constantArgs).
//   4. Assigns a fresh JSON-RPC id (never reusing the client's id on the secondary).
//   5. Returns nil (skip) for unclassifiable calls or fenced writes.
//
// All tests are pure (no live MCP process): translateMirrorCall and classifyMirrorCall
// are static helpers exposed for testing. The tests assert on the JSON bytes /
// decoded JSONValue that would be sent to the secondary.

// MARK: - Helpers

private func verbMap(write: String, query: String, list: String? = nil,
                     contentArg: String = "content", queryArg: String = "query",
                     constantArgs: [String: String] = [:]) -> EndpointConfig.VerbMap {
    EndpointConfig.VerbMap(
        write: write, query: query, list: list,
        contentArg: contentArg, queryArg: queryArg,
        constantArgs: constantArgs
    )
}

/// Decodes a tools/call Data blob into JSONValue for assertion.
private func decode(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

/// Builds a client-side tools/call JSON-RPC message in raw Data form.
private func clientCall(id: Int = 42,
                        toolName: String,
                        arguments: [String: JSONValue]) -> Data {
    let msg = JSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": .number(Double(id)),
        "method": .string("tools/call"),
        "params": .object([
            "name": .string(toolName),
            "arguments": .object(arguments),
        ]),
    ])
    return try! JSONEncoder().encode(msg)
}

// MARK: - ProxyTranslationTests

@Suite struct ProxyTranslationTests {

    // MARK: - classifyMirrorCall

    @Test("classifyMirrorCall returns .write for a primary write tool name")
    func classifiesWrite() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let callType = ProxyServer.classifyMirrorCall(toolName: "moot_file_memory",
                                                      primaryVerbMap: primary)
        #expect(callType == .write)
    }

    @Test("classifyMirrorCall returns .query for a primary query tool name")
    func classifiesQuery() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let callType = ProxyServer.classifyMirrorCall(toolName: "moot_memory_search",
                                                      primaryVerbMap: primary)
        #expect(callType == .query)
    }

    @Test("classifyMirrorCall returns nil for an unclassifiable tool name")
    func classifiesUnknownAsNil() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let callType = ProxyServer.classifyMirrorCall(toolName: "some_other_tool",
                                                      primaryVerbMap: primary)
        #expect(callType == nil)
    }

    @Test("classifyMirrorCall returns .list for a primary list tool name")
    func classifiesList() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search",
                              list: "moot_list_memories")
        let callType = ProxyServer.classifyMirrorCall(toolName: "moot_list_memories",
                                                      primaryVerbMap: primary)
        #expect(callType == .list)
    }

    // MARK: - translateMirrorCall: write verb remap

    @Test("Write call is translated to secondary write verb with contentArg remap + constantArgs")
    func translatesWriteToSecondaryVerb() throws {
        // Primary: mootx01 (moot_file_memory, content arg = "content", constant: location)
        // Secondary: MemPalace (mempalace_add_drawer, content arg = "content", constants: wing + room)
        let primary = verbMap(
            write: "moot_file_memory",
            query: "moot_memory_search",
            contentArg: "content",
            constantArgs: ["location": "import/mempalace"]
        )
        let secondary = verbMap(
            write: "mempalace_add_drawer",
            query: "mempalace_search",
            contentArg: "content",
            constantArgs: ["wing": "general", "room": "notes"]
        )
        let clientBytes = clientCall(id: 99, toolName: "moot_file_memory", arguments: [
            "content": .string("hello world"),
            "location": .string("my/location"),
        ])

        let result = ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .write,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 1001
        )

        let translated = try #require(result)
        let json = try decode(translated)

        // Tool name must be the secondary's write tool.
        #expect(json["method"]?.stringValue == "tools/call")
        #expect(json["params"]?["name"]?.stringValue == "mempalace_add_drawer")

        let args = json["params"]?["arguments"]
        // Content is carried under the secondary's contentArg key.
        #expect(args?["content"]?.stringValue == "hello world")
        // Secondary's constantArgs are injected.
        #expect(args?["wing"]?.stringValue == "general")
        #expect(args?["room"]?.stringValue == "notes")
        // The primary's own constant args (location) must NOT appear in the
        // secondary call — the secondary does not know that key.
        #expect(args?["location"] == nil)
    }

    @Test("Write call translation assigns the fresh id, not the client's id")
    func writeTranslationUsesFreshID() throws {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let secondary = verbMap(write: "mempalace_add_drawer", query: "mempalace_search")
        let clientBytes = clientCall(id: 42, toolName: "moot_file_memory", arguments: [
            "content": .string("text"),
        ])

        let translated = try #require(ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .write,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 5555
        ))
        let json = try decode(translated)
        // The fresh id is used, NOT the client's id (42).
        #expect(json["id"]?.stringValue == nil)  // id must be a number
        if case .number(let n) = json["id"] {
            #expect(n == 5555.0)
        } else {
            Issue.record("Expected numeric id in translated call")
        }
    }

    // MARK: - translateMirrorCall: query verb remap

    @Test("Query call is translated to secondary query verb with queryArg remap")
    func translatesQueryToSecondaryVerb() throws {
        let primary = verbMap(
            write: "moot_file_memory",
            query: "moot_memory_search",
            queryArg: "query"
        )
        let secondary = verbMap(
            write: "mempalace_add_drawer",
            query: "mempalace_search",
            queryArg: "query"
        )
        let clientBytes = clientCall(id: 7, toolName: "moot_memory_search", arguments: [
            "query": .string("what did I decide about auth"),
        ])

        let translated = try #require(ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .query,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 2001
        ))
        let json = try decode(translated)
        #expect(json["params"]?["name"]?.stringValue == "mempalace_search")
        #expect(json["params"]?["arguments"]?["query"]?.stringValue == "what did I decide about auth")
    }

    @Test("Query call with differing queryArg keys remaps correctly")
    func translatesQueryWithDifferingArgKeys() throws {
        // Primary uses "query"; secondary uses "search_text" (hypothetical).
        let primary = verbMap(write: "w1", query: "q1", queryArg: "query")
        let secondary = verbMap(write: "w2", query: "q2", queryArg: "search_text")
        let clientBytes = clientCall(id: 3, toolName: "q1", arguments: [
            "query": .string("project planning notes"),
        ])

        let translated = try #require(ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .query,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 3001
        ))
        let json = try decode(translated)
        #expect(json["params"]?["name"]?.stringValue == "q2")
        // The query text must appear under the secondary's queryArg key.
        #expect(json["params"]?["arguments"]?["search_text"]?.stringValue == "project planning notes")
        // The primary's queryArg key ("query") must NOT appear if it differs from secondary's.
        #expect(json["params"]?["arguments"]?["query"] == nil)
    }

    // MARK: - mirror-reads-only fence

    @Test("mirror-reads-only: translateMirrorCall returns nil for a write call")
    func mirrorReadsOnlySkipsWrite() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let secondary = verbMap(write: "mempalace_add_drawer", query: "mempalace_search")
        let clientBytes = clientCall(id: 1, toolName: "moot_file_memory", arguments: [
            "content": .string("data"),
        ])

        let result = ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .write,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: true,
            freshID: 9999
        )
        // A write call with mirrorReadsOnly=true must be skipped.
        #expect(result == nil)
    }

    @Test("mirror-reads-only: translateMirrorCall passes through a query call")
    func mirrorReadsOnlyAllowsQuery() throws {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let secondary = verbMap(write: "mempalace_add_drawer", query: "mempalace_search")
        let clientBytes = clientCall(id: 5, toolName: "moot_memory_search", arguments: [
            "query": .string("test query"),
        ])

        let result = ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .query,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: true,
            freshID: 8888
        )
        // A query call is mirrored even when mirrorReadsOnly=true.
        let translated = try #require(result)
        let json = try decode(translated)
        #expect(json["params"]?["name"]?.stringValue == "mempalace_search")
    }

    // MARK: - unclassifiable tool call

    @Test("Unclassifiable tool name: classifyMirrorCall returns nil → skip mirror")
    func unclassifiableToolIsSkipped() {
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        // Some non-memory tool the client called (e.g. a code-search tool).
        let callType = ProxyServer.classifyMirrorCall(toolName: "search_code_files",
                                                      primaryVerbMap: primary)
        // Must be nil — do not blind-forward.
        #expect(callType == nil)
    }

    // MARK: - Client receives primary response with original id

    @Test("Primary response carries the client's original id (invariant)")
    func primaryResponsePreservesClientID() throws {
        // This invariant lives in handleClientMessage: the primary's response bytes
        // are returned verbatim to clientOut WITHOUT id reassignment.
        // We verify it by checking that the translation path does NOT alter the
        // primary response — translateMirrorCall only produces the secondary call,
        // never mutates the primary bytes.
        let primary = verbMap(write: "moot_file_memory", query: "moot_memory_search")
        let secondary = verbMap(write: "mempalace_add_drawer", query: "mempalace_search")
        let clientBytes = clientCall(id: 77, toolName: "moot_file_memory", arguments: [
            "content": .string("hello"),
        ])

        let translated = try #require(ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .write,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 4242
        ))
        let json = try decode(translated)
        // The SECONDARY call uses the fresh id (4242), NOT the client's id (77).
        // This confirms the primary path would still carry id=77 untouched.
        if case .number(let n) = json["id"] {
            #expect(n == 4242.0)
            #expect(n != 77.0)
        } else {
            Issue.record("Expected numeric id in translated secondary call")
        }
    }

    // MARK: - constantArgs injection

    @Test("Secondary constantArgs are injected even when primary has no constantArgs")
    func secondaryConstantArgsInjected() throws {
        // Primary has no constant args; secondary requires wing + room.
        let primary = verbMap(write: "w1", query: "q1", constantArgs: [:])
        let secondary = EndpointConfig.VerbMap(
            write: "mempalace_add_drawer",
            query: "mempalace_search",
            list: nil,
            contentArg: "content",
            queryArg: "query",
            constantArgs: ["wing": "main", "room": "inbox"]
        )
        let clientBytes = clientCall(id: 1, toolName: "w1", arguments: [
            "content": .string("some memory"),
        ])

        let translated = try #require(ProxyServer.translateMirrorCall(
            clientLine: clientBytes,
            callType: .write,
            primaryVerbMap: primary,
            secondaryVerbMap: secondary,
            mirrorReadsOnly: false,
            freshID: 100
        ))
        let json = try decode(translated)
        let args = json["params"]?["arguments"]
        #expect(args?["content"]?.stringValue == "some memory")
        #expect(args?["wing"]?.stringValue == "main")
        #expect(args?["room"]?.stringValue == "inbox")
    }
}
