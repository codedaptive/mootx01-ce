// MeetingDecisionCapture.swift
//
// DCP M6 — the filing seam for the controlled-decision grammar. The pure
// parser lives in SubstrateML/MeetingDecisionExtractor.swift; this layer
// files each accepted decision as a KGFact so the typed proving lane
// (ConflictProjectionSweep) can evaluate it against the estate's other
// claims. F21/F22 (two conflicting transcripts → proof end-to-end) run
// through exactly this path.
//
// Filing posture: extracted facts file ACTIVE. The controlled register
// is strict enough that an accepted line IS an assertion (the grammar
// rejected everything hypothetical, quoted, or ambiguous), and the M0 §2
// proof floor requires both facts active — a pending-state filing would
// exile every extracted decision from the proving lane. What stays
// PROPOSED in this program is the downstream contradicts tunnel (M5
// review lifecycle), not the fact itself.
//
// Replay safety: fact ids are deterministic —
// sha256("dcp-meeting-v1|<sourceDrawerID>|<subject>|<predicate>|<object>")
// — and `addKGFact` is a plain insert, so re-extracting the same
// transcript SKIPS already-filed ids instead of erroring or duplicating.

import CryptoKit
import Foundation
import LocusKit
import SubstrateML

/// One transcript's filing outcome.
public struct MeetingDecisionCaptureReport: Sendable {
    /// The parse outcome (accepted + rejected lines).
    public let extraction: MeetingDecisionExtraction
    /// Ids of facts filed THIS call, in transcript order.
    public let filedFactIDs: [String]
    /// Ids skipped because an identical fact was already on file
    /// (deterministic-id replay).
    public let skippedExistingIDs: [String]
    /// `Replaces decision <id>` references, keyed by the filed (or
    /// skipped) fact id — the M5 supersession wiring input.
    public let replacesByFactID: [String: String]
}

public extension GeniusLocusKit {

    /// Deterministic KGFact id for an extracted decision (replay-safe).
    static func meetingDecisionFactID(
        sourceDrawerID: String, subject: String,
        predicate: String, object: String
    ) -> String {
        let input = "\(meetingDecisionExtractorID)|\(sourceDrawerID)|\(subject)|\(predicate)|\(object)"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Parse `transcript` under the v0.1 registry and file each accepted
    /// decision as an ACTIVE KGFact anchored to `sourceDrawerID` (the
    /// transcript's drawer). `now` is the filing instant (fleet
    /// determinism discipline — pass `Date()` at non-test call sites).
    func captureMeetingDecisions(
        in handle: EstateHandle,
        transcript: String,
        sourceDrawerID: String,
        registry: ConflictRuleRegistry = .v01,
        now: Date
    ) async throws -> MeetingDecisionCaptureReport {
        let extraction = MeetingDecisionExtractor.extract(
            transcript: transcript, registry: registry)
        let store = try await ensureKGStore(for: handle)

        var filed: [String] = []
        var skipped: [String] = []
        var replaces: [String: String] = [:]
        for decision in extraction.decisions {
            let id = Self.meetingDecisionFactID(
                sourceDrawerID: sourceDrawerID,
                subject: decision.entity,
                predicate: decision.dimension,
                object: decision.rawValue)
            if let replacedID = decision.replacesID {
                replaces[id] = replacedID
            }
            if try await store.getKGFact(id: id) != nil {
                skipped.append(id)
                continue
            }
            try await store.addKGFact(KGFact(
                id: id,
                subject: decision.entity,
                // The rule's canonical dimension spelling, so projection's
                // dimensionKey(predicate) round-trips to the same rule.
                predicate: decision.dimension,
                object: decision.rawValue,
                sourceDrawerID: sourceDrawerID,
                filedAt: now))
            filed.append(id)
        }
        return MeetingDecisionCaptureReport(
            extraction: extraction,
            filedFactIDs: filed,
            skippedExistingIDs: skipped,
            replacesByFactID: replaces)
    }
}
