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
        // v2 hint text (capital N) from AriaV2Coach.swift:91 — asserting the
        // case-sensitive form discriminates; the old lowercase check always passed
        // even when the hint fired. AriaV2Envelope.applyHint (AriaV2Envelope.swift:93)
        // appends "\nhint: " to content[0].text when a hint fires; its absence
        // also proves no hint was appended.
        #expect(
            !searchText.contains("No memories matched"),
            "No-results hint must not fire when search returned results; got: \(searchText)"
        )
        #expect(
            !searchText.contains("\nhint: "),
            "No hint token must appear in compact text when results are present; got: \(searchText)"
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
        // The no-results coaching hint IS in compact text, not only in structuredContent.
        // AriaV2Envelope.applyHint (AriaV2Envelope.swift:88-93) appends "\nhint: " + hint
        // to content[0].text. AriaV2Coach.hintForMemorySearch (AriaV2Coach.swift:89-93)
        // fires on zero results with: "No memories matched. File content with
        // moot_file_memory first, then search with a focused term."
        #expect(
            searchText.contains("No memories matched"),
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

    /// BLOCKED: AriaV2SelectedCatalog.swift:812-818 declares
    /// `required: ["memory_id", "wing", "room"]` for moot_move_memory —
    /// there is no room-only move path in v2. A caller that omits `wing`
    /// receives a decoder rejection before the operation runs.
    /// Awaiting a v2 spec decision: either add an optional-wing code path or
    /// remove the room-only-move contract from the spec.
    /// Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: AriaV2SelectedCatalog.swift:812-818 requires wing; no room-only move path exists in v2"))
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
            !recallText.contains("found 0 candidate memories"),
            "after room-only move, memory must still be in StableWing; got: \(recallText)"
        )
    }
}
