import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// P0-4: the `scoring` argument on moot_memory_search must fail CLOSED on an
/// unknown non-empty value (was: silently coerced to matrixAware).
///
/// Before the fix, `GLKRecallScoring(rawValue: scoringStr) ?? .matrixAware`
/// silently ran the matrix-aware pipeline for ANY unrecognized string,
/// including a client typo — running a different scoring mode than asked and
/// hiding the mistake. The fix mirrors the strict `ordering` decode: absent
/// keeps the documented default (matrixAware); an unknown non-empty string
/// throws invalidParams. Kept in lockstep with the Rust run_memory_search.
///
/// ## What these tests prove
///   A. Unknown scoring throws invalidParams (fail-closed).
///   B. A known scoring value (raw) still succeeds; rrf and matrixAware are not separately covered.
///   C. Absent scoring keeps the documented default and succeeds.
@Suite("Scoring dispatch (P0-4 fail-closed)", .serialized)
struct ScoringDispatchTests {

    /// Build a ToolDispatcher wired to a fresh in-memory estate.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scoring-dispatch-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

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
        return text.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
    }

    // MARK: - A. Unknown scoring fails closed

    /// FORCE-TEST: an unknown non-empty scoring value must throw invalidParams,
    /// not silently run matrixAware.
    @Test func unknownScoringThrowsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "scoring": .string("magicScore"),
                ])
            )
            Issue.record("Unknown scoring must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Unknown scoring must throw invalidParams; got code \(error.code)"
            )
        }
    }

    @Test func nullScoringThrowsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "scoring": .null,
                ])
            )
            Issue.record("scoring:null must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    @Test func nullFilterThrowsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "filter": .null,
                ])
            )
            Issue.record("filter:null must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    // MARK: - B. Known scoring still succeeds

    @Test func knownScoringRawSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "scoring-raw-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("scoring-raw-test"),
                "scoring": .string("raw"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "scoring=raw must succeed")
    }

    // MARK: - C. Absent scoring defaults

    /// Omitting `scoring` keeps the documented default (matrixAware) and must
    /// succeed — only an unknown NON-EMPTY string errors.
    @Test func absentScoringDefaultsAndSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "absent-scoring-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("absent-scoring-test")])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "absent scoring must default to matrixAware and succeed")
    }

    @Test func omittedFilterFindsFreshUnconfirmedMemory() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "omitted-filter-unconfirmed-test", location: "test", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("omitted-filter-unconfirmed-test")])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(text.contains("found 1 memory(s)"), "omitted filter must find fresh captures; got: \(text)")
    }
}
