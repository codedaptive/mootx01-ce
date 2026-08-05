// ConflictTunnelLifecycle.swift
//
// DCP M5 — the typed lane's write step: proven contradictions become
// PROPOSED `contradicts` tunnels (review via moot_review_tunnel, same
// lifecycle as the lexical hunter's proposals), and the meeting
// grammar's `Replaces decision` references become ACTIVE `supersedes`
// tunnels so the next sweep reads the pair as HistoricalSuccession
// (F22 end-to-end).
//
// Sensitivity ceiling: a proven finding whose endpoint sensitivity
// ceiling exceeds Elevated is never proposed — the same policy, the same
// raw-value comparison, and the same position ahead of the dedup check
// that the lexical hunter applies before it screens a pair
// (ContradictionHunt.swift). Ceiling skips are counted apart from dedup
// suppressions so the gate's activity is visible in the report.
//
// Dedup contract (F14/F15):
// - ANY live (active or proposed) `contradicts` tunnel between the
//   pair suppresses a new proposal — the claim is already on the books.
// - A WITHDRAWN (rejected) tunnel suppresses re-proposal only for the
//   SAME rule@version (rejection is durable, F14). A registry bump is
//   new evidence: the same pair under rule@2 files a NEW instance
//   (F15). Typed proposals carry `dcp: <ruleID>@<version>` in the
//   label so the version survives in the tunnel record itself.
// - A withdrawn LEXICAL tunnel (the hunter's `hunter: …` label) does
//   NOT suppress a typed proposal: a rejected textual guess is not a
//   rejection of a typed proof.

import Foundation
import LocusKit
import SubstrateML

/// One M5 pass's outcome.
public struct ConflictTunnelProposalReport: Sendable {
    /// The sweep the proposals were derived from.
    public let sweep: ConflictProjectionSweepReport
    /// Tunnel ids proposed THIS pass, in sweep order.
    public let proposedTunnelIDs: [String]
    /// Proven findings suppressed by the dedup contract.
    public let suppressed: Int
    /// Proven findings skipped because their sensitivity ceiling exceeds
    /// Elevated. Counted apart from `suppressed`: "already on the books"
    /// and "above the ceiling" are different facts, and folding the
    /// second into the first would hide the gate's activity from anyone
    /// reading the report — including from whoever has to notice it has
    /// regressed.
    public let ceilingSkipped: Int
}

public extension GeniusLocusKit {

    /// Label prefix for typed-lane proposals; the rule@version after it
    /// is the F15 renewal key.
    static let conflictProposalLabelPrefix = "dcp: "

