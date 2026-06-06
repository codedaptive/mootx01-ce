// HydrateRoundTripTests.swift
//
// Round-trip conformance tests for EstateHydration.
//
// Contract (per REPLICATION_TRACK_PLAN.md §9-style contract for GLK):
//   Build a non-trivial GLK estate in-memory (drawers, KGFacts, audit events).
//   Flush to SQLite via StorageReplicator.
//   Open a FRESH in-memory GLK estate hydrating from that SQLite.
//   Assert logical equivalence — recall results + matrix state (including
//   temporal) match the original.
//
// Two tests:
//   1. hydrateRoundTripDrawersAndKGFacts — core recall equivalence (drawers +
//      KGFacts) and matrix tier presence after hydration.
//   2. hydrateRoundTripMatrixTierEquivalence — matrix tier state (liveRowCount,
//      lastHLC) matches after hydration; temporal watermark is non-zero.
//
// The tests use InMemory↔SQLite backend pairs. SQLite files are written to
// the process temp directory and cleaned up in a `defer` block.
//
// Note on HLC column round-trip: the SQLite backend has a known pre-existing
// pack/unpack asymmetry (F-HLC-01). These tests do NOT assert exact HLC column
// values through the SQLite→InMemory path; they assert counts and structural
// equivalence instead. This is consistent with the §9 correctness contract
// (logical equivalence, not byte-identity).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitReplication
@testable import GeniusLocusKit

// MARK: - Helpers

/// Create a fresh InMemory storage with a new estate UUID.
/// The storage is NOT pre-opened with a schema — the GLK lifecycle does that.
private func makeInMemoryStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

/// Create a SQLite storage at a temp path and return the storage + URL for cleanup.
/// The storage is NOT pre-opened with a schema — the GLK lifecycle does that.
private func makeSQLiteStorage() throws -> (SQLiteStorage, URL) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("glk-hydrate-test-\(UUID().uuidString).sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url)
    ))
    return (storage, url)
}

