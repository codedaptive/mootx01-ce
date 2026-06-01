// GeniusLocusKitErrorTests.swift
//
// Per-type coverage for `GeniusLocusKitError` (Part 2 gap suite).
//
// The error enum is exercised case-by-case across the verb-surface,
// coordinator, federation, and scheduler suites — each throws and
// matches a single case. None of those suites assert the type's OWN
// surface: its `Equatable` conformance (two cases compare equal iff
// case + payload match) and its `CustomStringConvertible.description`
// (the human-readable text each case renders). This suite pins both.
//
// TEST-ONLY. No production source modified.

import Testing
import Foundation
@testable import GeniusLocusKit

@Suite("GeniusLocusKitError surface")
struct GeniusLocusKitErrorTests {

    // Fixed UUIDs so description assertions are deterministic.
    private let u1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let u2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let branch = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - description

    @Test
    func invalidManifestDescription() {
        let e = GeniusLocusKitError.invalidManifest(key: "estate_uuid", detail: "missing")
        #expect(e.description == "invalid manifest field 'estate_uuid': missing")
    }

    @Test
    func estateNotOpenDescription() {
        let e = GeniusLocusKitError.estateNotOpen(estateUUID: u1)
        #expect(e.description == "estate \(u1) is not open in this kit")
    }

    @Test
    func duplicateEstateDescription() {
        let e = GeniusLocusKitError.duplicateEstate(estateUUID: u1)
        #expect(e.description == "estate \(u1) is already open")
    }

    @Test
    func underlyingEstateFailureDescription() {
        let e = GeniusLocusKitError.underlyingEstateFailure(reason: "disk full")
        #expect(e.description == "underlying LocusKit.Estate failure: disk full")
    }

    @Test
    func invalidLatticeRegionDescription() {
        let e = GeniusLocusKitError.invalidLatticeRegion(low: 10, high: 4)
        #expect(e.description == "invalid lattice region: low 10 > high 4")
    }

    @Test
    func schedulerSignalNotRegisteredDescription() {
        let e = GeniusLocusKitError.schedulerSignalNotRegistered(SignalID(rawValue: "sig-1"))
        #expect(e.description == "signal sig-1 is not registered with the addressed estate's scheduler")
    }

    @Test
    func schedulerNotStartedDescription() {
        let e = GeniusLocusKitError.schedulerNotStarted(estateUUID: u1)
        #expect(e.description == "estate \(u1) has no standing-signal scheduler — register a signal first")
    }

    @Test
    func branchNotTrackedDescription() {
        let e = GeniusLocusKitError.branchNotTracked(branchID: branch)
        #expect(e.description == "branch \(branch) is not tracked in this kit instance")
    }

    @Test
    func invalidPromotionTargetDescription() {
        let e = GeniusLocusKitError.invalidPromotionTarget(
            branchID: branch, expectedEstateUUID: u1, actualEstateUUID: u2)
        #expect(e.description == "branch \(branch) cannot be promoted into estate \(u2): its parent estate is \(u1)")
    }

    @Test
    func crossEstateReadRefusedDescription() {
        let e = GeniusLocusKitError.crossEstateReadRefused(
            source: u1, requester: u2, reason: .noActiveGrant)
        // `reason` interpolates with the enum's default representation;
        // assert the stable prefix/structure rather than the reason token.
        #expect(e.description.hasPrefix("cross-estate read of \(u1) by \(u2) refused:"))
    }

    // MARK: - Equatable

    @Test
    func equalWhenCaseAndPayloadMatch() {
        #expect(GeniusLocusKitError.estateNotOpen(estateUUID: u1)
                == GeniusLocusKitError.estateNotOpen(estateUUID: u1))
        #expect(GeniusLocusKitError.invalidLatticeRegion(low: 10, high: 4)
                == GeniusLocusKitError.invalidLatticeRegion(low: 10, high: 4))
        #expect(GeniusLocusKitError.crossEstateReadRefused(source: u1, requester: u2, reason: .grantExpired)
                == GeniusLocusKitError.crossEstateReadRefused(source: u1, requester: u2, reason: .grantExpired))
    }

    @Test
    func notEqualWhenPayloadDiffers() {
        #expect(GeniusLocusKitError.estateNotOpen(estateUUID: u1)
                != GeniusLocusKitError.estateNotOpen(estateUUID: u2))
        #expect(GeniusLocusKitError.invalidLatticeRegion(low: 10, high: 4)
                != GeniusLocusKitError.invalidLatticeRegion(low: 4, high: 10))
        #expect(GeniusLocusKitError.crossEstateReadRefused(source: u1, requester: u2, reason: .noActiveGrant)
                != GeniusLocusKitError.crossEstateReadRefused(source: u1, requester: u2, reason: .grantExpired))
    }

    @Test
    func notEqualWhenCaseDiffers() {
        #expect(GeniusLocusKitError.estateNotOpen(estateUUID: u1)
                != GeniusLocusKitError.duplicateEstate(estateUUID: u1))
        #expect(GeniusLocusKitError.branchNotTracked(branchID: branch)
                != GeniusLocusKitError.schedulerNotStarted(estateUUID: branch))
    }

    // MARK: - usable as Error

    @Test
    func isThrowableAndCatchableAsTypedError() {
        func boom() throws { throw GeniusLocusKitError.duplicateEstate(estateUUID: u1) }
        #expect(throws: GeniusLocusKitError.duplicateEstate(estateUUID: u1)) {
            try boom()
        }
    }
}
