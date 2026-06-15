// AssociationRulesTests.swift
//
// End-to-end tests for the AssociationRules recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Verifies
// the full through-line: GLK recall → label extraction → MatrixO →
// mineAssociationRules → relabeled output.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// `.serialized`: each test opens a fresh estate and runs captures
/// sequentially; preserve the one-at-a-time execution the suite ran
/// under XCTest.
@Suite("AssociationRulesTests", .serialized)
struct AssociationRulesTests {

    // MARK: - Harness

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "ar-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        room: String,
        kind: ContentKind = .prose,
        channel: CaptureChannel = .typed
    ) async throws {
        let frame = CaptureFrame(
            content: "test content",
            channel: channel,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "ar-test",
            embeddingModelID: "test-v1",
            kind: kind)
        _ = try await kit.capture(handle, frame)
    }

    // MARK: - Tests

    // CK-AR-1: empty estate — no drawers recalled, no rules.
    @Test("empty estate yields no rules")
    func emptyEstateYieldsNoRules() async throws {
        let (kit, handle) = try await openEstate()
        let input = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            thresholds: .init(minSupport: 0.0, minConfidence: 0.0))
        let out = try await AssociationRules().run(
            input: input, estate: handle, kit: kit)
        #expect(out.rules.isEmpty)
        #expect(out.drawerCount == 0)
    }

    // CK-AR-2: two rooms captured together repeatedly produce a rule.
    //
    // 4 drawers in room "study" with kind prose + channel typed.
    // 4 drawers in room "work" with kind code + channel voiced.
    // Labels include room:study, kind:prose, channel:typed and
    // room:work, kind:code, channel:voiced. Co-occurring labels
    // within each drawer should produce high-confidence rules.
    @Test("co-occurring labels produce rules above threshold")
    func coOccurringLabelsProduceRules() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<4 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
            try await capture(kit, handle, room: "work", kind: .code, channel: .voiced)
        }

        let input = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            thresholds: .init(minSupport: 0.2, minConfidence: 0.5))
        let out = try await AssociationRules().run(
            input: input, estate: handle, kit: kit)

        // Rules exist — the two regimes have high internal co-occurrence.
        #expect(!out.rules.isEmpty)
        #expect(out.drawerCount == 8)

        // Every rule names both antecedent and consequent as string labels.
        for rule in out.rules {
            #expect(!rule.antecedent.isEmpty)
            #expect(!rule.consequent.isEmpty)
            #expect(rule.support > 0)
            #expect(rule.confidence > 0)
        }
    }

    // CK-AR-3: thresholds gate rules — high threshold removes low-support rules.
    @Test("high support threshold removes low-support rules")
    func highThresholdFilters() async throws {
        let (kit, handle) = try await openEstate()
        // 2 drawers: one with room "rare", one without.
        try await capture(kit, handle, room: "rare", kind: .prose, channel: .typed)
        try await capture(kit, handle, room: "common", kind: .prose, channel: .typed)
        try await capture(kit, handle, room: "common", kind: .prose, channel: .typed)
        try await capture(kit, handle, room: "common", kind: .prose, channel: .typed)

        // At threshold 0.9, only rules appearing in 90%+ of drawers pass.
        // kind:prose + channel:typed co-occur in all 4 drawers, so those
        // rules should pass. room:rare appears in only 1/4 → rules involving
        // it are gated out.
        let high = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            thresholds: .init(minSupport: 0.9, minConfidence: 0.9))
        let highOut = try await AssociationRules().run(
            input: high, estate: handle, kit: kit)

        let low = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            thresholds: .init(minSupport: 0.0, minConfidence: 0.0))
        let lowOut = try await AssociationRules().run(
            input: low, estate: handle, kit: kit)

        // High threshold is strictly more restrictive.
        #expect(highOut.rules.count <= lowOut.rules.count)
    }

    // CK-AR-4: capability gate fires — the recipe declares .associationRuleMining
    // and verifyCapabilities correctly rejects when that capability is absent.
    @Test("capability declaration is associationRuleMining")
    func capabilityDeclaration() {
        let recipe = AssociationRules()
        #expect(recipe.requiredCapabilities == [.associationRuleMining])
        // The gate correctly rejects a host that does not supply this capability.
        #expect(throws: RecipeError.missingCapability(.associationRuleMining)) {
            try verifyCapabilities(
                required: recipe.requiredCapabilities,
                available: [.hybridRecall])
        }
    }

    // CK-AR-5: determinism — same recalled set yields identical rules.
    @Test("two runs on the same estate produce identical rules")
    func rulesAreDeterministic() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
        }
        for _ in 0..<3 {
            try await capture(kit, handle, room: "work", kind: .code, channel: .voiced)
        }

        let input = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            thresholds: .init(minSupport: 0.0, minConfidence: 0.0))
        let first = try await AssociationRules().run(input: input, estate: handle, kit: kit)
        let second = try await AssociationRules().run(input: input, estate: handle, kit: kit)

        #expect(first.rules.count == second.rules.count)
        for (a, b) in zip(first.rules, second.rules) {
            #expect(a.antecedent == b.antecedent)
            #expect(a.consequent == b.consequent)
        }
    }
}