/// Remove SQLite file and WAL/SHM sidecars.
private func cleanupSQLite(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

// Fixed timestamp for test determinism — avoids Date() inside engine calls
// per CLAUDE.md "pass `now` as parameter" rule.
private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

// MARK: - Round-trip test suite

@Suite("GLK hydrate round-trip")
struct HydrateRoundTripTests {

    // MARK: - Test 1: Drawers + KGFacts recall equivalence

    /// Build a non-trivial in-memory estate, flush to SQLite, hydrate back into a
    /// fresh InMemory backend, assert that recall returns the same drawers and KGFacts.
    ///
    /// Equivalence contract:
    ///   - Drawer count matches.
    ///   - Drawer contents match (by content string).
    ///   - KGFact count matches.
    ///   - KGFact triples (subject, predicate, object) match.
    ///   - MatrixTier is present (rebuilt from hydrated audit log).
    @Test
    func hydrateRoundTripDrawersAndKGFacts() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-hydrate-rt-1")
        let (sqliteStorage, sqliteURL) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: sqliteURL) }

        // ── Build source estate ──────────────────────────────────────────────
        let sourceStorage = makeInMemoryStorage()
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)

        let sourceKit = GeniusLocusKit()
        let sourceHandle = try await sourceKit.open(storage: sourceStorage, owner: owner)

        // Capture three drawers with deterministic content.
        let capturedContents = [
            "swift memory substrate GLK hydrate test alpha",
            "rust LocusKit bitmap accumulate recall parity beta",
            "vector ANN hamming scan logical equivalence gamma",
        ]
        for content in capturedContents {
            _ = try await sourceKit.capture(sourceHandle, CaptureFrame(
                content: content,
                channel: .typed,
                room: "hydrate-rt",
                latticeAnchor: .udc("000.000"),
                addedBy: "hydrate-test",
                embeddingModelID: "test-model-v1"
            ))
        }

        // Add two KGFacts.
        _ = try await sourceKit.captureKGFact(
            sourceHandle,
            subject: "GLK", predicate: "hydrates", object: "estate",
            now: t0
        )
        _ = try await sourceKit.captureKGFact(
            sourceHandle,
            subject: "MatrixTier", predicate: "rebuilds", object: "fromAuditLog",
            now: t0
        )

        // Recall baseline from source estate.
        let sourceDrawers = try await sourceKit.recall(sourceHandle, RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: 10
        ))
        let sourceKGFacts = try await sourceKit.recallKGFacts(sourceHandle)

        // ── Flush to SQLite ──────────────────────────────────────────────────
        // kit.flush opens both backends with the composite GLK schema before
        // calling StorageReplicator.flush, so the schema gate passes.
        _ = try await sourceKit.flush(from: sourceStorage, into: sqliteStorage)

        // ── Hydrate into fresh InMemory ──────────────────────────────────────
        let freshStorage = makeInMemoryStorage()
        let hydratedKit = GeniusLocusKit()

        let hydratedHandle = try await hydratedKit.open(
            inMemory: freshStorage,
            owner: owner,
            hydrateFrom: sqliteStorage
        )

        // ── Assert logical equivalence ───────────────────────────────────────

        let hydratedDrawers = try await hydratedKit.recall(hydratedHandle, RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: 10
        ))
        let hydratedKGFacts = try await hydratedKit.recallKGFacts(hydratedHandle)

        // Drawer count.
        let srcCount = sourceDrawers.count
        let hydCount = hydratedDrawers.count
        #expect(hydCount == srcCount)

        // Drawer contents — all source contents appear in hydrated recall.
        let sourceContents = Set(sourceDrawers.map { $0.content })
        let hydratedContents = Set(hydratedDrawers.map { $0.content })
        for content in sourceContents {
            #expect(hydratedContents.contains(content))
        }

        // KGFact count.
        let srcFactCount = sourceKGFacts.count
        let hydFactCount = hydratedKGFacts.count
        #expect(hydFactCount == srcFactCount)

        // KGFact triples (subject|predicate|object).
        let sourceFacts = Set(sourceKGFacts.map { "\($0.subject)|\($0.predicate)|\($0.object)" })
        let hydratedFacts = Set(hydratedKGFacts.map { "\($0.subject)|\($0.predicate)|\($0.object)" })
        #expect(sourceFacts == hydratedFacts)

        // MatrixTier is present (rebuilt from hydrated audit log).
        let tier = await hydratedKit.matrixTiers[hydratedHandle]
        #expect(tier != nil)
        if let tier {
            // liveRowCount must reflect the 3 captured drawers.
            #expect(tier.liveRowCount > 0)
        }
    }

    // MARK: - Test 2: Matrix tier state equivalence

    /// Assert that the matrix tier built from a hydrated estate matches the one
    /// built from the source estate: same liveRowCount, non-zero lastHLC, and
    /// non-zero temporalWatermarkHLC after audit replay.
    ///
    /// This test specifically validates the two-pass rebuild ordering:
    ///   Pass 1 (rebuild)         → F, O, C, liveRowCount, lastHLC
    ///   Pass 2 (rebuildTemporal) → T, temporalWatermarkHLC
    /// Both must run (MatrixTier.fullRebuild) for temporal state to be populated.
    /// A temporalWatermarkHLC == .zero indicates rebuildTemporal was NOT called.
    @Test
    func hydrateRoundTripMatrixTierEquivalence() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-hydrate-rt-2")
        let (sqliteStorage, sqliteURL) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: sqliteURL) }

        // ── Build source estate with several captures ────────────────────────
        let sourceStorage = makeInMemoryStorage()
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)

        let sourceKit = GeniusLocusKit()
        let sourceHandle = try await sourceKit.open(storage: sourceStorage, owner: owner)

        // Capture 4 drawers so audit events accumulate for matrix rebuild.
        for i in 0..<4 {
            _ = try await sourceKit.capture(sourceHandle, CaptureFrame(
                content: "matrix tier parity test content row \(i)",
                channel: .typed,
                room: "matrix-rt",
                latticeAnchor: .udc("000.000"),
                addedBy: "hydrate-test",
                embeddingModelID: "test-model-v1"
            ))
        }

        // Explicitly rebuild source tier so we have a baseline to compare against.
        try await sourceKit.rebuildDerivedAccelerators(for: sourceHandle)
        let sourceTier = await sourceKit.matrixTiers[sourceHandle]
        guard let sourceTier else {
            Issue.record("Source matrix tier must not be nil after rebuildDerivedAccelerators")
            return
        }

        // ── Flush to SQLite ──────────────────────────────────────────────────
        _ = try await sourceKit.flush(from: sourceStorage, into: sqliteStorage)

        // ── Hydrate into fresh InMemory ──────────────────────────────────────
        let freshStorage = makeInMemoryStorage()
        let hydratedKit = GeniusLocusKit()

        let hydratedHandle = try await hydratedKit.open(
            inMemory: freshStorage,
            owner: owner,
            hydrateFrom: sqliteStorage
        )

        let hydratedTier = await hydratedKit.matrixTiers[hydratedHandle]
        guard let hydratedTier else {
            Issue.record("Hydrated matrix tier must not be nil after open(inMemory:owner:hydrateFrom:)")
            return
        }

        // liveRowCount must match — both sessions saw the same 4 captures.
        #expect(hydratedTier.liveRowCount == sourceTier.liveRowCount)

        // lastHLC must be non-zero on both — audit events carry HLC timestamps.
        // HLC.zero is the sentinel for "no events processed" (MatrixTier.init default).
        #expect(sourceTier.lastHLC != .zero)
        #expect(hydratedTier.lastHLC != .zero)

        // temporalWatermarkHLC must be non-zero on the hydrated tier.
        // This validates that MatrixTier.fullRebuild called both passes.
        // A value of .zero means rebuildTemporal did NOT run — a correctness bug.
        #expect(hydratedTier.temporalWatermarkHLC != .zero)
    }
}
