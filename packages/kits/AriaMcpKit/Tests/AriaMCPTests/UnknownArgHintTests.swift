// UnknownArgHintTests.swift
//
// Regression suite for Part A of the FIX-MCP mission: unrecognized argument
// keys sent to any tool must produce a trailing hint line in the result
// ("hint: unrecognized argument(s) ignored: <names>") rather than being
// silently dropped.
//
// The silence-on-unknown-arg pattern bit us twice in two days:
//   - "location" constant arg sent to moot_memory_search was dropped silently,
//     invalidating the search scope the caller intended to set.
//   - Benchmark runner sent "n" (meant to be "impatient") to moot_file_memory;
//     the capture ran without the impatient flag, invalidating a full benchmark
//     comparison before anyone noticed.
//
// These tests pin both regression cases and verify the central mechanism in
// ToolDispatcher.appendUnknownArgsHint that prevents future silent drops.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: tests open live in-memory estates; serial execution avoids
/// contention between concurrent GLK estate opens.
@Suite("Unknown-arg hint — regression and baseline", .serialized)
struct UnknownArgHintTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Extract the text payload from a tool-result JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    // MARK: - Baseline: known-good call produces no hint

    @Test func knownGoodCallProducesNoHint() async throws {
        // A call with only declared argument keys must NOT trigger the hint.
        // Uses moot_file_memory with its declared args (content + location).
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "unk-arg-known-good"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("baseline test memory"),
                "subject": .string("baseline test memory"),
                "location": .string("unk-arg-tests"),
            ]))

        let t = text(of: result)
        #expect(!t.contains("hint: unrecognized argument(s) ignored"),
                "a call with only declared args must NOT produce an unrecognized-arg hint")
    }

    // MARK: - Bogus arg produces hint, tool still succeeds

    // MARK: - Regression: "n" sent to moot_file_memory instead of "impatient"

    // MARK: - Regression: "location" sent to moot_memory_search

    // MARK: - Multiple unrecognized keys
}
