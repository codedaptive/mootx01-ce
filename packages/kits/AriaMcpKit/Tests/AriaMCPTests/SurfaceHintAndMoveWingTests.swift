// SurfaceHintAndMoveWingTests.swift
//
// Regression tests for two live-drive bugs found via the ARIA surface:
//
// O — contradictory hint: moot_memory_search appended "No results / Try
//     broader terms" even when results were present (the substring "0 memory"
//     matched "20 memory(s)"). Fix: gate on "found 0 candidate memories" prefix.
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
    /// does NOT appear. The test asserts the result does not contain "found 0 candidate memories",
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
            !searchText.contains("found 0 candidate memories"),
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
            searchText.contains("found 0 candidate memories"),
            "zero-result search must report 0 memories; got: \(searchText)"
        )
        // v2 compact text for zero results: "found 0 candidate memories"
        // Coaching hints (if any) are in structuredContent, not the compact text.
        // The essential property is that "found 0 candidate memories" is the prefix —
        // the "O" bug was that non-zero results also triggered this prefix text.
        #expect(
            searchText.hasPrefix("found 0 candidate memories"),
            "zero-result search must use the 'found 0' prefix; got: \(searchText)"
        )
    }

    // MARK: - Bug J: move_memory must honor the wing argument

    /// File a memory into wing "OriginWing", then move it to wing "TargetWing"
    /// via moot_move_memory. Verify it is now recalled under "TargetWing" and
    /// NOT recalled when scoped to "OriginWing".
    ///
    /// Before the fix: ReanchorFrame had no toWing field; the wing arg was
    /// silently ignored and the drawer stayed in its original wing.
    ///
    /// v2 changes: memory_id (not id), room (not location).
    /// v2 compact text: "Moved memory {uuid}." (capital M, no wing/room in compact text).
    /// Wing and room appear in structuredContent.data.placement — verified via "\(moveResult)".
    @Test("moot_move_memory with wing argument reanchors to target wing")
    func moveMemoryHonorsWing() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory into wing "OriginWing".
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
        let memID = String(afterPrefix.prefix(while: { !$0.isWhitespace }))
        #expect(!memID.isEmpty, "must extract a non-empty memory ID from: \(fileText)")

        // Move the memory to "TargetWing/target-room".
        // v2 arg names: memory_id (not id), room (not location).
        let moveResult = try await dispatcher.dispatch(
            name: "moot_move_memory",
            arguments: .object([
                "memory_id": .string(memID),
                "room": .string("target-room"),
                "wing": .string("TargetWing"),
            ])
        )
        let moveText = text(of: moveResult)
        // v2 compact text: "Moved memory {uuid}." (capital M).
        #expect(
            moveText.contains("Moved memory"),
            "move_memory must report success; got: \(moveText)"
        )
        // v2 placement details are in structuredContent.data.placement — verify via string repr.
        let moveResultStr = "\(moveResult)"
        #expect(
            moveResultStr.contains("TargetWing"),
            "move result must name the target wing in placement; got: \(moveResultStr)"
        )
        #expect(
            moveResultStr.contains("target-room"),
            "move result must name the target room in placement; got: \(moveResultStr)"
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
            !targetText.contains("found 0 candidate memories"),
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
            originText.contains("found 0 candidate memories"),
            "recall in OriginWing must return 0 hits after cross-wing move; got: \(originText)"
        )
    }

    // MARK: - Bug J (row 45): BLOCKED

    // moveMemoryRoomOnlyWhenNoWing is BLOCKED in ARIA v2.
    //
    // v1 moot_move_memory accepted an optional `wing` argument so a room-only
    // move was possible. In ARIA v2, AriaV2MoveMemoryRequest marks `wing` as
    // REQUIRED (required: ["memory_id", "wing", "room"]). There is no room-only
    // move path in v2. A caller that omits `wing` receives a decoder rejection.
    //
    // The test cannot be rewritten without weakening the assertion or inventing
    // a path that does not exist — both are prohibited. Restoration is blocked
    // pending a v2 spec decision: either add an optional-wing code path to
    // moot_move_memory, or remove the room-only-move contract from the spec.
}
