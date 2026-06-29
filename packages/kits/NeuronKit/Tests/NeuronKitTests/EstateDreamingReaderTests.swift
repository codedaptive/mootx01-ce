import Foundation
import Testing
import GeniusLocusKit
// LocusKit imported for OwnerCredentials and Drawer construction helpers.
// This file does not reference ProposeFrame by name so the GeniusLocusKit /
// LocusKit ProposeFrame ambiguity does not arise here.
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

/// Tests for EstateDreamingReader — the production adapter that binds
/// DreamingSubstrateReader to a live GeniusLocusKit estate.
///
/// Coverage plan:
///   §1  drainDreamingWindow via live estate — empty queue on a fresh estate
///   §2  existingTunnels via live estate (empty case via GLK INTERFACE)
///   §3  recentRecallTraces via live estate (empty case; trace insertion is
///       a GLK-internal operation not yet surfaced publicly, so the non-empty
///       case is covered by the LocusKit DrawerStore tests in RecallTraceItemTests)
///   §4  Protocol conformance — adapter constructs cleanly over a real estate
///
/// The positive drain case (drain after recall-driven DreamingItem enqueue)
/// is covered by the T8 end-to-end tests in DreamingQueueDrainTests.swift,
/// which exercise the full recall→enqueue→drain→bumpCoRecall→decide path
/// using a live estate opened with a wired dreaming queue.
@Suite("EstateDreamingReader — production adapter integration")
struct EstateDreamingReaderTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dreaming-reader-test")
        // In-memory estate: create the schema first, then open via the GLK coordinator.
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    // MARK: - § 1  drainDreamingWindow — live estate

    @Test("drainDreamingWindow returns empty for a fresh estate")
    func drainDreamingWindowFreshEstate() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        // No recall has fired → dreaming queue is not mounted → no windows.
        let windows = try await reader.drainDreamingWindow()
        #expect(windows.isEmpty, "fresh estate has no pending dreaming windows")
    }

    @Test("drainDreamingWindow drain-once semantics: second call returns empty")
    func drainDreamingWindowDrainOnce() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        // First drain: empty (no recall fired).
        let first = try await reader.drainDreamingWindow()
        #expect(first.isEmpty)
        // Second drain: also empty (idempotent on empty queue).
        let second = try await reader.drainDreamingWindow()
        #expect(second.isEmpty, "repeated drain on empty queue returns empty")
    }

    // MARK: - § 2  existingTunnels — live estate

    @Test("existingTunnels returns empty for a fresh estate")
    func existingTunnelsEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let tunnels = try await reader.existingTunnels()
        #expect(tunnels.isEmpty)
    }

    // MARK: - § 3  recentRecallTraces — live estate

    @Test("recentRecallTraces returns empty for a fresh estate")
    func recentRecallTracesEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let traces = try await reader.recentRecallTraces(
            since: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 9_999_999)
        )
        #expect(traces.isEmpty)
    }

    // MARK: - § 4  Protocol conformance

    @Test("EstateDreamingReader conforms to DreamingSubstrateReader")
    func conformsToProtocol() async throws {
        let (kit, handle) = try await makeKit()
        // Type-check: assigning to the protocol type must compile.
        let reader: any DreamingSubstrateReader = EstateDreamingReader(handle: handle, kit: kit)
        // Call all three reads to confirm delegation compiles and returns.
        _ = try await reader.recentRecallTraces(
            since: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 1))
        _ = try await reader.drainDreamingWindow()
        _ = try await reader.existingTunnels()
    }
}
