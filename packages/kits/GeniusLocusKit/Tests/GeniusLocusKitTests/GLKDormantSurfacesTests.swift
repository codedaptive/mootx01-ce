// GLKDormantSurfacesTests.swift
//
// Shared-fixture tests for the dormant-surfaces estate reads
// (dormant-surfaces mission, Part 5).
//
// Covers:
//   • glkEventLagPairs: 5-event fixture with known HLCs and values;
//     asserts entry count, HLC-ascending order, and per-entry field
//     coordinate encoding (bitmap, string, integer, bytes, null).
//   • Calibration round-trip: record outcomes, read back the curve,
//     verify decay is applied at the next write (30-day half-life).
//
// The Rust port carries the same fixture values and produces identical
// results; see packages/kits/GeniusLocusKit/rust/tests/dormant_surfaces.rs.

import Testing
import SubstrateTypes
import SubstrateML
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Test-only audit-log injection helper

// Adds a synthetic UnifiedAuditEntry directly into GLK's in-memory
// audit log without going through the LocusKit storage tier. This
// allows deterministic lag-pair tests with precise physicalTime values.
private extension GeniusLocusKit {
    func injectAuditEntry(_ entry: UnifiedAuditEntry, for handle: EstateHandle) {
        auditLogs[handle, default: UnifiedAuditLog()].add(entry)
    }
}

// MARK: - Shared fixture constants (identical to Rust dormant_surfaces.rs)

// Physicals are ms-since-Unix-epoch; seconds = physical / 1000.
private enum Fixture {
    static let tBase:   Int64 = 1_000_000_000_000  // t+0 min
    static let tPlusOne: Int64 = 1_000_000_060_000  // t+1 min
    static let tPlusThree: Int64 = 1_000_000_180_000  // t+3 min
    static let tPlusTen: Int64 = 1_000_000_600_000  // t+10 min
    static let tPlusTwoHundred: Int64 = 1_000_012_000_000  // t+200 min (still inside 256-min window)

    // Bucket expectations for TemporalCausalityFold when called with
    // window=256 and startWatermark=.zero:
    //   B-from-A: 1 min → bucket 1
    //   C-from-A: 3 min → bucket 4 (lagBuckets: [1,2,4,…])
    //   C-from-B: 2 min → bucket 2
    //   D-from-A: 10 min → bucket 16
    //   D-from-B:  9 min → bucket 16
    //   D-from-C:  7 min → bucket 8
    //   E-from-A: 200 min → bucket 128 (clamped to largest boundary)
    //   (B,C,D pairs with E are within window too)
}

// MARK: - Suite

@Suite("GLK dormant surfaces — lag pair and calibration reads")
struct GLKDormantSurfacesTests {

    // MARK: - Estate helpers

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dormant-surfaces-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func hlc(_ p: Int64, _ l: Int32 = 0) -> HLC {
        HLC(physicalTime: p, logicalCount: l, nodeID: 1)
    }

