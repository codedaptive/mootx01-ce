// GuardianPairParityTests.swift
//
// SwiftSyntax Guardian enforcement floor for the §3 cross-layer
// correspondences. The Guardian's syntax-tree checker catches drift at
// the desk (tools/guardian); these tests catch it in CI where the
// Guardian is not run as a build phase.
//
// Each test asserts one registered pair from the Guardian's registry.
// A test failure here means a raw-integer literal in SubstrateLib or
// DrawerStore has drifted from its canonical enum source in
// LocusKit/Adjectives.swift — exactly the class of bug the Guardian
// exists to prevent.
//
// Coverage:
//   Pairs 1-4 (set equality):
//     state-basis         AuditGate.basis[state].legalValues == State allCases raws
//     sensitivity-basis   AuditGate.basis[sensitivity].legalValues == AdjectiveSensitivity allCases raws
//     exportability-basis AuditGate.basis[exportability].legalValues == AdjectiveExportability allCases raws
//     trust-basis         AuditGate.basis[trust].legalValues == Trust allCases raws
//   Pairs 4b (DrawerStore inline duplicates — also set equality):
//     drawerstore-mutate-state   DrawerStore.mutateState stateSlot.legalValues == State allCases raws
//     drawerstore-expunge-state  DrawerStore.expungeGated stateSlot.legalValues == State allCases raws
//   Pairs 5-6 (single-value threshold — checked as raw value equality):
//     i22-sensitivity-raw  AdjectiveSensitivity.secret.rawValue == 48
//     i22-exportability-raw AdjectiveExportability.public_.rawValue == 32
//     s1-trust-threshold   Trust.canonical.rawValue == 3
//
// Placement: LocusKitTests. The LocusKitTests target depends on LocusKit,
// which depends on SubstrateLib. Vocabulary.basis is a public static let
// on SubstrateLib.Vocabulary, reachable through the build graph. The tests
// use @testable import LocusKit; SubstrateLib public symbols are accessible
// transitively (LocusKit lists SubstrateLib as a dependency in Package.swift).
// A SubstrateLib test target importing LocusKit would invert the layer order
// even in a test context — that is not permitted.

import Foundation
import Testing
@testable import LocusKit
import SubstrateLib

// MARK: - Helpers

/// Extract the legalValues from the basis slot whose label matches.
/// Returns nil if the slot is not found or has an empty legalValues
/// (the flags slot uses an empty set, meaning "any value fits width").
private func basisLegalValues(label: String) -> Set<Int64>? {
    guard let slot = Vocabulary.basis.first(where: { $0.label == label }) else {
        return nil
    }
    return slot.legalValues.isEmpty ? nil : slot.legalValues
}

@Suite("GuardianPairParityTests")
struct GuardianPairParityTests {

