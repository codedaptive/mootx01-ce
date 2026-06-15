// RecallAbsentSignalTests.swift
//
// Tests that RecallCandidateBuffer.normalizeFinals distinguishes absent signals
// (all-zero column, no cache registered) from measured-uniform signals (non-zero
// uniform column, constant-score cache registered).
//
// Bug F3 addressed here: before the fix, normalizeFinals converted all-zero
// columns to 0.5, silently injecting positive evidence from unmeasured channels.
// After the fix, all-zero columns remain 0.0 so absent evidence contributes
// nothing to matrixAware scoring.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("RecallAbsentSignal — absent vs measured-uniform distinction")
struct RecallAbsentSignalTests {

    // Minimal estate factory: one drawer captured, no caches registered.
    private func openEstate(
        content: String = "absent signal test content"
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-absent-signal-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "absent-signal-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "absent-signal-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame)
        return (kit, handle)
    }

    // MARK: - Absent graph signal test

    /// When no GraphCache is registered, the graph column in the buffer remains
    /// all-zero (absent signal). normalizeFinals must NOT convert this to 0.5 —
    /// absent evidence must contribute nothing to matrixAware scoring.
    @Test("absent graph column stays 0.0 when no GraphCache is registered")
    func absentGraphColumnRemainsZeroWhenNoCacheRegistered() async throws {
        let (kit, handle) = try await openEstate()
        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        // With no GraphCache registered, every hit's graph score must be 0.0.
        // The absent-sentinel logic in normalizeFinals leaves all-zero columns
        // at 0.0 rather than normalising to 0.5.
        #expect(!result.hits.isEmpty, "unionBest must return hits when drawers are captured")
        let allGraphZero = result.hits.allSatisfy { $0.score.graph == 0.0 }
        #expect(allGraphZero, "graph score must be 0.0 when no GraphCache is registered (absent signal)")
        try await kit.close(handle)
    }

    // MARK: - Measured-uniform graph signal test

    /// When a constant GraphCache is registered (all candidates receive the same
    /// non-zero score), normalizeFinals must produce 0.5 — the measured-uniform
    /// sentinel indicating real signal with no relative ordering.
    @Test("measured-uniform graph column normalizes to 0.5")
    func measuredUniformGraphColumnNormalizesToHalf() async throws {
        let (kit, handle) = try await openEstate()
        // Capture a second drawer so normalizeFinals sees two candidates, both
        // with the same non-zero graph score from the constant cache.
        let frame2 = CaptureFrame(
            content: "second drawer measured uniform test",
            channel: .typed,
            room: "absent-signal-tests",
            latticeAnchor: .udc("001.001"),
            addedBy: "absent-signal-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame2)

        // Constant cache: every candidate gets graph score 0.7.
        struct ConstantGraphCache: GraphCache {
            let score: Float
            func graphScore(for drawerID: String) -> Float { score }
        }
        await kit.registerGraphCache(ConstantGraphCache(score: 0.7), for: handle)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        // All candidates have identical non-zero graph scores (0.7 from the
        // constant cache). normalizeFinals sets measured-uniform columns to 0.5.
        #expect(!result.hits.isEmpty, "unionBest must return hits when drawers are captured")
        let allGraphHalf = result.hits.allSatisfy { abs($0.score.graph - 0.5) < 1e-6 }
        #expect(allGraphHalf, "graph score must be 0.5 for measured-uniform signal (constant-score cache)")
        try await kit.close(handle)
    }
}
