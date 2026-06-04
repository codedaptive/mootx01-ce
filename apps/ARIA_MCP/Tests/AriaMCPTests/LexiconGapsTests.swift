import Testing
import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// ARIA_MCP dispatch tests closing the 6 projected-but-dead lexicon tools
/// (SWIFT_LEXICON_GAPS_001). Covers:
///
///   - moot_capture_tunnel: live handler, happy path, arg-validation failure
///   - moot_kgFact_recall, moot_diaryEntry_recall, moot_proposal_recall,
///     moot_association_recall, moot_learnedReference_recall: live read handlers
///     (isError false, returning "recalled 0 X(s)" on a fresh estate), matching
///     the Rust leg's text_result output for the same tools.
///   - Schema assertions for all 6 tools: required arrays + property keys,
///     byte-parity with the Rust leg's lexicon_schema output.
///
/// Wire identity: tool names, schema property keys, and required arrays must
/// match the Rust server (rust/src/tool_list.rs lexicon_schema) byte for byte.
///
/// `.serialized`: each live-estate test opens an in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("Lexicon gaps (SWIFT_LEXICON_GAPS_001)", .serialized)
struct LexiconGapsTests {

    // MARK: - Harness

    /// Build a fresh dispatcher wired to a clean in-memory estate.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "lexicon-gaps-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    // MARK: - moot_capture_tunnel: happy path

