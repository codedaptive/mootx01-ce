import Foundation
import GeniusLocusKit
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

// MARK: - Unit 2 coverage: moot_link_memories, moot_move_memory, moot_update_memory,
// moot_erase_memory, moot_recall_connected, moot_recall_distilled, moot_federated_recall,
// and moot_recollect. Each test calls ToolDispatcher.dispatch with the literal operation
// name and asserts a value from the returned payload that would change if the handler
// were replaced with a no-op stub.
//
// FINDING — moot_recollect unreachable stub:
//   RecipeTools.swift:577 contains a notice-only stub that executes
//   `if name == recollectToolName { return ToolDispatcher.textResult(...) }`.
//   That stub lives inside RecipeTools.dispatch, which has no production caller —
//   ToolDispatcher.dispatch never reaches it. ToolProjection.admitsDispatch returns
//   false for "moot_recollect", so the dispatcher throws -32601 methodNotFound
//   before any decoder or handler runs. The stub is dark code. The test below pins
//   the production behavior: -32601 is always thrown.
//
// NOTE — moot_recall_distilled ACK gate removed:
//   An earlier draft documented an ACK gate for moot_recall_distilled requiring the
//   token "recall_distilled/v2". That gate was deleted in COMPOSER-02B. As of
//   ARIA_MCP_SPEC 2.0.0 §8.6 the operation executes unconditionally without an ACK
//   argument. No ACK token is supplied here; the error path tests a missing required
//   "query" argument instead of an absent ACK.

@Suite("ARIA v2 memory, graph and recall dispatch coverage", .serialized)
struct AriaV2MemoryGraphDispatchCoverageTests {

    // MARK: - Harness

    // Pinned environment prevents BenchClock from reading the process environment,
    // giving deterministic now() inside the dispatcher across all test invocations.
    private static let pinnedEnvironment = [BenchClock.envKey: "2026-09-08T00:00:00Z"]