    private func makeEntry(
        physicalTime: Int64,
        verb: UnifiedAuditVerb,
        field: String,
        value: UnifiedAuditValue
    ) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(physicalTime),
            verb: verb,
            rowID: UUID(),
            fieldPath: field,
            beforeValue: .null,
            afterValue: value
        )
    }

    // MARK: - glkEventLagPairs: five-event fixture

    @Test("lag pair fixture: 5 capture/expunge entries produce 5 temporal entries")
    func lagPairFiveEntryCount() async throws {
        let (kit, handle) = try await makeKit()

        // Five entries covering different value types (same fixture as Rust port).
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "alpha", value: .bitmap(0xAB)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusOne,
            verb: .capture, field: "beta", value: .string("hello")), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusThree,
            verb: .capture, field: "gamma", value: .integer(42)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusTen,
            verb: .expunge, field: "alpha", value: .bitmap(0xAB)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusTwoHundred,
            verb: .capture, field: "delta", value: .bytes([1, 2, 3])), for: handle)

        // Also inject a noise entry (verb=recall) that should produce empty coords.
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusOne + 1,
            verb: .recall, field: "beta", value: .string("hello")), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = Date(timeIntervalSince1970: Double(Fixture.tPlusTwoHundred) / 1_000.0 + 1.0)
        let window   = baseDate...topDate

        let entries = try await kit.glkEventLagPairs(in: handle, window: window)

        // 6 entries in window (5 capture/expunge + 1 recall), all returned.
        #expect(entries.count == 6)
    }

    @Test("lag pair fixture: HLC-ascending order")
    func lagPairOrdering() async throws {
        let (kit, handle) = try await makeKit()

        // Insert in non-ascending order to test sort stability.
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusTen,
            verb: .capture, field: "gamma", value: .integer(42)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "alpha", value: .bitmap(0xAB)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusOne,
            verb: .capture, field: "beta", value: .string("hello")), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = Date(timeIntervalSince1970: Double(Fixture.tPlusTen) / 1_000.0 + 1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 3)
        // Must be HLC-ascending.
        #expect(entries[0].hlc.physicalTime == Fixture.tBase)
        #expect(entries[1].hlc.physicalTime == Fixture.tPlusOne)
        #expect(entries[2].hlc.physicalTime == Fixture.tPlusTen)
    }

    @Test("lag pair fixture: bitmap coord encoding")
    func lagPairBitmapCoord() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "alpha", value: .bitmap(0xAB)), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords.count == 1)
        // 0xAB decimal = 171
        #expect(entries[0].fieldCoords[0].fieldPath == "alpha")
        #expect(entries[0].fieldCoords[0].valueRepr == "bitmap:171")
    }

    @Test("lag pair fixture: string coord encoding")
    func lagPairStringCoord() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "beta", value: .string("hello")), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords[0].valueRepr == "string:hello")
    }

    @Test("lag pair fixture: integer coord encoding")
    func lagPairIntegerCoord() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "gamma", value: .integer(42)), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords[0].valueRepr == "integer:42")
    }

    @Test("lag pair fixture: bytes coord encoding uses byte count")
    func lagPairBytesCoord() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "delta", value: .bytes([1, 2, 3])), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords[0].valueRepr == "bytes:3")
    }

    @Test("lag pair fixture: null after-value produces empty coord list")
    func lagPairNullCoord() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "epsilon", value: .null), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        // Null after-value: entry present but no field coordinates.
        #expect(entries[0].fieldCoords.isEmpty)
    }

    @Test("lag pair fixture: non-capture/expunge verb produces empty coord list")
    func lagPairNonCaptureVerb() async throws {
        let (kit, handle) = try await makeKit()
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .recall, field: "beta", value: .string("hello")), for: handle)

        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(1.0)
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        // recall verb is included in results (it advances the fold watermark)
        // but produces an empty coord list.
        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords.isEmpty)
    }

    @Test("lag pair fixture: window filter excludes out-of-range entries")
    func lagPairWindowFilter() async throws {
        let (kit, handle) = try await makeKit()

        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tBase,
            verb: .capture, field: "alpha", value: .bitmap(1)), for: handle)
        await kit.injectAuditEntry(makeEntry(
            physicalTime: Fixture.tPlusTwoHundred,
            verb: .capture, field: "beta", value: .bitmap(2)), for: handle)

        // Window that only includes the first entry.
        let baseDate = Date(timeIntervalSince1970: Double(Fixture.tBase) / 1_000.0)
        let topDate  = baseDate.addingTimeInterval(60.0)  // +1 min
        let entries = try await kit.glkEventLagPairs(in: handle, window: baseDate...topDate)

        #expect(entries.count == 1)
        #expect(entries[0].fieldCoords[0].valueRepr == "bitmap:1")
    }

    @Test("lag pair fixture: estateNotOpen error for closed handle")
    func lagPairUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        let window = Date()...Date().addingTimeInterval(60)
        do {
            _ = try await kit.glkEventLagPairs(in: handle, window: window)
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    // MARK: - Calibration round-trip

    @Test("calibration: record and read back — single success in bucket 14")
    func calibrationRecordAndRead() async throws {
        let (kit, handle) = try await makeKit()

        // confidence 0.7 → idx = Int(0.7 * 20) = 14
        let now = Date(timeIntervalSince1970: 0)
        try await kit.glkRecordCalibrationOutcome(
            for: handle,
            modelID: "test-model",
            claimedConfidence: 0.7,
            succeeded: true,
            at: now
        )

        let curve = try await kit.glkCalibrationCurve(for: handle, modelID: "test-model")
        let bucket = try #require(curve).buckets[14]
        #expect(bucket.count == 1)
        #expect(bucket.successRate == 1.0)
    }

    @Test("calibration: unknown model returns nil curve")
    func calibrationUnknownModel() async throws {
        let (kit, handle) = try await makeKit()
        let curve = try await kit.glkCalibrationCurve(for: handle, modelID: "no-such-model")
        #expect(curve == nil)
    }

    @Test("calibration: 30-day decay halves bucket count at next write")
    func calibrationDecayHalvesBucketCount() async throws {
        let (kit, handle) = try await makeKit()

        let t0 = Date(timeIntervalSince1970: 0)
        let modelID = "decay-test-model"

        // Record 10 successes at t=0.
        for _ in 0..<10 {
            try await kit.glkRecordCalibrationOutcome(
                for: handle,
                modelID: modelID,
                claimedConfidence: 0.7,
                succeeded: true,
                at: t0
            )
        }

        // Verify 10 successes landed in bucket 14.
        let curveAfter10 = try await kit.glkCalibrationCurve(for: handle, modelID: modelID)
        let b14After10 = try #require(curveAfter10).buckets[14]
        #expect(b14After10.count == 10)
        #expect(abs(b14After10.successRate - 1.0) < 0.001)

        // 30 days later: decay factor = 0.5^(30/30) = 0.5
        // count = round(10 * 0.5) = round(5.0) = 5 (ties round to even = 4 via banker's rounding,
        // but Double.rounded() uses schoolbook rounding — 5.0 → 5).
        // Then record 1 failure: count = 6, rate = (1.0*5 + 0.0)/6 = 5/6 ≈ 0.8333
        let t30 = t0.addingTimeInterval(30 * 24 * 3_600)
        try await kit.glkRecordCalibrationOutcome(
            for: handle,
            modelID: modelID,
            claimedConfidence: 0.7,
            succeeded: false,
            at: t30
        )

        let curveAfterDecay = try await kit.glkCalibrationCurve(for: handle, modelID: modelID)
        let b14AfterDecay = try #require(curveAfterDecay).buckets[14]
        // Count should be 5 (decayed from 10) + 1 new = 6.
        #expect(b14AfterDecay.count == 6)
        // Success rate: (1.0 * 5 + 0.0) / 6 ≈ 0.8333
        #expect(abs(b14AfterDecay.successRate - (5.0 / 6.0)) < 0.001)
    }

    @Test("calibration: estateNotOpen error for glkCalibrationCurve")
    func calibrationCurveUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            _ = try await kit.glkCalibrationCurve(for: handle, modelID: "m")
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    @Test("calibration: estateNotOpen error for glkRecordCalibrationOutcome")
    func calibrationRecordUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            try await kit.glkRecordCalibrationOutcome(
                for: handle, modelID: "m",
                claimedConfidence: 0.5, succeeded: true,
                at: Date(timeIntervalSince1970: 0))
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    // MARK: - Temporal reads (forwarding only — full coverage is in LocusKit tests)

    @Test("glkFingerprintsCaptured: estateNotOpen for closed handle")
    func fingerprintsCapturedUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            _ = try await kit.glkFingerprintsCaptured(in: handle, window: Date()...Date())
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    @Test("glkFingerprintBitSeries: estateNotOpen for closed handle")
    func fingerprintBitSeriesUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            _ = try await kit.glkFingerprintBitSeries(
                in: handle, bit: 0,
                bucketSeconds: 60, bucketCount: 1,
                endingAt: Date())
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    // MARK: - Maintenance-accessor bundle (board items 4b/4d)

    private func captureFrame(content: String, room: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "dormant-surfaces-tests",
            embeddingModelID: "model-v1"
        )
    }

    @Test("allDrawers(in:limit:) caps the read; nil reads the full corpus")
    func allDrawersBoundedCapsTheRead() async throws {
        let (kit, handle) = try await makeKit()
        for i in 0..<5 {
            _ = try await kit.capture(handle, captureFrame(content: "c\(i)", room: "study"))
        }
        let two = try await kit.allDrawers(in: handle, limit: 2)
        #expect(two.count == 2, "limit caps the read at 2 rows")
        let all = try await kit.allDrawers(in: handle, limit: nil)
        #expect(all.count == 5, "nil reads the full corpus")
    }

    @Test("allDrawers(in:limit:): estateNotOpen for closed handle")
    func allDrawersBoundedUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            _ = try await kit.allDrawers(in: handle, limit: 1)
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    @Test("roomLevelFingerprints(in:) returns a real aggregate after capture")
    func roomLevelFingerprintsReturnsAggregate() async throws {
        let (kit, handle) = try await makeKit()
        _ = try await kit.capture(handle, captureFrame(content: "alpha", room: "study"))
        let entries = try await kit.roomLevelFingerprints(in: handle)
        #expect(!entries.isEmpty, "a captured drawer populates a room-level fingerprint")
        let study = entries.first { $0.room == "study" }
        #expect(study != nil, "the captured room appears as a container")
    }

    @Test("roomLevelFingerprints(in:): estateNotOpen for closed handle")
    func roomLevelFingerprintsUnknownHandle() async throws {
        let (kit, handle) = try await makeKit()
        try await kit.close(handle)
        do {
            _ = try await kit.roomLevelFingerprints(in: handle)
            Issue.record("Expected estateNotOpen to be thrown")
        } catch let err as GeniusLocusKitError {
            if case .estateNotOpen = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }
}