    // MARK: - Pair 1: state-basis
    //
    // AuditGate.basis[state].legalValues == State rawValues (all 10 cases).
    // Drift would mean the gate accepts states the LocusKit enum doesn't define,
    // or rejects states it does.
    //
    // Canonical raws per cookbook §2.3 / §2.8:
    //   active=0, pending=1, contested=2, accepted=3,
    //   superseded=16, decayed=17, withdrawn=18, expired=19,
    //   rejected=32, tombstoned=33
    @Test("Pair 1 state-basis: AuditGate.basis[state].legalValues == State raws")
    func stateBasisEqualsStateRaws() {
        guard let basisSet = basisLegalValues(label: "state") else {
            Issue.record("basis slot 'state' not found or has empty legalValues")
            return
        }
        // Explicit set — enums in this file do not conform to CaseIterable;
        // explicit declaration makes the expected value immediately visible.
        let canonicalRaws: Set<Int64> = [
            Int64(State.active.rawValue),
            Int64(State.pending.rawValue),
            Int64(State.contested.rawValue),
            Int64(State.accepted.rawValue),
            Int64(State.superseded.rawValue),
            Int64(State.decayed.rawValue),
            Int64(State.withdrawn.rawValue),
            Int64(State.expired.rawValue),
            Int64(State.rejected.rawValue),
            Int64(State.tombstoned.rawValue),
        ]
        #expect(basisSet == canonicalRaws,
            "state-basis drift: basis legalValues \(basisSet.sorted()) != State raws \(canonicalRaws.sorted())")
    }

    @Test("Pair 1 state-basis: State raw value spot-checks (cookbook §2.3 scale-gapped layout)")
    func stateRawValueSpotChecks() {
        // Verify the scale-gapped boundaries match what the basis encodes.
        // Cluster A boundary: 0; Cluster B boundary: 16; Cluster C boundary: 32.
        #expect(State.active.rawValue == 0)
        #expect(State.pending.rawValue == 1)
        #expect(State.superseded.rawValue == 16)
        #expect(State.rejected.rawValue == 32)
        #expect(State.tombstoned.rawValue == 33)
    }

    // MARK: - Pair 2: sensitivity-basis
    //
    // AuditGate.basis[sensitivity].legalValues == AdjectiveSensitivity rawValues.
    // Scale-gapped layout per cookbook §2.3: 0, 16, 32, 48.
    @Test("Pair 2 sensitivity-basis: AuditGate.basis[sensitivity].legalValues == AdjectiveSensitivity raws")
    func sensitivityBasisEqualsAdjectiveSensitivityRaws() {
        guard let basisSet = basisLegalValues(label: "sensitivity") else {
            Issue.record("basis slot 'sensitivity' not found or has empty legalValues")
            return
        }
        let canonicalRaws: Set<Int64> = [
            Int64(AdjectiveSensitivity.normal.rawValue),
            Int64(AdjectiveSensitivity.elevated.rawValue),
            Int64(AdjectiveSensitivity.restricted.rawValue),
            Int64(AdjectiveSensitivity.secret.rawValue),
        ]
        #expect(basisSet == canonicalRaws,
            "sensitivity-basis drift: basis legalValues \(basisSet.sorted()) != AdjectiveSensitivity raws \(canonicalRaws.sorted())")
    }

    @Test("Pair 2 sensitivity-basis: AdjectiveSensitivity scale-gapped raws are 0/16/32/48 (cookbook §2.3)")
    func sensitivityRawValueSpotChecks() {
        #expect(AdjectiveSensitivity.normal.rawValue == 0)
        #expect(AdjectiveSensitivity.elevated.rawValue == 16)
        #expect(AdjectiveSensitivity.restricted.rawValue == 32)
        #expect(AdjectiveSensitivity.secret.rawValue == 48)
    }

    // MARK: - Pair 3: exportability-basis
    //
    // AuditGate.basis[exportability].legalValues == AdjectiveExportability rawValues.
    // Scale-gapped layout per cookbook §2.3: 0, 32.
    @Test("Pair 3 exportability-basis: AuditGate.basis[exportability].legalValues == AdjectiveExportability raws")
    func exportabilityBasisEqualsAdjectiveExportabilityRaws() {
        guard let basisSet = basisLegalValues(label: "exportability") else {
            Issue.record("basis slot 'exportability' not found or has empty legalValues")
            return
        }
        let canonicalRaws: Set<Int64> = [
            Int64(AdjectiveExportability.private_.rawValue),
            Int64(AdjectiveExportability.public_.rawValue),
        ]
        #expect(basisSet == canonicalRaws,
            "exportability-basis drift: basis legalValues \(basisSet.sorted()) != AdjectiveExportability raws \(canonicalRaws.sorted())")
    }

    @Test("Pair 3 exportability-basis: AdjectiveExportability scale-gapped raws are 0/32 (cookbook §2.3)")
    func exportabilityRawValueSpotChecks() {
        #expect(AdjectiveExportability.private_.rawValue == 0)
        #expect(AdjectiveExportability.public_.rawValue == 32)
    }

    // MARK: - Pair 4: trust-basis
    //
    // AuditGate.basis[trust].legalValues == Trust rawValues (all 7 cases).
    // Gradient layout per cookbook §2.3 v0.6: 0..6.
    @Test("Pair 4 trust-basis: AuditGate.basis[trust].legalValues == Trust raws")
    func trustBasisEqualsTrustRaws() {
        guard let basisSet = basisLegalValues(label: "trust") else {
            Issue.record("basis slot 'trust' not found or has empty legalValues")
            return
        }
        let canonicalRaws: Set<Int64> = [
            Int64(Trust.verbatim.rawValue),
            Int64(Trust.observed.rawValue),
            Int64(Trust.imported.rawValue),
            Int64(Trust.canonical.rawValue),
            Int64(Trust.derived.rawValue),
            Int64(Trust.proposed.rawValue),
            Int64(Trust.ambient.rawValue),
        ]
        #expect(basisSet == canonicalRaws,
            "trust-basis drift: basis legalValues \(basisSet.sorted()) != Trust raws \(canonicalRaws.sorted())")
    }

    @Test("Pair 4 trust-basis: Trust raw value spot-checks (cookbook §2.3 v0.6)")
    func trustRawValueSpotChecks() {
        #expect(Trust.verbatim.rawValue == 0)
        #expect(Trust.canonical.rawValue == 3)
        #expect(Trust.ambient.rawValue == 6)
    }

    // MARK: - Pairs 4b: DrawerStore inline stateSlot duplicates
    //
    // DrawerStore.mutateState and DrawerStore.expungeGated both declare a
    // stateSlot with inline legalValues. These cannot be tested directly (the
    // slots are local variables inside actor methods). The test asserts the
    // canonical State raws match the known expected inline set; if State raws
    // change, this test fails, which means the DrawerStore literals also need
    // updating. The Guardian's syntax extractor cross-checks the DrawerStore
    // side against the same canonical set at the desk.
    @Test("Pair 4b-a drawerstore-mutate-state: canonical State raws match DrawerStore inline literal set")
    func drawerStoreMutateStateSlotLegalValuesMatchesState() {
        let canonicalRaws: Set<Int64> = [
            Int64(State.active.rawValue),
            Int64(State.pending.rawValue),
            Int64(State.contested.rawValue),
            Int64(State.accepted.rawValue),
            Int64(State.superseded.rawValue),
            Int64(State.decayed.rawValue),
            Int64(State.withdrawn.rawValue),
            Int64(State.expired.rawValue),
            Int64(State.rejected.rawValue),
            Int64(State.tombstoned.rawValue),
        ]
        // The expected inline set from DrawerStore.mutateState stateSlot.
        // If this #expect fails, the DrawerStore literal needs to match State.
        let expectedDrawerStoreInline: Set<Int64> = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
        #expect(canonicalRaws == expectedDrawerStoreInline,
            "drawerstore-mutate-state drift: State raws \(canonicalRaws.sorted()) != DrawerStore inline \(expectedDrawerStoreInline.sorted())")
    }

    @Test("Pair 4b-b drawerstore-expunge-state: canonical State raws match DrawerStore inline literal set")
    func drawerStoreExpungeStateSlotLegalValuesMatchesState() {
        let canonicalRaws: Set<Int64> = [
            Int64(State.active.rawValue),
            Int64(State.pending.rawValue),
            Int64(State.contested.rawValue),
            Int64(State.accepted.rawValue),
            Int64(State.superseded.rawValue),
            Int64(State.decayed.rawValue),
            Int64(State.withdrawn.rawValue),
            Int64(State.expired.rawValue),
            Int64(State.rejected.rawValue),
            Int64(State.tombstoned.rawValue),
        ]
        let expectedDrawerStoreInline: Set<Int64> = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
        #expect(canonicalRaws == expectedDrawerStoreInline,
            "drawerstore-expunge-state drift: State raws \(canonicalRaws.sorted()) != DrawerStore inline \(expectedDrawerStoreInline.sorted())")
    }

    // MARK: - Pair 5: I-22 raw values (single-value threshold checks)
    //
    // RowStateAutomaton.ForbiddenCombinations.check uses inline integer
    // literals 48 and 32 in the I-22 check (`sensitivity == 48 && exportability == 32`).
    // These must equal the canonical enum rawValues in LocusKit/Adjectives.swift.
    // Checked here as test assertions rather than syntax-tree extraction (the
    // Guardian extracts integer-literal SETS; a singleton threshold vs a full
    // enum set is more reliably expressed as a direct rawValue assertion).
    @Test("Pair 5a i22-sensitivity-raw: AdjectiveSensitivity.secret.rawValue == 48 (I-22 lower bound)")
    func i22SensitivityRawIs48() {
        // raw 48 appears inline in RowStateAutomaton: `if sensitivity == 48 && ...`
        // LocusKit/Adjectives.swift is the source of truth.
        #expect(AdjectiveSensitivity.secret.rawValue == 48,
            "I-22 sensitivity drift: AdjectiveSensitivity.secret.rawValue is \(AdjectiveSensitivity.secret.rawValue), expected 48")
    }

    @Test("Pair 5b i22-exportability-raw: AdjectiveExportability.public_.rawValue == 32 (I-22 upper bound)")
    func i22ExportabilityRawIs32() {
        // raw 32 appears inline in RowStateAutomaton: `... && exportability == 32`
        #expect(AdjectiveExportability.public_.rawValue == 32,
            "I-22 exportability drift: AdjectiveExportability.public_.rawValue is \(AdjectiveExportability.public_.rawValue), expected 32")
    }

    // MARK: - Pair 6: S-1 trust threshold (single-value threshold check)
    //
    // RowStateAutomaton.ForbiddenCombinations.check uses inline integer literal 3
    // in the S-1 check (`if trust < 3`). Must equal Trust.canonical.rawValue.
    @Test("Pair 6 s1-trust-threshold: Trust.canonical.rawValue == 3 (S-1 floor for accepted rows)")
    func s1TrustThresholdIs3() {
        // raw 3 appears inline in RowStateAutomaton: `if trust < 3`
        // LocusKit/Adjectives.swift is the source of truth.
        #expect(Trust.canonical.rawValue == 3,
            "S-1 threshold drift: Trust.canonical.rawValue is \(Trust.canonical.rawValue), expected 3")
    }
}
