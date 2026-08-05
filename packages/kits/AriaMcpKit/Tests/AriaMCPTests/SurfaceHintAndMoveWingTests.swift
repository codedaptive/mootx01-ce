// SurfaceHintAndMoveWingTests.swift
//
// Regression tests for two live-drive bugs found via the ARIA surface:
//
// O — contradictory hint: moot_memory_search appended "No results / Try
//     broader terms" even when results were present (the substring "0 memory"
//     matched "20 memory(s)"). Fix: gate on "found 0 memory" prefix.
//
// J — move_memory ignores wing: moot_move_memory accepted a `wing` argument
//     but silently dropped it, leaving the drawer in its original wing.
//     Fix: thread `wing` through ReanchorFrame → Estate.reanchor →
//     DrawerStore.reanchorGated (writes the `wing` column).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Surface hint and move-wing fixes", .serialized)
struct SurfaceHintAndMoveWingTests {

    // MARK: - Harness

    /// Open a fresh in-memory estate and return a ToolDispatcher backed by it.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "surface-hint-move-wing-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// Extract the text content block from a tool result.
    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    // MARK: - Bug O: coaching hint fires only on zero results

    /// File a memory, search for it, then verify the "No results" coaching hint
    /// does NOT appear. The test asserts the result does not contain "found 0 memory",
    /// confirming the hint fires only on genuine zero results, not on counts that
    /// happen to contain "0" as a substring.
    @Test("moot_memory_search with results does not emit No-results hint")
    func searchWithResultsHasNoEmptyHint() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory so the search can return at least one hit.
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("surface-hint-test unique content alpha bravo charlie"),
                "subject": .string("surface-hint-test unique content alpha bravo charlie"),
                "location": .string("test/wing-hint-check"),
            ])
        )
        let fileText = text(of: fileResult)
        #expect(fileText.contains("filed memory"), "file_memory must succeed before search")

        // Search for the filed memory.
        let searchResult = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("surface-hint-test unique content alpha"),
            ])
        )
        let searchText = text(of: searchResult)

        // The result must show at least one hit.
        #expect(
            !searchText.contains("found 0 memory"),
            "search must return at least one hit; got: \(searchText)"
        )
        // The no-results hint must NOT be present because results were returned.
        // Hint text matches Rust coaching_engine.rs trigger 2.
        #expect(
            !searchText.contains("no memories matched"),
            "No-results hint must not fire when search returned results; got: \(searchText)"
        )
        #expect(
            !searchText.contains("broaden the query"),
            "Broaden-query hint must not fire when search returned results; got: \(searchText)"
        )
    }

    /// Search against an empty estate (zero results) and verify the "No results"
    /// coaching hint IS emitted.
    @Test("moot_memory_search with zero results emits No-results hint")
    func searchWithZeroResultsHasHint() async throws {
        let dispatcher = try await makeDispatcher()

        // No memories filed — estate is empty.
        let searchResult = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("xyzzy-unique-nonexistent-term-abcdef"),
            ])
        )
        let searchText = text(of: searchResult)

        // Must report zero hits.
        #expect(
            searchText.contains("found 0 memory"),
            "zero-result search must report 0 memories; got: \(searchText)"
        )
        // The coaching hint must fire on genuine zero results.
        // Hint text matches Rust coaching_engine.rs trigger 2.
        #expect(
            searchText.contains("no memories matched") || searchText.contains("broaden the query"),
            "No-results coaching hint must fire when search returned 0 hits; got: \(searchText)"
        )
    }

    // MARK: - Bug J: move_memory must honor the wing argument

    /// File a memory into wing "OriginWing", then move it to wing "TargetWing"
    /// via moot_move_memory. Verify it is now recalled under "TargetWing" and
    /// NOT recalled when scoped to "OriginWing".
    ///
    /// Before the fix: ReanchorFrame had no toWing field; the wing arg was
    /// silently ignored and the drawer stayed in its original wing.
    @Test("moot_move_memory with wing argument reanchors to target wing")
    func moveMemoryHonorsWing() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory into wing "OriginWing" (explicitly passed; not using the default wing).
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("cross-wing move test payload unique zeta omega"),
                "subject": .string("cross-wing move test payload unique zeta omega"),
                "location": .string("origin-room"),
                "wing": .string("OriginWing"),
            ])
        )
        let fileText = text(of: fileResult)
        #expect(fileText.contains("filed memory"), "file_memory must succeed; got: \(fileText)")

        // Extract the drawer id from the file result.
        // filed memory format: "filed memory <uuid> in OriginWing/origin-room"
        let idPrefix = "filed memory "
        guard let idRange = fileText.range(of: idPrefix) else {
            Issue.record("Cannot find 'filed memory ' prefix in: \(fileText)")
            return
        }
        let afterPrefix = String(fileText[idRange.upperBound...])
        // ID is the first whitespace-delimited token after the prefix.
        let memID = String(afterPrefix.prefix(while: { !$0.isWhitespace }))
        #expect(!memID.isEmpty, "must extract a non-empty memory ID from: \(fileText)")

        // Move the memory to "TargetWing/target-room".
        let moveResult = try await dispatcher.dispatch(
            name: "moot_move_memory",
            arguments: .object([
                "id": .string(memID),
                "location": .string("target-room"),
                "wing": .string("TargetWing"),
            ])
        )
        let moveText = text(of: moveResult)
        #expect(
            moveText.contains("moved memory"),
            "move_memory must report success; got: \(moveText)"
        )
        // The success text must name both the wing and the room.
        #expect(
            moveText.contains("TargetWing"),
            "move result must name the target wing; got: \(moveText)"
        )
        #expect(
            moveText.contains("target-room"),
            "move result must name the target room; got: \(moveText)"
        )

        // Recall scoped to "TargetWing" must find the memory.
        let targetRecall = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("cross-wing move test payload"),
                "wing": .string("TargetWing"),
            ])
        )
        let targetText = text(of: targetRecall)
        #expect(
            !targetText.contains("found 0 memory"),
            "recall in TargetWing must find the moved memory; got: \(targetText)"
        )

        // Recall scoped to "OriginWing" must NOT find the memory (it was moved out).
        let originRecall = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("cross-wing move test payload"),
                "wing": .string("OriginWing"),
            ])
        )
        let originText = text(of: originRecall)
        #expect(
            originText.contains("found 0 memory"),
            "recall in OriginWing must return 0 hits after cross-wing move; got: \(originText)"
        )
    }

    /// Verify that moot_move_memory without a wing argument still performs a
    /// room-only move — existing behavior is unchanged when wing is omitted.
    @Test("moot_move_memory without wing argument performs room-only move")
    func moveMemoryRoomOnlyWhenNoWing() async throws {
        let dispatcher = try await makeDispatcher()

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("room-only move test payload unique lambda sigma"),
                "subject": .string("room-only move test payload unique lambda sigma"),
                "location": .string("old-room"),
                "wing": .string("StableWing"),
            ])
        )
        let fileText = text(of: fileResult)
        #expect(fileText.contains("filed memory"), "file_memory must succeed")

        let idPrefix = "filed memory "
        guard let idRange = fileText.range(of: idPrefix) else {
            Issue.record("Cannot find 'filed memory ' prefix in: \(fileText)")
            return
        }
        let afterPrefix = String(fileText[idRange.upperBound...])
        let memID = String(afterPrefix.prefix(while: { !$0.isWhitespace }))

        // Move room only — no wing argument.
        let moveResult = try await dispatcher.dispatch(
            name: "moot_move_memory",
            arguments: .object([
                "id": .string(memID),
                "location": .string("new-room"),
            ])
        )
        let moveText = text(of: moveResult)
        #expect(
            moveText.contains("moved memory"),
            "room-only move must succeed; got: \(moveText)"
        )
        // Result names only the room (wing path is not in the success text).
        #expect(
            moveText.contains("new-room"),
            "move result must name the new room; got: \(moveText)"
        )

        // Memory must still be findable in the original wing.
        let recall = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("room-only move test payload unique lambda"),
                "wing": .string("StableWing"),
            ])
        )
        let recallText = text(of: recall)
        #expect(
            !recallText.contains("found 0 memory"),
            "after room-only move, memory must still be in StableWing; got: \(recallText)"
        )
    }
}
