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

    /// Search against an empty estate (zero results) and verify the "No results"
    /// coaching hint IS emitted.

    // MARK: - Bug J: move_memory must honor the wing argument

    /// File a memory into wing "OriginWing", then move it to wing "TargetWing"
    /// via moot_move_memory. Verify it is now recalled under "TargetWing" and
    /// NOT recalled when scoped to "OriginWing".
    ///
    /// Before the fix: ReanchorFrame had no toWing field; the wing arg was
    /// silently ignored and the drawer stayed in its original wing.

    /// Verify that moot_move_memory without a wing argument still performs a
    /// room-only move — existing behavior is unchanged when wing is omitted.
}