    /// Run one typed sweep and file a PROPOSED `contradicts` tunnel for
    /// every proven finding that survives the dedup contract. `now` is
    /// the filing instant (determinism discipline).
    func proposeConflictTunnels(
        in handle: EstateHandle,
        registry: ConflictRuleRegistry = .v01,
        now: Date
    ) async throws -> ConflictTunnelProposalReport {
        let sweep = try await conflictProjectionSweep(in: handle, registry: registry)
        let estate = try estate(for: handle)

        // Dedup state: live pairs (any label) and withdrawn typed labels
        // per pair.
        var livePairs: Set<String> = []
        var withdrawnTypedLabelsByPair: [String: Set<String>] = [:]
        for tunnel in try await estate.allTunnels() where tunnel.kind == .contradicts {
            guard let s = tunnel.sourceDrawerId, let t = tunnel.targetDrawerId else { continue }
            let pair = Self.pairKey(s, t)
            switch tunnel.lifecycle {
            case .active, .proposed:
                livePairs.insert(pair)
            case .withdrawn, .superseded:
                if tunnel.label.hasPrefix(Self.conflictProposalLabelPrefix) {
                    withdrawnTypedLabelsByPair[pair, default: []].insert(tunnel.label)
                }
            }
        }

        var proposed: [String] = []
        var suppressed = 0
        var ceilingSkipped = 0
        for finding in sweep.proven {
            let outcome = finding.outcome
            guard outcome.sourceDrawerIDs.count == 2 else { continue }
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the
            // Normal tier (normal + elevated). Restricted/secret rows
            // must not be screened, proposed, or echoed as borderline
            // snippets.
            //
            // Compare the RAW ceiling, never a decoded tier: decoding
            // coerces every unrecognised raw — scale-gapped intermediates
            // and beyond-spec values alike — to `.normal`, so a
            // decode-based check would wave through exactly the rows this
            // gate exists to stop. The sweep already computed this
            // ceiling as the MAX endpoint sensitivity, and it fails
            // closed on an unresolvable endpoint.
            if finding.sensitivityCeilingRaw > AdjectiveSensitivity.elevated.rawValue {
                ceilingSkipped += 1
                continue
            }
            let a = outcome.sourceDrawerIDs[0], b = outcome.sourceDrawerIDs[1]
            let pair = Self.pairKey(a, b)
            let label = "\(Self.conflictProposalLabelPrefix)\(outcome.ruleID)@\(outcome.ruleVersion) "
                + "result=\(outcome.resultID)"
            let renewalKey = "\(Self.conflictProposalLabelPrefix)\(outcome.ruleID)@\(outcome.ruleVersion)"
            if livePairs.contains(pair) {
                suppressed += 1
                continue
            }
            if let rejected = withdrawnTypedLabelsByPair[pair],
               rejected.contains(where: { $0.hasPrefix(renewalKey) }) {
                // F14: exact repeat of a rejected proof stays rejected.
                // (A different rule VERSION misses this prefix → F15
                // files a new instance.)
                suppressed += 1
                continue
            }
            // Endpoint coordinates from the node tree — a pair whose
            // endpoints cannot be resolved is skipped, same posture as
            // the lexical hunter (never file fabricated coordinates).
            let drawers = try await estate.hydrateBodies(ids: [a, b])
            guard drawers.count == 2 else { continue }
            let byID = Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) })
            guard let da = byID[a], let db = byID[b] else { continue }
            let names = try await estate.resolveNodeNames(
                parentNodeIds: [da.parentNodeId, db.parentNodeId])
            guard let aNames = names[da.parentNodeId],
                  let bNames = names[db.parentNodeId] else { continue }
            let tunnel = try await estate.capture(TunnelCaptureFrame(
                sourceWing: aNames.wing,
                sourceRoom: aNames.room,
                targetWing: bNames.wing,
                targetRoom: bNames.room,
                label: label,
                addedBy: "conflict-projection",
                sourceDrawerId: a,
                targetDrawerId: b,
                kind: .contradicts,
                originClass: .derived,
                lifecycle: .proposed))
            livePairs.insert(pair)
            proposed.append(tunnel.id)
        }
        return ConflictTunnelProposalReport(
            sweep: sweep, proposedTunnelIDs: proposed, suppressed: suppressed,
            ceilingSkipped: ceilingSkipped)
    }

    /// File the ACTIVE `supersedes` tunnels for a meeting-capture
    /// report's `Replaces decision` references (F22): the replaced
    /// fact's source drawer is superseded by the replacing fact's
    /// source drawer. References to unknown fact ids are returned
    /// unresolved — the grammar accepted the line, the estate just has
    /// no such fact (yet).
    func fileSupersessions(
        in handle: EstateHandle,
        report: MeetingDecisionCaptureReport,
        now: Date
    ) async throws -> (filedTunnelIDs: [String], unresolved: [String]) {
        guard !report.replacesByFactID.isEmpty else { return ([], []) }
        let estate = try estate(for: handle)
        let store = try await ensureKGStore(for: handle)
        var filed: [String] = []
        var unresolved: [String] = []
        for (factID, replacedFactID) in report.replacesByFactID.sorted(by: { $0.key < $1.key }) {
            guard let newFact = try await store.getKGFact(id: factID),
                  let oldFact = try await store.getKGFact(id: replacedFactID),
                  !oldFact.sourceDrawerID.isEmpty, !newFact.sourceDrawerID.isEmpty
            else {
                unresolved.append(replacedFactID)
                continue
            }
            let ids = [newFact.sourceDrawerID, oldFact.sourceDrawerID]
            let drawers = try await estate.hydrateBodies(ids: ids)
            let byID = Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) })
            guard let newDrawer = byID[newFact.sourceDrawerID],
                  let oldDrawer = byID[oldFact.sourceDrawerID] else {
                unresolved.append(replacedFactID)
                continue
            }
            let names = try await estate.resolveNodeNames(
                parentNodeIds: [newDrawer.parentNodeId, oldDrawer.parentNodeId])
            guard let nNames = names[newDrawer.parentNodeId],
                  let oNames = names[oldDrawer.parentNodeId] else {
                unresolved.append(replacedFactID)
                continue
            }
            // Source = the SUPERSEDING drawer, target = the superseded
            // one (LocusKit supersedes convention). ACTIVE because the
            // controlled grammar's Replaces line IS the acceptance.
            let tunnel = try await estate.capture(TunnelCaptureFrame(
                sourceWing: nNames.wing,
                sourceRoom: nNames.room,
                targetWing: oNames.wing,
                targetRoom: oNames.room,
                label: "\(meetingDecisionExtractorID): replaces \(replacedFactID)",
                addedBy: "conflict-projection",
                sourceDrawerId: newFact.sourceDrawerID,
                targetDrawerId: oldFact.sourceDrawerID,
                kind: .supersedes,
                originClass: .derived,
                lifecycle: .active))
            filed.append(tunnel.id)
        }
        return (filed, unresolved)
    }
}
