// FeatureExtractorsTests.swift
//
// Per-stream ambient feature extractors per cookbook § 3.9.
// swift-testing peer suite for Sources/SubstrateML/FeatureExtractors.swift.
//
// rust/src/feature_extractors.rs carries NO #[test], so this suite
// provides partial Swift-side coverage: HealthKit determinism,
// stream-source flag and UDC lattice anchor for HealthKit + CoreLocation
// only, rowId/HLC passthrough (HealthKit), input-sensitivity (HealthKit),
// EventKit attendee-order independence, and CoreLocation geohash bucketing.
// ScreenTime and SystemTelemetry extractors have no explicit test coverage
// in this file. Fingerprints are computed under a fixed, deterministically
// generated hyperplane family.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("FeatureExtractors")
struct FeatureExtractorsTests {

    // A fixed, deterministically generated four-block family so the
    // SimHash projections are reproducible across runs. The ambient
    // feature extractors feed a single 64-bit subhash word to every
    // block (SimHash.fingerprint(fromSubhashes:)), so each block here
    // is a 64-bit-input family — distinct from the 192/64/64/64
    // estate-local row family.
    private let family: [HyperplaneFamily] = {
        let seed = [UInt8](repeating: 0x5A, count: 32)
        return (0..<4).map {
            HyperplaneFamily.generate(seed: seed, blockIndex: $0, inputBitLength: 64)
        }
    }()

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }

    private func healthSample(value: Double = 1234) -> HealthKitSample {
        HealthKitSample(quantityType: "stepCount", value: value, unit: "count",
                        startDate: 1000, endDate: 2000, sourceDevice: "Watch")
    }

    @Test("the HealthKit extractor is deterministic on its inputs")
    func healthKitDeterministic() {
        let ex = HealthKitExtractor(hyperplanes: family)
        let id = UUID()
        let a = ex.extract(healthSample(), hlc: hlc(100), rowId: id)
        let b = ex.extract(healthSample(), hlc: hlc(100), rowId: id)
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.payload == b.payload)
    }

    @Test("each extractor tags its own stream-source flag and UDC anchor")
    func streamSourceAndLattice() {
        let id = UUID()
        let health = HealthKitExtractor(hyperplanes: family).extract(healthSample(), hlc: hlc(1), rowId: id)
        #expect(health.streamSource == StreamSourceFlag.healthkit.rawValue)
        #expect(health.lattice == LatticeAnchor.udc("613.71"))

        let loc = CoreLocationExtractor(hyperplanes: family).extract(
            CoreLocationSample(latitude: 37.33, longitude: -122.03, altitude: 10,
                               speed: 1, course: 90, timestamp: 1, horizontalAccuracy: 5),
            hlc: hlc(1), rowId: id)
        #expect(loc.streamSource == StreamSourceFlag.corelocation.rawValue)
        #expect(loc.lattice == LatticeAnchor.udc("914"))
        #expect(loc.payload.isEmpty)   // CoreLocation carries no payload
    }

    @Test("the rowId and capture HLC pass through unchanged")
    func passesThroughIdentity() {
        let id = UUID()
        let row = HealthKitExtractor(hyperplanes: family).extract(healthSample(), hlc: hlc(777), rowId: id)
        #expect(row.rowId == id)
        #expect(row.captureHLC == hlc(777))
    }

    @Test("materially different samples produce different fingerprints")
    func sensitivity() {
        let ex = HealthKitExtractor(hyperplanes: family)
        let id = UUID()
        let a = ex.extract(healthSample(value: 100), hlc: hlc(1), rowId: id)
        let b = ex.extract(healthSample(value: 999_999), hlc: hlc(1), rowId: id)
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test("EventKit attendee hashing is order-independent")
    func eventKitAttendeeOrderIndependent() {
        let ex = EventKitExtractor(hyperplanes: family)
        let id = UUID()
        func sample(_ attendees: [String]) -> EventKitSample {
            EventKitSample(eventIdentifier: "E1", title: "Standup",
                           startDate: 1000, endDate: 2000, calendarIdentifier: "work",
                           attendees: attendees, location: "Room 1")
        }
        let ab = ex.extract(sample(["alice", "bob"]), hlc: hlc(1), rowId: id)
        let ba = ex.extract(sample(["bob", "alice"]), hlc: hlc(1), rowId: id)
        #expect(ab.fingerprint == ba.fingerprint)
    }

    @Test("geohash quantization is deterministic and precision-bucketed")
    func geohashQuantization() {
        let g1 = CoreLocationExtractor.quantizeGeohash(lat: 37.331, lon: -122.031, precision: 2)
        let g2 = CoreLocationExtractor.quantizeGeohash(lat: 37.331, lon: -122.031, precision: 2)
        #expect(g1 == g2)
        // precision 2 ⇒ buckets at 0.01; 37.331 → floor(3733.1) = 3733.
        #expect(g1 == "3733,-12204")
    }
}
