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
}
