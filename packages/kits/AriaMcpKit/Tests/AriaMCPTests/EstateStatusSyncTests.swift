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
        let handle = try await kit.open(storage: storage, owner: owner)
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
    @Test func noSyncEngine_reportsLocalOnly() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sync-test-1")
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        #expect(body.contains("sync: local-only"),
                "Expected 'sync: local-only' in estate_status when no engine is registered; got:\n\(body)")
    }

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
    @Test func syncFieldAlwaysPresent() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sync-test-3")
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        #expect(body.contains("sync: "),
                "estate_status output must contain a 'sync:' field; got:\n\(body)")
    }

    // MARK: - Test 4: NoSyncEngine disabled → "none (idle)"

    /// An estate with a NoSyncEngine that has not been enabled must report
    /// "sync: none (idle)".
    @Test func noSyncEngineDisabled_reportsNoneIdle() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "sync-test-4")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Register a NoSyncEngine (disabled — never had enable() called).
        try await kit.registerSyncEngine(NoSyncEngine(), backendName: "none", for: handle)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        #expect(body.contains("sync: none (idle)"),
                "Expected 'sync: none (idle)' for disabled NoSyncEngine; got:\n\(body)")
    }

    // MARK: - Test 5: NoSyncEngine enabled → "none (enabled, zone: …)"

    /// An estate with a NoSyncEngine that has been enabled must report
    /// "sync: none (enabled, zone: <zone>)".
    @Test func noSyncEngineEnabled_reportsNoneEnabled() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "sync-test-5")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Build a NoSyncEngine and enable it with a test manifest.
        let engine = NoSyncEngine()
        let manifest = SyncManifest(
            kitID: "test-kit",
            schemaVersion: 1,
            zoneIdentifier: "test.zone.op1",
            tables: []
        )
        // PersistenceKitInMemory storage for the engine enable call.
        let engineStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        try await engine.enable(manifest: manifest, storage: engineStorage)

        // Register the enabled engine.
        try await kit.registerSyncEngine(engine, backendName: "none", for: handle)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        #expect(body.contains("sync: none (enabled, zone: test.zone.op1)"),
                "Expected 'sync: none (enabled, zone: test.zone.op1)' for enabled NoSyncEngine; got:\n\(body)")
    }

    // MARK: - Test 6: sync field uses correct key name (not "status")

    /// The field key must be "sync:" not "status:".
    /// This guards against regression to the old fabricated "status: connected" key.
    @Test func syncFieldUsesCorrectKey() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sync-test-6")
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        // Must have "sync:" key.
        #expect(body.contains("sync: "),
                "estate_status must use 'sync:' as the field key; got:\n\(body)")
        // Must NOT have the old "status:" key (which was the fabricated literal).
        let lines = body.components(separatedBy: "\n")
        let hasOldStatusLine = lines.contains { $0.hasPrefix("status:") }
        #expect(!hasOldStatusLine,
                "estate_status must not use the old 'status:' key; got:\n\(body)")
    }

    // MARK: - Wave-C Part 2: count label alignment

    /// estate_status must say "memories: N active" (not "drawers: N") to match
    /// the Rust port label alignment fix (Wave C, Part 2). A withdrawn drawer
    /// must not appear in the active count.
    @Test func statusCountLabel_memoriesActive() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "label-test")
        // File one memory so the count is 1.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("label test content"),
                "location": .string("label/room")
            ])
        )
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: result)
        // Must use "memories:" label (Wave C label alignment).
        #expect(body.contains("memories: "),
                "estate_status must use 'memories:' label; got:\n\(body)")
        // Must say "active" to distinguish from total.
        #expect(body.contains("active"),
                "estate_status label must include 'active'; got:\n\(body)")
        // The old "drawers:" label must not appear.
        #expect(!body.contains("drawers:"),
                "estate_status must not use deprecated 'drawers:' label; got:\n\(body)")
    }

    // MARK: - FIX 2: believed-only active count

    /// A rejected memory must NOT be counted as "active" in estate_status.
    /// Before this fix, `allDrawers().filter { tombstonedAt == nil }` included
    /// rejected drawers (no tombstone, but not cluster-A believed), causing the
    /// active count to exceed `memory_search`'s belief-filtered count.
    @Test func rejectedMemoryNotCountedAsActive() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "believed-count-test")

        // File a memory and immediately reject it (moves out of cluster A).
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("believed-count test fixture"),
                "location": .string("test/room")
            ])
        )
        let fileText = text(of: fileResult)
        // Extract drawer id from "filed memory <id>" prefix.
        let drawerID = fileText
            .components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
        #expect(!drawerID.isEmpty, "filed memory must return a drawer id; got:\n\(fileText)")

        // Move to Contested first (Active → Contested is legal).
        // Active → Reject is NOT legal per the gate automaton; contest must come first.
        let contestResult = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string(drawerID),
                "mutation": .string("contest")
            ])
        )
        let contestedIsSuccess = contestResult.objectValue?["isError"]?.boolValue == false
        #expect(contestedIsSuccess, "contest must succeed on active row; got: \(contestResult)")

        // Reject the memory (Contested → Rejected is legal) — moves it out of cluster A into cluster C.
        let rejectResult = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string(drawerID),
                "mutation": .string("reject")
            ])
        )
        let rejectedIsSuccess = rejectResult.objectValue?["isError"]?.boolValue == false
        #expect(rejectedIsSuccess, "reject must succeed on contested row; got: \(rejectResult)")

        // estate_status active count must be 0 (rejected drawer is not believed).
        let statusResult = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let body = text(of: statusResult)
        // "memories: 0 active" — the rejected drawer must NOT be in the active count.
        #expect(body.contains("memories: 0 active"),
                "Rejected drawer must not count as active; got:\n\(body)")
        // The total count must still be 1 (the row exists, just not believed).
        #expect(body.contains("(1 total)"),
                "Total non-erased count must be 1; got:\n\(body)")
    }
}