    /// Builds a single-estate dispatcher backed by InMemoryStorage.
    /// The dispatcher has no registered peers, so `federationSources` is empty —
    /// moot_federated_recall will reach the lower and throw noAuthorizedFederationSource.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-memory-graph-coverage")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (
            ToolDispatcher(
                kit: kit,
                handle: handle,
                environment: Self.pinnedEnvironment),
            kit,
            handle)
    }

    /// Files a memory through the dispatcher and returns its UUID string.
    /// The return value is the canonical lowercase UUID from structuredContent.data.memory_id.
    private func fileMemory(
        _ dispatcher: ToolDispatcher,
        content: String,
        subject: String,
        location: String = "Coverage Inbox"
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(subject),
                "location": .string(location),
            ]))
        let memoryID = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue,
            "moot_file_memory must return structuredContent.data.memory_id")
        _ = try #require(UUID(uuidString: memoryID), "memory_id must be a valid UUID, got: \(memoryID)")
        return memoryID
    }

    /// Returns structuredContent.data as a dictionary, or fails the test.
    private func requireData(
        _ result: JSONValue,
        operation: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: JSONValue] {
        try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue,
            "\(operation) must return structuredContent.data",
            sourceLocation: sourceLocation)
    }

    /// Returns structuredContent.error as a dictionary, or fails the test.
    private func requireError(
        _ result: JSONValue,
        operation: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: JSONValue] {
        try #require(
            result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue,
            "\(operation) must return structuredContent.error",
            sourceLocation: sourceLocation)
    }

    // MARK: - moot_link_memories

    /// Files two memories and links them through the production dispatcher. Asserts
    /// tunnel_id is a valid UUID — a no-op stub cannot produce a real tunnel UUID
    /// because it has no estate access.
    @Test func linkMemoriesDispatchRoundTripReturnsTunnelID() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        #expect(await kit.mountState(for: handle) == .mounted,
                "selected v2 tunnel filing requires a mounted estate")

        let fromID = try await fileMemory(dispatcher, content: "Link source memory for coverage.", subject: "Link source")
        let toID = try await fileMemory(dispatcher, content: "Link target memory for coverage.", subject: "Link target")

        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID),
                "to_id": .string(toID),
                "relationship": .string("relates"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "link must succeed; got: \(result)")
        let d = try requireData(result, operation: "moot_link_memories")
        // tunnel_id is a real UUID created by the estate lower — a stub has no path to
        // produce a valid UUID here, making this the discriminating assertion.
        #expect(UUID(uuidString: d["tunnel_id"]?.stringValue ?? "") != nil,
                "tunnel_id must be a valid UUID; got data: \(d)")
        #expect(d["from_id"] == .string(fromID), "from_id must round-trip")
        #expect(d["to_id"] == .string(toID), "to_id must round-trip")
        #expect(d["kind"] == .string("relates"), "kind must reflect the relationship argument")
    }

    @Test func quiescedSelectedLinkDoesNotCaptureTunnel() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let fromID = try await fileMemory(dispatcher, content: "Quiesced source.", subject: "Quiesced source")
        let toID = try await fileMemory(dispatcher, content: "Quiesced target.", subject: "Quiesced target")
        let estate = try await kit.estate(for: handle)
        let tunnelsBefore = try await estate.allTunnels()
        try await kit.quiesce(handle)
        #expect(await kit.mountState(for: handle) == .quiesced)

        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID),
                "to_id": .string(toID),
                "relationship": .string("relates"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(true),
                "quiesced selected link must be refused by the typed capture verb")
        #expect(try await estate.allTunnels().map(\.id) == tunnelsBefore.map(\.id),
                "a quiesced selected link must not reach tunnel storage")
    }

    /// Missing required argument throws JSONRPCError before reaching the estate.
    @Test func linkMemoriesMissingToIDThrowsInvalidParams() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_link_memories",
                arguments: .object([
                    "from_id": .string(UUID().uuidString),
                    "relationship": .string("relates"),
                ]))
            Issue.record("missing to_id must throw JSONRPCError invalidParams")
        } catch is JSONRPCError {
            // Expected: -32602 invalidParams from the decoder
        }
    }

    // MARK: - moot_move_memory

    /// Files a memory and moves it through the production dispatcher. Asserts
    /// placement.wing and placement.room round-trip the argument values — a stub
    /// returning a generic success has no way to echo these values correctly.
    @Test func moveMemoryDispatchRoundTripReturnsPlacement() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let memoryID = try await fileMemory(
            dispatcher,
            content: "Move coverage seed memory.",
            subject: "Move coverage seed")

        let result = try await dispatcher.dispatch(
            name: "moot_move_memory",
            arguments: .object([
                "memory_id": .string(memoryID),
                "wing": .string("CoverageWing"),
                "room": .string("DestinationRoom"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "move must succeed; got: \(result)")
        let d = try requireData(result, operation: "moot_move_memory")
        #expect(d["memory_id"] == .string(memoryID),
                "memory_id must round-trip — the estate echoes the canonicalized UUID")
        let placement = try #require(d["placement"]?.objectValue, "placement must be present")
        // The handler reads back the actual drawer path; a no-op stub cannot
        // produce the right wing/room without calling the estate lower.
        #expect(placement["wing"] == .string("CoverageWing"), "wing must match argument")
        #expect(placement["room"] == .string("DestinationRoom"), "room must match argument")
    }

    /// An unknown memory_id yields an isError=true refusal (not a throw), because
    /// the dispatcher reached the handler and the estate reported the memory absent.
    @Test func moveMemoryUnknownIDYieldsRefusal() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let result = try await dispatcher.dispatch(
            name: "moot_move_memory",
            arguments: .object([
                "memory_id": .string(UUID().uuidString.lowercased()),
                "wing": .string("SomeWing"),
                "room": .string("SomeRoom"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(true),
                "unknown memory_id must yield isError=true refusal; got: \(result)")
    }

    // MARK: - moot_update_memory

    /// Files a memory and updates it through the production dispatcher using the
    /// "confirm" mutation. Asserts memory_id and mutation echo in data — a no-op
    /// stub has no path to produce these correctly.
    @Test func updateMemoryDispatchRoundTripReturnsMutationField() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let memoryID = try await fileMemory(
            dispatcher,
            content: "Update coverage seed memory.",
            subject: "Update coverage seed")

        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string(memoryID),
                "mutation": .string("confirm"),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "update must succeed; got: \(result)")
        let d = try requireData(result, operation: "moot_update_memory")
        // memory_id and mutation are written by the estate lower and read back;
        // a stub cannot produce these values without calling the actual mutation handler.
        #expect(d["memory_id"] == .string(memoryID),
                "memory_id must round-trip; got data: \(d)")
        #expect(d["mutation"] == .string("confirm"),
                "mutation field must reflect the applied operation; got data: \(d)")
    }

    /// An unsupported mutation name throws JSONRPCError invalidParams at the decoder,
    /// before the estate is reached.
    @Test func updateMemoryUnsupportedMutationThrowsInvalidParams() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_update_memory",
                arguments: .object([
                    "memory_id": .string(UUID().uuidString),
                    "mutation": .string("not_a_real_mutation_verb"),
                ]))
            Issue.record("unsupported mutation must throw JSONRPCError invalidParams")
        } catch is JSONRPCError {
            // Expected: -32602 invalidParams
        }
    }

    // MARK: - moot_erase_memory

    /// Files a memory and erases it through the production dispatcher. Asserts
    /// refused_sibling_memory_ids is an array — the field type proves the expunge
    /// handler ran; a stub returning a generic success has no array to produce.
    @Test func eraseMemoryDispatchRoundTripReturnsRefusedSiblingsArray() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let memoryID = try await fileMemory(
            dispatcher,
            content: "Erase coverage seed memory.",
            subject: "Erase coverage seed")

        let result = try await dispatcher.dispatch(
            name: "moot_erase_memory",
            arguments: .object([
                "memory_id": .string(memoryID),
                "confirmation": .bool(true),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "erase must succeed; got: \(result)")
        let d = try requireData(result, operation: "moot_erase_memory")
        #expect(d["memory_id"] == .string(memoryID),
                "memory_id must round-trip; got data: \(d)")
        // The refused_sibling_memory_ids array is populated by the expunge outcome.
        // A standalone memory has no siblings so the array is empty — the ARRAY TYPE
        // is the discriminating assertion; a stub has no way to produce an empty array
        // under this key without calling the actual expunge lower.
        let _ = try #require(d["refused_sibling_memory_ids"]?.arrayValue,
                             "refused_sibling_memory_ids must be an array from the expunge outcome")
    }

    /// confirmation: false throws JSONRPCError invalidParams at the decoder,
    /// before the estate is touched.
    @Test func eraseMemoryFalseConfirmationThrowsInvalidParams() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let memoryID = try await fileMemory(
            dispatcher,
            content: "Must survive false confirmation erase attempt.",
            subject: "Erase false confirm guard")
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_erase_memory",
                arguments: .object([
                    "memory_id": .string(memoryID),
                    "confirmation": .bool(false),
                ]))
            Issue.record("confirmation:false must throw JSONRPCError invalidParams")
        } catch is JSONRPCError {
            // Expected: -32602 invalidParams
        }
    }

    // MARK: - moot_recall_connected

    /// Files a seed memory and dispatches moot_recall_connected. Asserts the results
    /// key is an array in structuredContent.data — a no-op stub returning an empty
    /// success has no results key, making this the discriminating assertion.
    @Test func recallConnectedDispatchProducesTypedResultsArray() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await fileMemory(
            dispatcher,
            content: "Seed memory for connected recall coverage test.",
            subject: "Connected recall seed")

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("connected recall coverage"),
                "limit": .integer(5),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "recall_connected must succeed; got: \(result)")
        let d = try requireData(result, operation: "moot_recall_connected")
        // results is the typed S1 projection array from structuredS1. Its presence
        // proves the lens handler ran; a stub returning {} has no results key.
        let _ = try #require(d["results"]?.arrayValue,
                             "results must be an array in structuredContent.data")
        // effect:read confirms the meta envelope was constructed by the real handler.
        #expect(
            result.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"),
            "recall_connected effect must be read")
    }

    // MARK: - moot_recall_distilled

    // NOTE: An earlier draft documented an ACK gate requiring "recall_distilled/v2".
    // That gate was deleted in COMPOSER-02B (see RecipeToolsTests.swift:354 and
    // ARIA_MCP_SPEC 2.0.0 §8.6). The operation dispatches unconditionally. The error
    // path here tests a missing required "query" argument, not an absent ACK token.

    /// Files a seed memory and dispatches moot_recall_distilled without an ACK token
    /// (none is required since COMPOSER-02B). Asserts the results key is an array in
    /// structuredContent.data — the discriminating assertion against a no-op stub.
    @Test func recallDistilledDispatchProducesTypedResultsArray() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await fileMemory(
            dispatcher,
            content: "Seed memory for distilled recall coverage test.",
            subject: "Distilled recall seed")

        // No ACK argument — the gate was deleted in COMPOSER-02B.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("distilled recall coverage"),
                "limit": .integer(5),
            ]))
        #expect(result.objectValue?["isError"] == .bool(false),
                "recall_distilled must succeed without ACK since COMPOSER-02B; got: \(result)")
        let d = try requireData(result, operation: "moot_recall_distilled")
        let _ = try #require(d["results"]?.arrayValue,
                             "results must be an array in structuredContent.data")
        #expect(
            result.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"),
            "recall_distilled effect must be read")
    }

    /// Missing required "query" throws JSONRPCError invalidParams at the decoder.
    @Test func recallDistilledMissingQueryThrowsInvalidParams() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_distilled",
                arguments: .object([:]))
            Issue.record("missing query must throw JSONRPCError invalidParams")
        } catch is JSONRPCError {
            // Expected: -32602 invalidParams
        }
    }

    // MARK: - moot_federated_recall

    /// Dispatches moot_federated_recall against a single-estate dispatcher with no
    /// peer grants. The operation reaches the federation lower, which throws
    /// noAuthorizedFederationSource. executeV2Core catches it generically and wraps
    /// it as an isError=true refusal with code "operation_failed". The refusal proves
    /// the production dispatch path was reached — a stub that short-circuits would
    /// not produce structuredContent.error with this code.
    @Test func federatedRecallNoPeerGrantsProducesOperationFailedRefusal() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([:]))
        // isError=true — refusal, not a JSON-RPC protocol throw.
        #expect(result.objectValue?["isError"] == .bool(true),
                "single-estate federated_recall must produce isError=true; got: \(result)")
        let errorObj = try requireError(result, operation: "moot_federated_recall")
        // "operation_failed" is the generic catch re-wrap applied by executeV2Core when
        // the lower throws noAuthorizedFederationSource. A stub short-circuiting before
        // the lower would not produce structuredContent.error at all.
        #expect(errorObj["code"] == .string("operation_failed"),
                "error code must be operation_failed; got error: \(errorObj)")
        #expect(errorObj["message"]?.stringValue?.isEmpty == false,
                "error message must be non-empty")
    }

    // MARK: - moot_recollect

    // FINDING: RecipeTools.swift:577 contains a notice-only stub behind
    // `RecipeTools.dispatch`. That function has no production caller — ToolDispatcher
    // never routes through it. ToolProjection.admitsDispatch("moot_recollect") returns
    // false, so the dispatcher throws -32601 methodNotFound before decoding or handling.
    // The stub is unreachable dead code from the production v2 path.

    /// Pins the current production behavior: moot_recollect throws -32601 methodNotFound
    /// because the tool is absent from the selected v2 catalog. The test name is the
    /// behavioral specification for future readers.
    @Test func recollectIsNotAdmittedByTheSelectedCatalog() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_recollect",
                arguments: .object(["query": .string("any query")]))
            Issue.record("moot_recollect must throw JSONRPCError -32601 methodNotFound, never reach a handler")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.methodNotFound,
                    "moot_recollect must produce code -32601; got code: \(error.code)")
        }
    }

    // MARK: - moot_erase_memory partial-expunge gate

    /// Builds a CaptureFrame for the partial-erase gate test.
    ///
    /// Uses `.typed` channel with a deterministic lattice anchor.
    /// No embedding model is required; the assertion targets the audit gate
    /// at the DrawerStore layer, not the vector-recall lane.
    private func captureFrameForPartialErase(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "partial-erase-gate",
            latticeAnchor: .udc("000"),
            addedBy: "partial-erase-gate",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Gate: erasing a memory whose lineage contains an accepted sibling triggers the
    /// audit gate (S-3: accepted → tombstoned is blocked) and MUST report a partial
    /// verdict in the ARIA v2 response.
    ///
    /// Three assertions all must hold:
    ///   1. outcome field is "erased_partially" (not "erased")
    ///   2. refused_sibling_memory_ids is non-empty; every id is lowercase (D8)
    ///   3. compact text does NOT say "Erased memory" unqualified
    ///
    /// D1 ruling: a partial erasure is a completed operation with a partial verdict;
    /// isError stays false — the rows that were erased ARE gone.
    ///
    /// This test cannot pass on a stub that returns a generic "erased" success; the
    /// expunge verb must reach the audit gate and return the refused IDs to the caller.
    @Test func eraseMemoryPartialExpungeReportsErasedPartiallyOutcome() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Seed d1: capture, promote trust to canonical, then accept.
        // The audit gate (S-3: accepted → tombstoned is blocked) will refuse to
        // tombstone d1 when the expunge below walks the lineage.
        let d1 = try await kit.capture(
            handle,
            captureFrameForPartialErase(
                content: "accepted gate-sibling — audit refuses its tombstone"),
            mode: .impatient)
        try await kit.mutate(
            handle,
            MutateFrame(rowID: d1.id, kind: .correctTrust(.canonical)))
        try await kit.mutate(
            handle,
            MutateFrame(rowID: d1.id, kind: .accept))

        // Seed d2: same lineage as d1, stays active.
        // Erasing d2 expunges the whole lineage; the gate refuses d1.
        var d2Frame = captureFrameForPartialErase(
            content: "active head to erase — its accepted sibling d1 will be refused")
        d2Frame.lineageID = d1.lineageID
        let d2 = try await kit.capture(handle, d2Frame, mode: .impatient)

        // Erase d2 through the production ARIA v2 dispatcher.
        let result = try await dispatcher.dispatch(
            name: "moot_erase_memory",
            arguments: .object([
                "memory_id": .string(d2.id.lowercased()),
                "confirmation": .bool(true),
            ]))

        // D1: partial erasure is a completed operation; isError must be false.
        #expect(result.objectValue?["isError"] == .bool(false),
                "partial erasure must not be an error (D1: completed with partial verdict); got: \(result)")

        let d = try requireData(result, operation: "moot_erase_memory")

        // Gate 1: outcome is "erased_partially", not "erased".
        // A handler that discards the refused-sibling list from the expunge
        // outcome would return "erased" here and fail this assertion.
        #expect(d["outcome"] == .string("erased_partially"),
                "partial expunge must report outcome erased_partially; got data: \(d)")

        // Gate 2: refused sibling ID is listed and lowercase (D8).
        let refused = try #require(
            d["refused_sibling_memory_ids"]?.arrayValue,
            "refused_sibling_memory_ids must be an array; got data: \(d)")
        #expect(!refused.isEmpty,
                "refused_sibling_memory_ids must be non-empty for a partial expunge; got: \(d)")
        let refusedStr = try #require(
            refused.first?.stringValue,
            "first refused sibling id must be a string; got: \(refused)")
        #expect(refusedStr == refusedStr.lowercased(),
                "refused sibling ID must be lowercase per D8 ruling; got: \(refusedStr)")

        // Gate 3: compact text must NOT say "Erased memory" unqualified.
        // The text lives in content[0].text per AriaV2Envelope.success (the
        // structuredContent envelope carries data, not the compact text).
        // A partial erasure is a partial verdict; the word "Partially" must appear.
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(!text.hasPrefix("Erased memory"),
                "partial erasure text must not say 'Erased memory' unqualified; got text: \(text)")
        #expect(text.contains("Partially"),
                "partial erasure text must say 'Partially'; got text: \(text)")
    }
}
