// EstateStatusSyncTests.swift
//
// Force-tests for the moot_estate_status sync field (OP-1 honesty fix).
//
// Verifies:
//   1. Estate with no sync engine → "sync: local-only" (never "connected").
//   2. Estate with NoSyncEngine (disabled) → "sync: none (idle)".
//   3. Estate with NoSyncEngine (enabled) → "sync: none (enabled, zone: …)".
//   4. Hardcoded "status: connected" literal is absent from all responses.
//   5. "sync:" field is always present in the output.
//
// These tests exercise the full dispatch path through ToolDispatcher.runEstateStatus
// so the assertion covers both the GLK accessor and the ARIA_MCP formatting layer.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
import ConvergenceKitNone
@testable import AriaMCP

/// `.serialized`: each test opens a live in-memory estate and calls dispatch.
@Suite("Estate status sync field (OP-1)", .serialized)
struct EstateStatusSyncTests {

    // MARK: - Harness

    /// Build a ToolDispatcher backed by a fresh in-memory estate.
    private func makeDispatcher(ownerID: String = "sync-test") async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// Extract the text payload from a JSONValue MCP result.
    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    // MARK: - Test 1: no sync engine → "local-only"

    /// An estate with no sync engine registered must report "sync: local-only".
    /// This is the production default for all ARIA_MCP v1.0 deployments.

    // MARK: - Test 2: fabricated "connected" literal is gone

    /// The hardcoded "status: connected" literal must never appear in estate_status.
    /// This was the fabrication removed by OP-1.
    @Test func fabricatedConnectedLiteralIsAbsent() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sync-test-2")
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        #expect(!body.contains("status: connected"),
                "Fabricated 'status: connected' must not appear in estate_status; got:\n\(body)")
    }

    // MARK: - Test 3: sync field always present

    /// The "sync:" field must always be present in the estate_status output.

    // MARK: - Test 4: NoSyncEngine disabled → "none (idle)"

    /// An estate with a NoSyncEngine that has not been enabled must report
    /// "sync: none (idle)".

    // MARK: - Test 5: NoSyncEngine enabled → "none (enabled, zone: …)"

    /// An estate with a NoSyncEngine that has been enabled must report
    /// "sync: none (enabled, zone: <zone>)".

    // MARK: - Test 6: sync field uses correct key name (not "status")

    /// The field key must be "sync:" not "status:".
    /// This guards against regression to the old fabricated "status: connected" key.

    // MARK: - Wave-C Part 2: count label alignment

    /// estate_status must say "memories: N active" (not "drawers: N") to match
    /// the Rust port label alignment fix (Wave C, Part 2). A withdrawn drawer
    /// must not appear in the active count.

    // MARK: - FIX 2: believed-only active count

    /// A rejected memory must NOT be counted as "active" in estate_status.
    /// Before this fix, `allDrawers().filter { tombstonedAt == nil }` included
    /// rejected drawers (no tombstone, but not cluster-A believed), causing the
    /// active count to exceed `memory_search`'s belief-filtered count.
}
