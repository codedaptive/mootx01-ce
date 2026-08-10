// TunnelReviewLadderTests.swift
//
// MXE-CT3 P2.5 — review ladder, decline matrix, tier-labeled filing,
// endorsement ledger, and review-queue ranking. Swift leg; the Rust
// coordinator tests mirror the integration cases and the pure cores
// carry their own fixture-identical unit tests.

import Testing
import Foundation
import LocusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("Tunnel review ladder — MXE-CT3 P2.5", .serialized)
struct TunnelReviewLadderTests {

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let modelID = "minilm-v6"

    private let near = Fingerprint256(
        block0: 0xAAAA, block1: 0xBBBB, block2: 0xCCCC, block3: 0xDDDD)

    private func makeKit(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle, LocusKit.Estate, VectorStore) {
        let kit = GeniusLocusKit()
        let creds = OwnerCredentials(ownerIdentifier: owner)
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(storage: storage, owner: creds)
        let estate = try await kit.estate(for: handle)
        let vectorStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vectorStorage)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, estate, vectorStore)
    }

    /// Capture a drawer and file its vector so the lexical lanes see it.
    @discardableResult
    private func plant(
        _ content: String,
        kit: GeniusLocusKit, handle: EstateHandle, vectorStore: VectorStore
    ) async throws -> Drawer {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "review-ladder-tests",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "review-ladder-tests",
            embeddingModelID: Self.modelID,
            eventTime: Self.t0))
        try await vectorStore.addVector(
            itemID: drawer.id, engram: near, modelID: Self.modelID,
            modelVersion: "1.0", filedAt: Self.t0)
        return drawer
    }

    /// File the typed proof pair (validity-overlap Employer facts).
    private func proveTyped(
        _ subject: String, _ a: Drawer, _ b: Drawer,
        kit: GeniusLocusKit, handle: EstateHandle
    ) async throws {
        _ = try await kit.captureKGFact(
            handle, subject: subject, predicate: "Employer",
            object: "Acme Robotics", sourceDrawerID: a.id, now: Self.t0)
        _ = try await kit.captureKGFact(
            handle, subject: subject, predicate: "Employer",
            object: "Beta Corp", sourceDrawerID: b.id, now: Self.t0)
    }

    // MARK: - Decline matrix (pure)

    @Test("decline matrix — every direction of the tier ordering")
    func declineMatrixDirections() {
        typealias Record = (tier: Int, label: String)
        let t1UserReject: [Record] = [(1, "dcp: rule@1 result=x")]
        let t3Reject: [Record] = [(3, "tier3:value_divergence@1 score=0.8")]

        // HIGHER-tier rejection suppresses lower tiers of the pair —
        // a user who rejected the proof does not want the maybe.
        #expect(GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 2, renewalKey: "tier2:word_exclusion@1",
            withdrawnRecords: t1UserReject))
        #expect(GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 3, renewalKey: "tier3:value_divergence@1",
            withdrawnRecords: t1UserReject))
        // Same tier + same renewal key: durable (F14).
        #expect(GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 1, renewalKey: "dcp: rule@1",
            withdrawnRecords: t1UserReject))
        // Same tier, version bump: renews (F15 / cue-version mirror).
        #expect(!GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 1, renewalKey: "dcp: rule@2",
            withdrawnRecords: t1UserReject))
        #expect(!GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 3, renewalKey: "tier3:value_divergence@2",
            withdrawnRecords: t3Reject))
        // LOWER-tier rejection never suppresses a higher tier: a
        // rejected lexical guess is not a rejection of a typed proof.
        #expect(!GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 1, renewalKey: "dcp: rule@1",
            withdrawnRecords: t3Reject))
        #expect(!GeniusLocusKit.declineMatrixSuppresses(
            filingTier: 2, renewalKey: "tier2:word_exclusion@1",
            withdrawnRecords: t3Reject))
        // hunter:/foreign labels never enter the records (tier nil).
        #expect(GeniusLocusKit.rejectionTier(ofLabel: "hunter: value_divergence score=0.9") == nil)
        #expect(GeniusLocusKit.rejectionTier(ofLabel: "dcp: rule@1 result=x") == 1)
        #expect(GeniusLocusKit.rejectionTier(ofLabel: "tier2:word_exclusion@1 score=1") == 2)
        #expect(GeniusLocusKit.rejectionTier(ofLabel: "tier3:value_divergence@1 score=1") == 3)
    }

    // MARK: - Tier-labeled filing

    @Test("lexical findings file as tier-labeled .proposed tunnels")
    func tier3FilingHappyPath() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-file")
        _ = try await plant("the api timeout is 30 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        _ = try await plant("the api timeout is 90 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        #expect(report.proposedTunnelIDs.isEmpty) // no typed proof planted
        #expect(report.proposedTier2IDs.isEmpty)
        #expect(report.proposedTier3IDs.count == 1)

        let tunnels = try await estate.allTunnels().filter { $0.kind == .contradicts }
        #expect(tunnels.count == 1)
        let filed = try #require(tunnels.first)
        #expect(filed.lifecycle == .proposed)
        #expect(filed.label.hasPrefix("tier3:value_divergence@\(GeniusLocusKit.conflictCueVersion) "))
        #expect(!filed.isEndorsed && !filed.isContested)

        // Second pass: the live proposal suppresses re-filing.
        let second = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        #expect(second.proposedTier3IDs.isEmpty)
        #expect(second.suppressed >= 1)
    }

    @Test("user-rejected tier-1 label suppresses lower-tier refiling of the same pair")
    func userRejectT1SuppressesLowerTiers() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-t1-reject")
        let a = try await plant("the api timeout is 30 seconds",
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant("the api timeout is 90 seconds",
                                kit: kit, handle: handle, vectorStore: vectorStore)
        try await proveTyped("Sarah Chen L1", a, b, kit: kit, handle: handle)

        // Tier-1 files first (and the live claim suppresses the
        // tier-3 filing of the same pair within the same pass).
        let first = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        #expect(first.proposedTunnelIDs.count == 1)
        #expect(first.proposedTier3IDs.isEmpty)

        // The user rejects the PROOF.
        try await estate.respondToTunnel(
            id: try #require(first.proposedTunnelIDs.first),
            accept: false, changedBy: "bob", now: Self.t0)

        // Re-propose: tier-1 stays rejected (F14) AND the tier-3 maybe
        // is suppressed too — the user did not want this pair.
        let second = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        #expect(second.proposedTunnelIDs.isEmpty)
        #expect(second.proposedTier2IDs.isEmpty)
        #expect(second.proposedTier3IDs.isEmpty)
        #expect(second.suppressed >= 2)
    }

    @Test("AI-rejected tier-3 never suppresses a typed tier-1 proposal")
    func aiRejectT3ThenTypedT1Proposes() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-t3-reject")
        let a = try await plant("the api timeout is 30 seconds",
                                kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant("the api timeout is 90 seconds",
                                kit: kit, handle: handle, vectorStore: vectorStore)

        // Tier-3 files, then a model reviewer rejects it (withdraw).
        let first = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        let tier3ID = try #require(first.proposedTier3IDs.first)
        let objection = try await kit.objectToTunnel(
            in: handle, tunnelID: tier3ID, reviewerID: "claude",
            tierLens: .lexicalValue, now: Self.t0)
        #expect(objection.withdrawn)
        #expect(!objection.contested)
        // The withdrawal carries the model's identity — reopenable.
        let withdrawn = try #require(try await estate.getTunnel(id: tier3ID))
        #expect(withdrawn.lifecycle == .withdrawn)
        let ledger = try TunnelReviewLedger.parse(withdrawn.ext)
        #expect(ledger.objections.map(\.by) == ["claude"])
        #expect(ledger.reviewedBy == "claude")

        // Typed proof arrives: tier 1 proposes DESPITE the tier-3
        // rejection (lower never suppresses higher) — and the tier-3
        // refiling stays suppressed (same renewal key).
        try await proveTyped("Sarah Chen L2", a, b, kit: kit, handle: handle)
        let second = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        #expect(second.proposedTunnelIDs.count == 1)
        #expect(second.proposedTier3IDs.isEmpty)
    }

    // MARK: - Endorsement ledger

    @Test("endorse sets bit 14, stays proposed, and is idempotent per endorser")
    func endorseIdempotencyAndBit() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-endorse")
        _ = try await plant("the api timeout is 30 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        _ = try await plant("the api timeout is 90 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        let report = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        let id = try #require(report.proposedTier3IDs.first)

        let first = try await kit.endorseTunnel(
            in: handle, tunnelID: id, endorserID: "claude",
            tierLens: .lexicalValue, now: Self.t0)
        #expect(first.newEndorser)
        #expect(first.distinctEndorsers == 1)
        #expect(!first.contested)

        // Same endorser again: one vote, timestamp refresh only.
        let again = try await kit.endorseTunnel(
            in: handle, tunnelID: id, endorserID: "claude",
            tierLens: .lexicalValue, now: Self.t0.addingTimeInterval(60))
        #expect(!again.newEndorser)
        #expect(again.distinctEndorsers == 1)

        let tunnel = try #require(try await estate.getTunnel(id: id))
        #expect(tunnel.isEndorsed)
        #expect(tunnel.lifecycle == .proposed, "endorsed is NOT a lifecycle case")
        let ledger = try TunnelReviewLedger.parse(tunnel.ext)
        #expect(ledger.endorsements.map(\.by) == ["claude"])
        #expect(ledger.endorsements.first?.atISO == "2023-11-14T22:14:20Z")
    }

    @Test("endorse + model objection = contested, stays proposed, ranked for user attention")
    func contestedDetection() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-contested")
        _ = try await plant("the api timeout is 30 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        _ = try await plant("the api timeout is 90 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        let report = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        let id = try #require(report.proposedTier3IDs.first)

        _ = try await kit.endorseTunnel(
            in: handle, tunnelID: id, endorserID: "claude",
            tierLens: .lexicalValue, now: Self.t0)
        let objection = try await kit.objectToTunnel(
            in: handle, tunnelID: id, reviewerID: "apple-onboard",
            tierLens: .lexicalValue, now: Self.t0.addingTimeInterval(60))
        #expect(objection.contested)
        #expect(!objection.withdrawn, "a contested proposal stays for the user, not withdrawn")

        let tunnel = try #require(try await estate.getTunnel(id: id))
        #expect(tunnel.isContested)
        #expect(tunnel.isEndorsed)
        #expect(tunnel.lifecycle == .proposed)

        // Contested floats to the top of its tier band in the queue.
        let ledger = try TunnelReviewLedger.parse(tunnel.ext)
        let contestedEntry = ReviewQueueRanking.entry(for: tunnel, ledger: ledger)
        let quiet = ReviewQueueEntry(
            tunnelID: "quiet", tier: 3, contested: false, weight: 5.0,
            recencyISO: "2026-08-07T12:00:00Z")
        let ranked = ReviewQueueRanking.rank([quiet, contestedEntry])
        #expect(ranked.first?.tunnelID == tunnel.id)
    }

    @Test("weight = distinct endorsers + model-family diversity bonus")
    func diversityBonus() {
        #expect(ReviewQueueRanking.modelFamily(of: "apple-onboard") == "apple")
        #expect(ReviewQueueRanking.modelFamily(of: "claude") == "claude")
        #expect(ReviewQueueRanking.modelFamily(of: "dream-adjudicator@1") == "dream")
        #expect(ReviewQueueRanking.modelFamily(of: "claude:haiku") == "claude")
        #expect(ReviewQueueRanking.endorsementWeight(endorserIDs: ["claude", "claude"]) == 1.0)
        #expect(ReviewQueueRanking.endorsementWeight(
            endorserIDs: ["claude", "claude:haiku"]) == 2.0)
        #expect(ReviewQueueRanking.endorsementWeight(
            endorserIDs: ["claude", "apple-onboard"]) == 3.0)
        #expect(ReviewQueueRanking.endorsementWeight(endorserIDs: []) == 0.0)
    }

    @Test("queue ranks tier first, endorsement weight second, recency third")
    func queueOrdering() {
        let ranked = ReviewQueueRanking.rank([
            ReviewQueueEntry(tunnelID: "t3-heavy", tier: 3, contested: false,
                             weight: 9.0, recencyISO: "2026-08-07T12:00:00Z"),
            ReviewQueueEntry(tunnelID: "t1-light", tier: 1, contested: false,
                             weight: 0.0, recencyISO: "2026-08-01T00:00:00Z"),
            ReviewQueueEntry(tunnelID: "t2-contested", tier: 2, contested: true,
                             weight: 1.0, recencyISO: "2026-08-02T00:00:00Z"),
            ReviewQueueEntry(tunnelID: "t2-heavy", tier: 2, contested: false,
                             weight: 5.0, recencyISO: "2026-08-07T12:00:00Z"),
            ReviewQueueEntry(tunnelID: "t2-b", tier: 2, contested: false,
                             weight: 2.0, recencyISO: "2026-08-03T00:00:00Z"),
            ReviewQueueEntry(tunnelID: "t2-a", tier: 2, contested: false,
                             weight: 2.0, recencyISO: "2026-08-03T00:00:00Z"),
        ])
        #expect(ranked.map(\.tunnelID) ==
            ["t1-light", "t2-contested", "t2-heavy", "t2-a", "t2-b", "t3-heavy"])
    }

    // MARK: - Human-authoritative activation

    @Test("user accept is unchanged and endorse can never activate")
    func userAcceptUnchangedEndorseCannotActivate() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "ladder-accept")
        _ = try await plant("the api timeout is 30 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        _ = try await plant("the api timeout is 90 seconds",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        let report = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        let id = try #require(report.proposedTier3IDs.first)

        // A pile of endorsements across families — maximum weight.
        for endorser in ["claude", "apple-onboard", "dream-adjudicator@1"] {
            _ = try await kit.endorseTunnel(
                in: handle, tunnelID: id, endorserID: endorser,
                tierLens: .lexicalValue, now: Self.t0)
        }
        // No vote total activates anything: still proposed.
        let endorsed = try #require(try await estate.getTunnel(id: id))
        #expect(endorsed.lifecycle == .proposed)

        // The user path, unchanged, is the ONLY activation.
        try await estate.respondToTunnel(
            id: id, accept: true, changedBy: "bob", now: Self.t0)
        let active = try #require(try await estate.getTunnel(id: id))
        #expect(active.lifecycle == .active)
        #expect(try TunnelReviewLedger.parse(active.ext).reviewedBy == "bob")

        // And a settled tunnel cannot be endorsed — the ladder only
        // operates on proposals.
        await #expect(throws: LocusKitError.self) {
            _ = try await kit.endorseTunnel(
                in: handle, tunnelID: id, endorserID: "claude",
                tierLens: .lexicalValue, now: Self.t0)
        }
    }

    // MARK: - OCC guard (stale model-write rejection)

    /// Regression test for the OCC guard added in GK-01.
    ///
    /// Scenario: a model computes an endorsed bitmap from a proposed tunnel,
    /// but the user accepts the tunnel before the model's write lands.
    /// `stampTunnelReview` must reject the stale write so the user's
    /// acceptance is not clobbered.
    @Test("stampTunnelReview rejects stale write after user accepts")
    func stampTunnelReviewRejectsStaleWriteAfterUserAccepts() async throws {
        let (kit, handle, estate, vectorStore) = try await makeKit(owner: "occ-guard")
        _ = try await plant("the contract expires in 30 days",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        _ = try await plant("the contract expires in 90 days",
                            kit: kit, handle: handle, vectorStore: vectorStore)
        let report = try await kit.proposeConflictTunnels(in: handle, now: Self.t0)
        let id = try #require(report.proposedTier3IDs.first)

        // Read the proposed tunnel to capture the bitmap a model would compute.
        let proposed = try #require(try await estate.getTunnel(id: id))
        #expect(proposed.lifecycle == .proposed)
        let staleBitmap = proposed.withEndorsed().operationalBitmap

        // User accepts — lifecycle moves proposed → active.
        try await estate.respondToTunnel(id: id, accept: true, changedBy: "bob", now: Self.t0)
        let accepted = try #require(try await estate.getTunnel(id: id))
        #expect(accepted.lifecycle == .active)

        // Model tries to write its stale endorsed bitmap — must be rejected.
        await #expect(throws: LocusKitError.tunnelNoLongerProposed(id: id)) {
            try await estate.stampTunnelReview(
                id: id, operationalBitmap: staleBitmap, ext: nil)
        }

        // Tunnel must remain active with no endorsed bit set.
        let after = try #require(try await estate.getTunnel(id: id))
        #expect(after.lifecycle == .active, "user acceptance must not be overwritten")
        #expect(!after.isEndorsed, "stale endorsed bit must not be applied")
    }
}
