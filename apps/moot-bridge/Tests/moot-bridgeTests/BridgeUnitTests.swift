import Foundation
import Testing
@testable import moot_bridge

// BridgeUnitTests.swift — pure-logic tests for the bridge's classify + translate +
// config layers. No live backends; these are deterministic and fast. The live
// end-to-end acceptance proof lives in BridgeAcceptanceTests.swift.

// MARK: - Config

@Suite("BridgeConfig decode")
struct BridgeConfigTests {

    /// A minimal two-backend config decodes, and `primary` resolves to a real
    /// backend name.
    @Test func minimalConfigDecodes() throws {
        let json = """
        {
          "backendA": {
            "name": "mempalace",
            "command": "mempalace-mcp --palace /tmp/x",
            "verbMap": {
              "write": "mempalace_add_drawer",
              "query": "mempalace_search",
              "constantArgs": { "wing": "scratch", "room": "notes" },
              "resultFormat": { "kind": "jsonObjects", "contentKey": "text" }
            }
          },
          "backendB": {
            "name": "mootx01",
            "command": "mootx01 serve",
            "verbMap": {
              "write": "moot_file_memory",
              "query": "moot_memory_search",
              "constantArgs": { "location": "scratch/notes" },
              "resultFormat": { "kind": "mootText" }
            }
          },
          "primary": "mempalace"
        }
        """
        let config = try JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8))
        #expect(config.backendA.name == "mempalace")
        #expect(config.backendB.name == "mootx01")
        #expect(config.primary == "mempalace")
        #expect(config.backendA.verbMap.write == "mempalace_add_drawer")
        #expect(config.backendA.verbMap.constantArgs["wing"] == "scratch")
        #expect(config.backendB.verbMap.write == "moot_file_memory")
    }

    /// A `primary` that names no configured backend fails fast at load.
    @Test func unknownPrimaryRejected() throws {
        let json = """
        {
          "backendA": { "name": "a", "command": "x", "verbMap": { "write": "w", "query": "q" } },
          "backendB": { "name": "b", "command": "y", "verbMap": { "write": "w", "query": "q" } },
          "primary": "c"
        }
        """
        #expect(throws: ConfigError.self) {
            _ = try JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8))
        }
    }

    /// A missing required verb surfaces as ConfigError.missingField, not a raw
    /// DecodingError.
    @Test func missingWriteVerbRejected() throws {
        let json = """
        {
          "backendA": { "name": "a", "command": "x", "verbMap": { "query": "q" } },
          "backendB": { "name": "b", "command": "y", "verbMap": { "write": "w", "query": "q" } },
          "primary": "a"
        }
        """
        #expect(throws: ConfigError.self) {
            _ = try JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8))
        }
    }
}

// MARK: - Classify

@Suite("BridgeServer.classifyCall")
struct ClassifyTests {
    private let verbMap = VerbMap(write: "moot_file_memory", query: "moot_memory_search")

    @Test func writeToolClassifiesWrite() {
        #expect(BridgeServer.classifyCall(toolName: "moot_file_memory", verbMap: verbMap) == .write)
    }

    @Test func queryToolClassifiesQuery() {
        #expect(BridgeServer.classifyCall(toolName: "moot_memory_search", verbMap: verbMap) == .query)
    }

    /// An unrelated tool name is unclassifiable (nil) — it is served from the
    /// primary alone and never fanned out to the secondary.
    @Test func unknownToolIsUnclassifiable() {
        #expect(BridgeServer.classifyCall(toolName: "moot_lens_drift", verbMap: verbMap) == nil)
    }
}

// MARK: - Translate

@Suite("BridgeServer.translateCall")
struct TranslateTests {
    // Primary = MemPalace, secondary = mootx01.
    private let mempalace = VerbMap(
        write: "mempalace_add_drawer", query: "mempalace_search",
        contentArg: "content", queryArg: "query",
        constantArgs: ["wing": "scratch", "room": "notes"],
        resultFormat: .jsonObjects(idKey: nil, contentKey: "text"))
    private let mootx01 = VerbMap(
        write: "moot_file_memory", query: "moot_memory_search",
        contentArg: "content", queryArg: "query",
        constantArgs: ["location": "scratch/notes"],
        resultFormat: .mootText)

