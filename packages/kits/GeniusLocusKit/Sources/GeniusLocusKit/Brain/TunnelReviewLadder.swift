// TunnelReviewLadder.swift
//
// MXE-CT3 P2.5 — the model-reviewer half of the review ladder
// (Rejected / Proposed / Endorsed / Accepted) on proposed `contradicts`
// tunnels.
//
// A model (AI) reviewer may ENDORSE (`endorseTunnel`) and REJECT
// (`objectToTunnel`). ONLY the user ACCEPTS: there is deliberately NO
// path in this file — or anywhere in GLK — from endorsements to
// lifecycle `.active`. Edge activation stays human-authoritative
// through `Estate.respondToTunnel(accept: true)`; endorsement weight
// feeds REVIEW-QUEUE RANKING ONLY (`ReviewQueueRanking`), and no vote
// total activates anything. That refusal is the design, not an
// omission: the moment votes can activate an edge, a model with a
// systematic blind spot can rewrite the estate's belief graph at
// scale, and the user's authority over "what is true here" is gone.
//
// State carried on the tunnel (LocusKit):
// - bit 14 `isEndorsed` — set on first endorsement; lifecycle stays
//   `.proposed`.
// - bit 15 `isContested` — set when the ext ledger holds BOTH a model
//   endorsement and a model objection (genuine model disagreement —
//   ranked for user attention).
// - `ext` — the `TunnelReviewLedger`: one vote per distinct endorser
//   (idempotent re-endorsement updates its timestamp only), objections
//   with reviewer identity, and `reviewedBy` on every transition.
//
// Rust twin: `EstateCoordinator::endorse_tunnel` /
// `EstateCoordinator::object_to_tunnel` (coordinator.rs).

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
import LocusKit

/// Outcome of one `endorseTunnel` call.
public struct TunnelEndorsementOutcome: Sendable, Equatable {
    public let tunnelID: String
    /// True when this call added a NEW distinct endorser; false when it
    /// was an idempotent re-endorsement (timestamp refresh only).
    public let newEndorser: Bool
    /// Distinct endorser count after this call.
    public let distinctEndorsers: Int
    /// True when the tunnel is now contested (bit 15).
    public let contested: Bool
}

/// Outcome of one `objectToTunnel` call.
public struct TunnelObjectionOutcome: Sendable, Equatable {
    public let tunnelID: String
    /// True when the objection withdrew the proposal (no model
    /// endorsement existed — the AI-rejected path, recorded in the
    /// ledger so a surface can reopen it).
    public let withdrawn: Bool
    /// True when the tunnel is now contested (bit 15) — it had a model
    /// endorsement, so it STAYS `.proposed` and floats to the top of
    /// its tier band for user attention.
    public let contested: Bool
}

public extension GeniusLocusKit {

    /// Model-reviewer endorsement of a `.proposed` tunnel.
    ///
    /// Appends to the ext ledger (one vote per distinct endorser —
    /// idempotent: a repeat endorsement by the same `endorserID`
    /// updates its timestamp only), sets the endorsed bit (14), and
    /// sets the contested bit (15) when the ledger already holds a
    /// model objection. Lifecycle is NOT touched — see the file header
    /// for why endorse can never activate.
    ///
    /// - Parameters:
    ///   - tunnelID: the proposed tunnel under review.
    ///   - endorserID: reviewer identity ("apple-onboard", "claude",
    ///     "dream-adjudicator@1"). The prefix before the first "-" or
    ///     ":" is the model family for the diversity bonus.
    ///   - tierLens: the contradiction tier the reviewer judged under.
    ///   - now: deterministic clock supplied by the caller.
    /// - Throws: `LocusKitError.tunnelNotFound` when absent;
    ///   `LocusKitError.invalidContent` when the tunnel is not
    ///   `.proposed`, the endorser id is empty, or the ext ledger is
    ///   corrupt (fail-loud).
    @discardableResult
    func endorseTunnel(
        in handle: EstateHandle,
        tunnelID: String,
        endorserID: String,
        tierLens: ContradictionTier,
        now: Date
    ) async throws -> TunnelEndorsementOutcome {
        guard !endorserID.isEmpty else {
            throw LocusKitError.invalidContent("endorserID must not be empty")
        }
        let estate = try estate(for: handle)
        guard let tunnel = try await estate.getTunnel(id: tunnelID) else {
            throw LocusKitError.tunnelNotFound(id: tunnelID)
        }
        guard tunnel.lifecycle == .proposed else {
            throw LocusKitError.invalidContent(
                "tunnel \(tunnelID) is \(tunnel.lifecycle) — only a proposed tunnel can be endorsed")
        }
        var ledger = try TunnelReviewLedger.parse(tunnel.ext)
        let newEndorser = ledger.recordEndorsement(
            by: endorserID,
            atISO: TunnelReviewLedger.isoTimestamp(now),
            tier: tierLens.rawValue)
        var updated = tunnel.withEndorsed()
        if ledger.isContestedEvidence {
            updated = updated.withContested()
        }
        do {
            try await estate.stampTunnelReview(
                id: tunnelID,
                operationalBitmap: updated.operationalBitmap,
                ext: ledger.serialized())
        } catch LocusKitError.tunnelNoLongerProposed {
            // Concurrent respondToTunnel moved the lifecycle between our read
            // and this write — the model vote is a no-op; the user's decision prevails.
            logger.info("stale model vote: tunnel \(tunnelID) no longer proposed — endorsement not applied")
            return TunnelEndorsementOutcome(
                tunnelID: tunnelID,
                newEndorser: false,
                distinctEndorsers: 0,
                contested: false)
        }
        return TunnelEndorsementOutcome(
            tunnelID: tunnelID,
            newEndorser: newEndorser,
            distinctEndorsers: ledger.distinctEndorserCount,
            contested: updated.isContested)
    }