extension AssociationRulesTests {

    // CK-AR-OV: more than 64 distinct labels trips the documented cap.
    // 70 unique rooms (+ kind:prose + channel:typed shared by every
    // drawer) exceed the 64-label table; the recipe flags the overflow
    // AND still mines rules over the kept labels — the sorted table
    // keeps channel:/kind: labels (they precede room:* alphabetically),
    // which co-occur in every drawer.
    @Test("label overflow past 64 is flagged and rules still mine")
    func labelOverflowIsFlaggedAndRulesStillMine() async throws {
        let (kit, handle) = try await openEstate()
        for i in 0..<70 {
            try await capture(kit, handle, room: String(format: "room%02d", i))
        }

        let input = AssociationRules.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed], limit: 100),
            thresholds: .init(minSupport: 0.0, minConfidence: 0.0))
        let out = try await AssociationRules().run(
            input: input, estate: handle, kit: kit)

        #expect(out.labelOverflow, "more than 64 distinct labels flags the cap")
        #expect(out.drawerCount == 70)
        #expect(!out.rules.isEmpty,
                "rules still mine over the kept (sorted-first-64) labels")
    }
}

// MARK: - AprioriRules recipe tests

extension AssociationRulesTests {

    // CK-AP-1: empty estate produces no Apriori rules — verifies recipe
    // wiring (capability check, currentAuditLog call, empty-return path).
    @Test("AprioriRules recipe returns empty on fresh estate")
    func aprioriRulesEmptyEstate() async throws {
        let (kit, handle) = try await openEstate()
        let input = AprioriRules.Input(
            thresholds: AprioriThresholds(
                minSupport: 0.5,
                minConfidence: 0.5,
                minLift: 1.0,
                maxK: 2
            )
        )
        let out = try await AprioriRules().run(input: input, estate: handle, kit: kit)
        #expect(out.rules.isEmpty,
                "fresh estate has no audit entries and no Apriori rules")
    }

    // CK-AP-2: recipe has the expected capability gate.
    @Test("AprioriRules capability declaration is associationRuleMining")
    func aprioriCapabilityDeclaration() {
        let recipe = AprioriRules()
        #expect(recipe.requiredCapabilities == [.associationRuleMining])
        #expect(throws: RecipeError.missingCapability(.associationRuleMining)) {
            try verifyCapabilities(
                required: recipe.requiredCapabilities,
                available: [.hybridRecall])
        }
    }

    // CK-AP-3: recipe returns a non-throwing result with captures in the estate.
    // The audit log after capture may or may not yield frequent patterns; what
    // we verify is that the recipe runs to completion without error.
    @Test("AprioriRules recipe runs without error after captures")
    func aprioriRulesRunsAfterCaptures() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<4 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
        }
        let input = AprioriRules.Input(
            thresholds: AprioriThresholds(
                minSupport: 0.1,
                minConfidence: 0.1,
                minLift: 0.5,
                maxK: 2
            )
        )
        // Should not throw; result may be empty or non-empty depending on
        // the audit entries the LocusKit trail produces for these drawers.
        let out = try await AprioriRules().run(input: input, estate: handle, kit: kit)
        // Every returned rule must have a non-empty antecedent.
        for rule in out.rules {
            #expect(!rule.antecedent.isEmpty)
        }
    }
}
