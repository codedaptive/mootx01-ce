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
                "location": .string("unk-arg-tests"),
            ]))

        let t = text(of: result)
        #expect(!t.contains("hint: unrecognized argument(s) ignored"),
                "a call with only declared args must NOT produce an unrecognized-arg hint")
    }

    // MARK: - Bogus arg produces hint, tool still succeeds

    @Test func bogusArgProducesHintAndToolSucceeds() async throws {
        // A call with an unrecognized key ("totally_fake_arg") must:
        //   1. Still return isError: false (tool succeeds).
        //   2. Append the hint line naming the bogus key.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "unk-arg-bogus"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("bogus arg test memory"),
                "location": .string("unk-arg-tests"),
                "totally_fake_arg": .string("should be flagged"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "unrecognized arg must NOT cause the tool call to fail")
        let t = text(of: result)
        #expect(t.contains("hint: unrecognized argument(s) ignored: totally_fake_arg"),
                "result must contain the hint line naming the unrecognized key")
    }

    // MARK: - Regression: "n" sent to moot_file_memory instead of "impatient"

    @Test func regression_nArgToFileMemoryShouldHint() async throws {
        // The benchmark runner sent "n" (short for the moot_file_memory "impatient"
        // flag) for an entire benchmark run. The arg was silently dropped, so captures
        // ran with the wrong flag and the comparison results were invalid. This test
        // pins the correct behavior: "n" triggers the hint so the caller knows.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "unk-arg-n-regression"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("impatient regression test"),
                "location": .string("unk-arg-tests"),
                "n": .bool(true),   // wrong key — should have been "impatient"
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "wrong key must NOT cause the call to fail — loose clients must keep working")
        let t = text(of: result)
        #expect(t.contains("hint: unrecognized argument(s) ignored: n"),
                "result must hint that 'n' is not a recognized arg (caller meant 'impatient')")
    }

    // MARK: - Regression: "location" sent to moot_memory_search

    @Test func regression_locationArgToMemorySearchShouldHint() async throws {
        // A constant "location" arg was sent to moot_memory_search intending to
        // restrict the search scope. The arg was silently dropped — the search ran
        // across the whole estate, not the intended scope, and the caller never knew.
        // This test pins that "location" triggers the hint for moot_memory_search.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "unk-arg-location-regression"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("regression test query"),
                "location": .string("unk-arg-tests"),  // not a declared arg on moot_memory_search
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "wrong key must NOT cause the call to fail — loose clients must keep working")
        let t = text(of: result)
        #expect(t.contains("hint: unrecognized argument(s) ignored: location"),
                "result must hint that 'location' is not a recognized arg on moot_memory_search")
    }

    // MARK: - Multiple unrecognized keys

    @Test func multipleUnrecognizedKeysAreSortedInHint() async throws {
        // When more than one unrecognized key is present, all names appear
        // in the hint — sorted alphabetically — comma-joined.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "unk-arg-multi"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("multi-unrecognized-arg test"),
                "location": .string("unk-arg-tests"),
                "zzz_last": .string("z"),
                "aaa_first": .string("a"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let t = text(of: result)
        #expect(t.contains("hint: unrecognized argument(s) ignored: aaa_first, zzz_last"),
                "multiple unrecognized keys must be listed sorted alphabetically in the hint")
    }
}
