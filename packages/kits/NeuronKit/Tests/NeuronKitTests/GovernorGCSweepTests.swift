// GovernorGCSweepTests.swift
//
// Tests for Mission #54 Part C: AutonomicGovernor GC sweep cadence.
//
// The GC sweep is a governor duty that fires every 30 s (default) to reclaim
// stale "cur" rows left by crashed drainers that the on-mount reclaim in
// CorpusKit and DreamCommand didn't catch. These tests verify the cadence
// semantics via GovernorReport.gcSweepFired without exercising the actual
// SQLite reclaim (covered by the QueueKit and CorpusKit tests).
//
// Success criteria (Mission #54, Part C):
//   1. First tick always fires the sweep (lastGCSweepFired is nil at startup).
//   2. Second tick does NOT fire when the interval hasn't elapsed (large interval).
//   3. Second tick fires when gcSweepIntervalMs = 0 (every-tick test knob).
//
// Uses an in-memory GeniusLocusKit estate — no SQLite I/O, no real sweep
// side effect, just the cadence gate in tick().

import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

@Suite("AutonomicGovernor GC sweep cadence (Mission #54 Part C)", .serialized)
struct GovernorGCSweepTests {

    // MARK: - Infrastructure

    private func makeGovernor(gcSweepIntervalMs: Int) async throws -> AutonomicGovernor {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "governor-gc-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Use gcSweepIntervalMs knob; suppress heavy duties by setting very large
        // cadences — this test only cares about gcSweepFired.
        return AutonomicGovernor(
            kit: kit,
            handle: handle,
            baseTickMs: 0,
            graphAnalyticsIntervalMs: Int.max,
            graphCentralityIntervalMs: Int.max,
            preferenceIntervalMs: Int.max,
            topologyCadenceMs: Int.max,
            poolReduceCadenceMs: Int.max,
            topologyHandler: nil,
            topologyFingerprintLoader: nil,
            topologyGate: nil,
            graphAnalyticsHandler: nil,
            poolDirectory: nil,          // suppress pool reduce
            poolTableArtifactURL: nil,
            gcSweepIntervalMs: gcSweepIntervalMs
        )
    }

    // MARK: 1. First tick always fires the GC sweep

    @Test("first tick fires GC sweep (lastGCSweepFired nil at startup)")
    func firstTickAlwaysFiresGCSweep() async throws {
        // With a large interval the sweep would never fire after the first tick —
        // but the first tick must fire regardless (catch orphaned cur rows at startup).
        let gov = try await makeGovernor(gcSweepIntervalMs: 99_999_999)
        let t0 = Date()
        let report = await gov.tick(now: t0)
        #expect(report.gcSweepFired == true,
            "first tick must always fire the GC sweep regardless of interval")
    }

    // MARK: 2. Second tick does NOT fire when interval has not elapsed

    @Test("second tick does not fire GC sweep before interval elapses")
    func secondTickDoesNotFireBeforeInterval() async throws {
        // 99-second interval; ticks 0.1 ms apart — sweep must not fire on second tick.
        let gov = try await makeGovernor(gcSweepIntervalMs: 99_000)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(0.0001)   // 0.1 ms after t0

        _ = await gov.tick(now: t0)   // first tick fires the sweep
        let report2 = await gov.tick(now: t1)
        #expect(report2.gcSweepFired == false,
            "sweep must not fire on second tick when interval has not elapsed")
    }

    // MARK: 3. gcSweepIntervalMs = 0 fires every tick

    @Test("gcSweepIntervalMs = 0 causes sweep to fire on every tick")
    func zeroIntervalFiresEveryTick() async throws {
        // The zero-interval knob is used in tests to trigger the sweep every pass
        // without waiting for the 30 s production cadence.
        let gov = try await makeGovernor(gcSweepIntervalMs: 0)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(0.0001)

        let report1 = await gov.tick(now: t0)
        let report2 = await gov.tick(now: t1)
        #expect(report1.gcSweepFired == true, "first tick must fire when interval = 0")
        #expect(report2.gcSweepFired == true, "second tick must fire when interval = 0")
    }
}