    /// Model-reviewer rejection/objection on a `.proposed` tunnel.
    ///
    /// Records the objection (one per distinct reviewer, idempotent)
    /// and the reviewer identity, then:
    /// - NO model endorsement in the ledger → the proposal WITHDRAWS
    ///   (lifecycle `.withdrawn`) — the AI-rejected path. The objection
    ///   entry is what distinguishes it from a user rejection, so a
    ///   future surface can reopen it; the decline matrix suppresses
    ///   re-proposal at this tier and below, never above.
    /// - a model endorsement EXISTS → the tunnel STAYS `.proposed` and
    ///   the contested bit (15) is set: one model endorsed, another
    ///   objected, and genuine model disagreement is the most
    ///   user-worthy queue position — withdrawing it would hide
    ///   exactly the proposal the user most needs to see.
    ///
    /// - Throws: same contract as `endorseTunnel`.
    @discardableResult
    func objectToTunnel(
        in handle: EstateHandle,
        tunnelID: String,
        reviewerID: String,
        tierLens: ContradictionTier,
        now: Date
    ) async throws -> TunnelObjectionOutcome {
        guard !reviewerID.isEmpty else {
            throw LocusKitError.invalidContent("reviewerID must not be empty")
        }
        let estate = try estate(for: handle)
        guard let tunnel = try await estate.getTunnel(id: tunnelID) else {
            throw LocusKitError.tunnelNotFound(id: tunnelID)
        }
        guard tunnel.lifecycle == .proposed else {
            throw LocusKitError.invalidContent(
                "tunnel \(tunnelID) is \(tunnel.lifecycle) — only a proposed tunnel can be objected to")
        }
        var ledger = try TunnelReviewLedger.parse(tunnel.ext)
        ledger.recordObjection(
            by: reviewerID,
            atISO: TunnelReviewLedger.isoTimestamp(now),
            tier: tierLens.rawValue)
        ledger.recordReview(by: reviewerID)

        let contested = ledger.isContestedEvidence
        let updated: Tunnel
        if contested {
            // Endorsed elsewhere → stays proposed, marked contested.
            updated = tunnel.withContested()
        } else {
            // AI-rejected: withdraw. The ledger's objection entry is
            // the reopenable record.
            updated = tunnel.withLifecycle(.withdrawn)
        }
        do {
            try await estate.stampTunnelReview(
                id: tunnelID,
                operationalBitmap: updated.operationalBitmap,
                ext: ledger.serialized())
        } catch LocusKitError.tunnelNoLongerProposed {
            // Concurrent respondToTunnel moved the lifecycle between our read
            // and this write — the model vote is a no-op; the user's decision prevails.
            logger.info("stale model vote: tunnel \(tunnelID) no longer proposed — objection not applied")
            return TunnelObjectionOutcome(
                tunnelID: tunnelID,
                withdrawn: false,
                contested: false)
        }
        return TunnelObjectionOutcome(
            tunnelID: tunnelID,
            withdrawn: !contested,
            contested: contested)
    }
}