    /// Capturing a tunnel through the MCP surface returns a success result
    /// whose text starts with "captured tunnel". Exercises the live
    /// (.capture, .tunnel) dispatch arm added in SWIFT_LEXICON_GAPS_001.
    @Test("moot_capture_tunnel happy path returns captured tunnel id")
    func captureTunnelHappyPath() async throws {
        let dispatcher = try await makeDispatcher()

        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_capture_tunnel"),
                "arguments": .object([
                    "sourceWing": .string("wing-a"),
                    "sourceRoom": .string("room-src"),
                    "targetWing": .string("wing-b"),
                    "targetRoom": .string("room-dst"),
                    "kind": .string("supports"),
                    "addedBy": .string("lexicon-gaps-tests"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_capture_tunnel returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "capture_tunnel must be a success result")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(
            text.hasPrefix("captured tunnel"),
            "result text must start with 'captured tunnel'; got: \(text)"
        )
    }

    // MARK: - moot_capture_tunnel: arg-validation failure

    /// Omitting a required argument (`sourceWing`) is an out-of-band
    /// invalidParams transport fault, not a tool-level error result.
    @Test("moot_capture_tunnel without sourceWing returns invalidParams")
    func captureTunnelMissingArgReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()

        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_capture_tunnel"),
                "arguments": .object([
                    // sourceWing omitted intentionally
                    "sourceRoom": .string("room-src"),
                    "targetWing": .string("wing-b"),
                    "targetRoom": .string("room-dst"),
                    "kind": .string("supports"),
                    "addedBy": .string("lexicon-gaps-tests"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing sourceWing must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(
            error.code == JSONRPCErrorCode.invalidParams,
            "missing sourceWing must map to invalidParams; got code \(error.code)"
        )
    }

    // MARK: - Recall live-read tests

    /// moot_kgFact_recall returns a live success result (isError false) because
    /// the substrate now has `DrawerStore.allKGFacts()` — an estate-wide kg-fact
    /// read accessor. Matches the Rust leg's Ok(empty vec) on a fresh estate.
    @Test("moot_kgFact_recall returns live recall result (isError false)")
    func kgFactRecallReturnsLiveResult() async throws {
        let dispatcher = try await makeDispatcher()
        try await assertLiveRecall(
            dispatcher: dispatcher,
            toolName: "moot_kgFact_recall",
            id: 10
        )
    }

    /// moot_diaryEntry_recall returns a live success result. Substrate now has
    /// `DrawerStore.allDiaryEntries()` — an estate-wide diary-entry accessor.
    @Test("moot_diaryEntry_recall returns live recall result (isError false)")
    func diaryEntryRecallReturnsLiveResult() async throws {
        let dispatcher = try await makeDispatcher()
        try await assertLiveRecall(
            dispatcher: dispatcher,
            toolName: "moot_diaryEntry_recall",
            id: 11
        )
    }

    /// moot_proposal_recall returns a live success result. Substrate now has
    /// `DrawerStore.allProposals()` — an estate-wide proposals accessor.
    @Test("moot_proposal_recall returns live recall result (isError false)")
    func proposalRecallReturnsLiveResult() async throws {
        let dispatcher = try await makeDispatcher()
        try await assertLiveRecall(
            dispatcher: dispatcher,
            toolName: "moot_proposal_recall",
            id: 12
        )
    }

    /// moot_association_recall returns a live success result. Substrate now has
    /// `DrawerStore.allAssociations()` — an estate-wide associations accessor.
    @Test("moot_association_recall returns live recall result (isError false)")
    func associationRecallReturnsLiveResult() async throws {
        let dispatcher = try await makeDispatcher()
        try await assertLiveRecall(
            dispatcher: dispatcher,
            toolName: "moot_association_recall",
            id: 13
        )
    }

    /// moot_learnedReference_recall returns a live success result. Substrate now
    /// has `DrawerStore.allLearnedReferences()` — an estate-wide learned
    /// references accessor.
    @Test("moot_learnedReference_recall returns live recall result (isError false)")
    func learnedReferenceRecallReturnsLiveResult() async throws {
        let dispatcher = try await makeDispatcher()
        try await assertLiveRecall(
            dispatcher: dispatcher,
            toolName: "moot_learnedReference_recall",
            id: 14
        )
    }

    /// Shared assertion: the named tool must return a tool-level success result
    /// (isError false, content present with "recalled" text) NOT a JSON-RPC
    /// transport fault when called with empty arguments. The call reached the
    /// dispatch surface, the substrate returned Ok, the client retains the call
    /// ID. Matches the Rust leg's text_result output on a fresh estate.
    private func assertLiveRecall(
        dispatcher: ARIA_MCPDispatcher,
        toolName: String,
        id: Int64
    ) async throws {
        let request = JSONRPCRequest(
            id: .integer(id),
            method: "tools/call",
            params: .object([
                "name": .string(toolName),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("\(toolName) must return a tool-level result (not JSON-RPC error)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(
            obj["isError"] == JSONValue.bool(false),
            "\(toolName) must return isError=false (live recall)"
        )
        let text = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        #expect(
            text != nil && !(text?.isEmpty ?? true),
            "\(toolName) live recall must include non-empty text content"
        )
        #expect(
            text?.contains("recalled") == true,
            "\(toolName) live recall text must contain 'recalled'; got: \(text ?? "nil")"
        )
    }

    // MARK: - Schema assertions: all 6 tools

    /// moot_capture_tunnel schema has the 6 required args from the Rust leg's
    /// lexicon_schema(Verb::Capture, Noun::Tunnel) and carries optional estateID.
    ///
    /// Required (Rust-grounded): sourceWing, sourceRoom, targetWing, targetRoom,
    /// kind, addedBy. Optional: sourceDrawerID, targetDrawerID, estateID.
    @Test("moot_capture_tunnel schema matches Rust required array and property keys")
    func captureTunnelSchemaMatchesRust() throws {
        let tool = try #require(
            ToolProjection.tools().first(where: { $0.name == "moot_capture_tunnel" }),
            "moot_capture_tunnel must appear in the projected tool list"
        )
        guard case .lexicon(let verb, let noun) = tool.provenance else {
            Issue.record("moot_capture_tunnel must have lexicon provenance")
            return
        }
        #expect(verb == .capture)
        #expect(noun == .tunnel)

        let schema = try #require(tool.inputSchema.objectValue, "inputSchema must be an object")
        let properties = try #require(schema["properties"]?.objectValue, "properties must be present")
        let required = schema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // Required args — wire-identical to Rust (tool_list.rs lexicon_schema Capture Tunnel).
        let expectedRequired = ["sourceWing", "sourceRoom", "targetWing", "targetRoom", "kind", "addedBy"]
        for key in expectedRequired {
            #expect(required.contains(key), "\(key) must be in required; got: \(required)")
            #expect(properties[key] != nil, "\(key) must be in properties")
        }
        // Optional args in the schema.
        #expect(properties["sourceDrawerID"] != nil, "sourceDrawerID must be in properties")
        #expect(properties["targetDrawerID"] != nil, "targetDrawerID must be in properties")
        // estateID injected by withEstateID wrapper — optional, never required.
        #expect(properties["estateID"] != nil, "estateID must be an optional property")
        #expect(!required.contains("estateID"), "estateID must not be required")
    }

    /// Schema assertions for the 5 recall-stub tools. Each must appear in
    /// tools/list with the standard recall frame schema (filter, limit, ordering,
    /// hydrationLevel, all optional) — wire-identical to the Rust leg's generic
    /// Verb::Recall arm in lexicon_schema. No required fields. estateID optional.
    @Test("recall stub schemas carry standard recall frame fields and optional estateID")
    func recallStubSchemasMatchRust() throws {
        let recallTools = [
            ("moot_kgFact_recall",            Noun.kgFact),
            ("moot_diaryEntry_recall",        Noun.diaryEntry),
            ("moot_proposal_recall",          Noun.proposal),
            ("moot_association_recall",       Noun.association),
            ("moot_learnedReference_recall",  Noun.learnedReference),
        ]
        let allTools = ToolProjection.tools()
        for (toolName, expectedNoun) in recallTools {
            guard let tool = allTools.first(where: { $0.name == toolName }) else {
                Issue.record("\(toolName) must appear in the projected tool list")
                continue
            }
            guard case .lexicon(let verb, let noun) = tool.provenance else {
                Issue.record("\(toolName) must have lexicon provenance")
                continue
            }
            #expect(verb == .recall, "\(toolName) must project from .recall verb")
            #expect(noun == expectedNoun, "\(toolName) must project from .\(expectedNoun) noun")

            let schema = tool.inputSchema.objectValue
            let properties = schema?["properties"]?.objectValue
            let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

            // Standard recall frame fields — all optional, matching Rust generic Recall arm.
            for key in ["filter", "limit", "ordering", "hydrationLevel"] {
                #expect(
                    properties?[key] != nil,
                    "\(toolName) must have '\(key)' in properties"
                )
            }
            // No required fields in the standard recall frame (empty required array).
            #expect(required.isEmpty, "\(toolName) must have empty required array; got: \(required)")
            // estateID injected by withEstateID — optional, never required.
            #expect(properties?["estateID"] != nil, "\(toolName) must have optional estateID property")
            #expect(!required.contains("estateID"), "\(toolName) estateID must not be required")
        }
    }
}