    private func parse(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    /// A MemPalace write translates into a mootx01 write: secondary tool name,
    /// secondary constantArgs (location), content carried over, fresh disjoint id.
    @Test func writeTranslatesToSecondaryTool() throws {
        let clientCall = parse("""
        {"jsonrpc":"2.0","id":42,"method":"tools/call",
         "params":{"name":"mempalace_add_drawer",
                   "arguments":{"wing":"scratch","room":"notes","content":"hello bridge"}}}
        """)
        let data = try #require(BridgeServer.translateCall(
            clientParsed: clientCall, callType: .write,
            primaryVerbMap: mempalace, secondaryVerbMap: mootx01, freshID: 7))
        let out = try JSONDecoder().decode(JSONValue.self, from: data)

        // Fresh, disjoint id — never the client's 42.
        #expect(out["id"] == .number(7))
        #expect(out["params"]?["name"]?.stringValue == "moot_file_memory")
        let argObj = try #require(out["params"]?["arguments"]?.objectValue)
        // Content carried over under the secondary's contentArg.
        #expect(argObj["content"] == .string("hello bridge"))
        // Secondary's constant write-context present.
        #expect(argObj["location"] == .string("scratch/notes"))
        // The primary-only constantArgs (wing/room) are NOT leaked to mootx01.
        #expect(argObj["wing"] == nil)
        #expect(argObj["room"] == nil)
    }

    /// The reverse direction: a mootx01 write translates into a MemPalace write,
    /// injecting MemPalace's two-key constant context (wing + room).
    @Test func writeTranslatesReverseDirection() throws {
        let clientCall = parse("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call",
         "params":{"name":"moot_file_memory",
                   "arguments":{"content":"reverse content","location":"scratch/notes"}}}
        """)
        let data = try #require(BridgeServer.translateCall(
            clientParsed: clientCall, callType: .write,
            primaryVerbMap: mootx01, secondaryVerbMap: mempalace, freshID: 3))
        let out = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(out["params"]?["name"]?.stringValue == "mempalace_add_drawer")
        let argObj = try #require(out["params"]?["arguments"]?.objectValue)
        #expect(argObj["content"] == .string("reverse content"))
        #expect(argObj["wing"] == .string("scratch"))
        #expect(argObj["room"] == .string("notes"))
    }

    /// A write with no content cannot be mirrored → nil (caller counts a failure).
    @Test func writeWithoutContentReturnsNil() throws {
        let clientCall = parse("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call",
         "params":{"name":"mempalace_add_drawer","arguments":{"wing":"scratch","room":"notes"}}}
        """)
        #expect(BridgeServer.translateCall(
            clientParsed: clientCall, callType: .write,
            primaryVerbMap: mempalace, secondaryVerbMap: mootx01, freshID: 1) == nil)
    }
}

// MARK: - Bridge tool schemas

@Suite("Bridge tool schemas")
struct ToolSchemaTests {
    @Test func setPrimarySchemaShape() {
        let schema = BridgeServer.bridgeSetPrimaryToolSchema()
        #expect(schema["name"]?.stringValue == "bridge_set_primary")
        let required = schema["inputSchema"]?["required"]?.arrayValue
        #expect(required == [.string("backend")])
    }

    @Test func statusSchemaShape() {
        let schema = BridgeServer.bridgeStatusToolSchema()
        #expect(schema["name"]?.stringValue == "bridge_status")
        #expect(schema["inputSchema"]?["type"]?.stringValue == "object")
    }
}

// MARK: - Stats

@Suite("BridgeStats")
struct BridgeStatsTests {
    @Test func latencyAndFailureAccumulate() async {
        let stats = BridgeStats()
        await stats.recordLatency(0.010, label: "mempalace.tools/call")
        await stats.recordLatency(0.020, label: "mempalace.tools/call")
        await stats.recordLatency(0.005, label: "mootx01.tools/call.mirror")
        await stats.recordSecondaryFailure()
        let snap = await stats.snapshot()
        // Series sorted by label: mempalace.* then mootx01.*
        #expect(snap.series.count == 2)
        #expect(snap.series[0].label == "mempalace.tools/call")
        #expect(snap.series[0].totalCount == 2)
        #expect(abs(snap.series[0].mean - 0.015) < 1e-9)
        #expect(snap.secondaryFailureCount == 1)
    }
}
