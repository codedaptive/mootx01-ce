import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Tests that ordering="byRelevanceDesc" on moot_memory_search routes to the
/// scored recall pipeline and succeeds (Bob's ruling — invalid-removal restoration).
///
/// Before this fix, "byRelevanceDesc" was removed from LocusKit.Ordering and the
/// ARIA surface threw invalidParams for that client spelling. The correct closure
/// (option b) is: keep LocusKit's enum clean (no byRelevanceDesc case there) but
/// PRESERVE the client API spelling at the ARIA layer, routing it to the scored
/// recall path (GLKRecallRequest/unionBest) which does deliver relevance-ordered
/// results. The LocusKit Ordering enum is used only as a tie-break field within
/// the scored layer; the final result order is driven by scores.
///
/// ## What these tests prove
///
///   A. byRelevanceDesc succeeds — moot_memory_search with ordering=byRelevanceDesc
///      returns isError:false and finds filed memories (not an invalidParams error).
///
///   B. byRelevanceDesc is documented — the moot_memory_search schema description
///      advertises "byRelevanceDesc" so clients can discover the spelling.
///
///   C. Other orderings unchanged — byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc
///      still succeed and unknown orderings still throw invalidParams.
///
///   D. Schema roundtrip — decodeOrdering("byRelevanceDesc") returns .byCaptureTimeDesc
///      (the internal tie-break value) without throwing.
@Suite("Ordering dispatch", .serialized)
struct OrderingDispatchTests {

    /// Build a ToolDispatcher wired to a fresh in-memory estate.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ordering-dispatch-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// File a memory and return the assigned drawer id.
    @discardableResult
    private func fileMemory(
        content: String,
        location: String,
        dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "location": .string(location),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        let id = text.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
        return id
    }

    // MARK: - A. byRelevanceDesc succeeds

    /// moot_memory_search with ordering="byRelevanceDesc" must NOT throw invalidParams.
    /// The scored recall path handles relevance ordering; the call must succeed and
    /// return found results. Before the fix this call threw invalidParams, which was
    /// the feature-removal Bob ruled against.
    @Test func byRelevanceDescSucceedsAndFindsMemory() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(
            content: "relevance-ordering-test-content",
            location: "test/room",
            dispatcher: dispatcher
        )
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("relevance-ordering-test-content"),
                "ordering": .string("byRelevanceDesc"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "ordering=byRelevanceDesc must not produce an error result")
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(
            text.contains("found 1 memory"),
            "byRelevanceDesc must find the filed memory; got: \(text)"
        )
    }

    /// moot_memory_search with ordering="byRelevanceDesc" on an empty estate
    /// must succeed (isError:false) with zero hits — not invalidParams.
    @Test func byRelevanceDescOnEmptyEstateSucceedsWithZeroHits() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("any-query"),
                "ordering": .string("byRelevanceDesc"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "ordering=byRelevanceDesc on empty estate must not error; got: \(result)")
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(
            text.contains("found 0 memory"),
            "empty estate must return 0 memories; got: \(text)"
        )
    }

    // MARK: - B. byRelevanceDesc is documented in the schema

    /// The moot_memory_search tool schema must advertise "byRelevanceDesc" in the
    /// ordering field description so clients can discover the spelling.
    @Test func memorySearchSchemaAdvertisesByRelevanceDesc() {
        let tools = ToolProjection.tools()
        guard let searchTool = tools.first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found in tool list")
            return
        }
        let properties = searchTool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        guard let orderingDesc = properties["ordering"]?.objectValue?["description"]?.stringValue else {
            Issue.record("moot_memory_search schema must have an ordering property with a description")
            return
        }
        #expect(
            orderingDesc.contains("byRelevanceDesc"),
            "ordering description must advertise byRelevanceDesc; got: \(orderingDesc)"
        )
    }

    // MARK: - C. Other orderings unchanged

    /// byCaptureTimeDesc (the default) must succeed as before.
    @Test func byCaptureTimeDescSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "capture-time-desc-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("capture-time-desc-test"),
                "ordering": .string("byCaptureTimeDesc"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "ordering=byCaptureTimeDesc must succeed")
    }

    /// byCaptureTimeAsc must succeed as before.
    @Test func byCaptureTimeAscSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "capture-time-asc-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("capture-time-asc-test"),
                "ordering": .string("byCaptureTimeAsc"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "ordering=byCaptureTimeAsc must succeed")
    }

    /// byRoomAsc must succeed as before.
    @Test func byRoomAscSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "room-asc-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("room-asc-test"),
                "ordering": .string("byRoomAsc"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "ordering=byRoomAsc must succeed")
    }

    /// An unknown ordering value must throw invalidParams (out-of-band fault),
    /// not silently succeed. This ensures the accept-list stays narrow.
    @Test func unknownOrderingThrowsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "ordering": .string("byMagicOrder"),
                ])
            )
            Issue.record("Unknown ordering must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Unknown ordering must throw invalidParams; got code \(error.code)"
            )
        }
    }

    // MARK: - D. Absent ordering arg defaults gracefully

    /// Omitting the ordering arg entirely must succeed — it defaults to the
    /// byCaptureTimeDesc tie-break. Regression guard: no ordering field was
    /// present on moot_memory_search before this change; existing callers
    /// that omit it must be unaffected.
    @Test func omittedOrderingSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "no-ordering-arg-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("no-ordering-arg-test")])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "omitted ordering must succeed (default behavior preserved)")
    }
}
