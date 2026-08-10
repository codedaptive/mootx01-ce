// ConflictTunnelLifecycle.swift
//
// DCP M5 + MXE-CT3 P2.5 — the contradiction lanes' write step.
//
// REVIEW LADDER (P2.5): Rejected / Proposed / Endorsed / Accepted.
// Every proposal files as a lifecycle-`.proposed` `contradicts` tunnel.
// A model (AI) reviewer may REJECT (withdraw, via `objectToTunnel`) and
// ENDORSE (bit 14 via `endorseTunnel` — NOT a lifecycle case; the
// tunnel stays proposed). ONLY the user ACCEPTS: edge activation is
// human-authoritative through `respondToTunnel(accept: true)`, and no
// GLK path promotes endorsements to `.active`. Reviewer identity is
// recorded in the tunnel's ext ledger on every transition
// (LocusKit `TunnelReviewLedger`).
//
// TIER-LABELED FILING (P2.5): all three tiers now file proposals, each
// under its own label family:
//   tier 1 (typed proof)        — "dcp: <ruleID>@<ruleVersion> …"
//                                 (existing scheme, unchanged)
//   tier 2 (structural lexical) — "tier2:<cueKind>@<cueVersion> …"
//   tier 3 (value divergence)   — "tier3:<cueKind>@<cueVersion> …"
// Tier-2/3 proposals classify out of the SAME lexical retrieval pass
// the tiered search reads (`lexicalTierScan`) — borderline candidates
// become reviewable proposals instead of report-only findings.
// `conflictCueVersion` is the F15 mirror for the lexical families: a
// cue-engine evolution bumps it, renewing rejections.
//
// COEXISTING LABEL FAMILY: the lexical hunter's `hunter: …` filing in
// `huntContradictions` is UNCHANGED this wave and stays outside the
// decline matrix (its own dedup lives in the hunter). Live `hunter:`
// tunnels still suppress ALL new filings via the live-pair rule; its
// withdrawn tunnels suppress nothing here — the pre-P2.5 "a rejected
// textual guess is not a rejection of a typed proof" rule, preserved
// as the special case of the tier ordering below.
//
// Sensitivity ceiling: a proven finding whose endpoint sensitivity
// ceiling exceeds Elevated is never proposed — the same policy, the same
// raw-value comparison, and the same position ahead of the dedup check
// that the lexical hunter applies before it screens a pair
// (ContradictionHunt.swift). Ceiling skips are counted apart from dedup
// suppressions so the gate's activity is visible in the report. The
// lexical lanes enforce the same ceiling per-endpoint inside
// `lexicalTierScan` before any candidate is classified.
//
// DECLINE MATRIX (F14/F15, generalized to the tier ordering):
// - ANY live (active or proposed) `contradicts` tunnel between the
//   pair suppresses a new proposal at every tier — the claim is
//   already on the books.
// - A WITHDRAWN (rejected) tunnel at tier T suppresses:
//     * same-tier re-proposal of the SAME label renewal key
//       (rule@version / cueKind@cueVersion) — rejection is durable
//       (F14); a version bump is new evidence and files a NEW
//       instance (F15, mirrored by `conflictCueVersion`);
//     * ALL lower-tier (numerically higher) re-filing of the same
//       PAIR, regardless of label: a user who rejected the proof does
//       not want the maybe. Tier ordering is tier1 > tier2 > tier3.
//   A rejection NEVER suppresses a proposal at a HIGHER tier: typed
//   proof outranks a rejected lexical guess (AI-reject T3 then a typed
//   T1 finding → T1 proposes).
// - Whether the rejection was user- or model-authored does not change
//   the matrix — it changes the RECORD: model rejections carry an
//   objection entry (and reviewedBy) in the ext ledger, so a future
//   surface can reopen AI-rejected pairs. User rejections carry only
//   reviewedBy and are not machine-reopenable.

import Foundation
import LocusKit
import SubstrateML

/// One M5/P2.5 pass's outcome.
public struct ConflictTunnelProposalReport: Sendable {
    /// The sweep the proposals were derived from.
    public let sweep: ConflictProjectionSweepReport
    /// TIER-1 (typed) tunnel ids proposed THIS pass, in sweep order.
    /// Name kept from the tier-1-only era so readers stay source-
    /// compatible; the lexical tiers report through the fields below.
    public let proposedTunnelIDs: [String]
    /// Tier-2 (structural lexical cue) tunnel ids proposed this pass,
    /// in lane rank order.
    public let proposedTier2IDs: [String]
    /// Tier-3 (value divergence) tunnel ids proposed this pass, in lane
    /// rank order.
    public let proposedTier3IDs: [String]
    /// Findings suppressed by the dedup contract, aggregated across all
    /// three filing tiers (live-pair suppressions + decline-matrix
    /// suppressions).
    public let suppressed: Int
    /// Proven TIER-1 findings skipped because their sensitivity ceiling
    /// exceeds Elevated. Counted apart from `suppressed`: "already on
    /// the books" and "above the ceiling" are different facts, and
    /// folding the second into the first would hide the gate's activity
    /// from anyone reading the report — including from whoever has to
    /// notice it has regressed. (The lexical lanes apply the same
    /// ceiling per-endpoint INSIDE `lexicalTierScan`, before candidates
    /// exist to count — so this counter is typed-lane-only by
    /// construction.)
    public let ceilingSkipped: Int
}

public extension GeniusLocusKit {

    /// Label prefix for typed-lane proposals; the rule@version after it
    /// is the F15 renewal key.
    static let conflictProposalLabelPrefix = "dcp: "

    /// Label prefixes for the P2.5 lexical-tier proposals; the
    /// cueKind@cueVersion after each is the renewal key (F15 mirror).
    static let tier2ProposalLabelPrefix = "tier2:"
    static let tier3ProposalLabelPrefix = "tier3:"

    /// Version of the lexical cue engine as a REJECTION-RENEWAL key
    /// (mirror of F15's rule version). Bump when `ConflictCue`'s
    /// classification meaningfully evolves: a pair rejected under
    /// cueKind@1 files a NEW instance under cueKind@2 — the new engine
    /// is new evidence. Starts at 1 (MXE-CT3 P2.5).
    static let conflictCueVersion = 1

    /// Decline-matrix tier of a withdrawn tunnel's label family, or nil
    /// when the label is outside the matrix (`hunter: …` and foreign
    /// labels — see the header's COEXISTING LABEL FAMILY note).
    internal static func rejectionTier(ofLabel label: String) -> Int? {
        if label.hasPrefix(conflictProposalLabelPrefix) { return 1 }
        if label.hasPrefix(tier2ProposalLabelPrefix) { return 2 }
        if label.hasPrefix(tier3ProposalLabelPrefix) { return 3 }
        return nil
    }

    /// The decline matrix's suppression decision for one candidate
    /// filing. Pure — unit-tested directly for every direction of the
    /// tier ordering. `withdrawnRecords` is the pair's rejected history
    /// within the three matrix label families.
    ///
    /// Rules (header: DECLINE MATRIX):
    /// - a rejection at a HIGHER tier class (numerically lower) than
    ///   the filing suppresses regardless of label — the rejected proof
    ///   damns the maybe;
    /// - a rejection at the SAME tier suppresses only the same renewal
    ///   key (F14; version bumps renew per F15);
    /// - a rejection at a LOWER tier class never suppresses.
    internal static func declineMatrixSuppresses(
        filingTier: Int,
        renewalKey: String,
        withdrawnRecords: [(tier: Int, label: String)]
    ) -> Bool {
        for record in withdrawnRecords {
            if record.tier < filingTier { return true }
            if record.tier == filingTier, record.label.hasPrefix(renewalKey) {
                return true
            }
        }
        return false
    }

    /// Run one typed sweep PLUS the shared lexical pass and file
    /// PROPOSED `contradicts` tunnels at every tier that survives the
    /// decline matrix (header: TIER-LABELED FILING). `now` is the
    /// filing instant (determinism discipline).
    ///
    /// - Parameters:
    ///   - registry: typed rule registry for the tier-1 sweep.
    ///   - modelID / probeLimit: the lexical retrieval's parameters —
    ///     same contract as `tieredContradictionSearch`.
    ///   - lexicalTopK: per-lane filing budget for tiers 2/3, clamped
    ///     by `TieredContradictionCore.effectiveTopK` and expanded by
    ///     the lane's fetch budget (2×/3×) exactly like the search
    ///     verb. 0 disables lexical filing.
    func proposeConflictTunnels(
        in handle: EstateHandle,
        registry: ConflictRuleRegistry = .v01,
        modelID: String = "minilm-v6",
        probeLimit: Int = 50,
        lexicalTopK: Int = 10,
        now: Date
    ) async throws -> ConflictTunnelProposalReport {
        let sweep = try await conflictProjectionSweep(in: handle, registry: registry)
        let estate = try estate(for: handle)

        // Dedup state: live pairs (any label family — a live claim is a
        // live claim) and the withdrawn history per pair WITHIN the
        // matrix label families (tier + full label; `hunter:` labels
        // classify nil and stay outside — see header).
        //
        // Pair keys are P2's LOWERCASE-CANONICAL `tieredPairKey` — the
        // tier-1 keys (sweep sourceDrawerIDs) and tier-2/3 keys
        // (hydrated drawer IDs) must collide regardless of how either
        // surface cased a UUID (c95910dff precedent). This dedup state
        // is built and consumed entirely inside this pass; the hunter's
        // own case-sensitive `settledPairs` set is untouched.
        var livePairs: Set<String> = []
        var withdrawnByPair: [String: [(tier: Int, label: String)]] = [:]
        for tunnel in try await estate.allTunnels() where tunnel.kind == .contradicts {
            guard let s = tunnel.sourceDrawerId, let t = tunnel.targetDrawerId else { continue }
            let pair = TieredContradictionCore.pairKey(s, t)
            switch tunnel.lifecycle {
            case .active, .proposed:
                livePairs.insert(pair)
            case .withdrawn, .superseded:
                if let tier = Self.rejectionTier(ofLabel: tunnel.label) {
                    withdrawnByPair[pair, default: []].append((tier, tunnel.label))
                }
            }
        }

        var state = ProposalFilingState(
            livePairs: livePairs, withdrawnByPair: withdrawnByPair, suppressed: 0)

        // ---- Tier 1: the typed proving sweep ----
        var proposed: [String] = []
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
            let renewalKey = "\(Self.conflictProposalLabelPrefix)\(outcome.ruleID)@\(outcome.ruleVersion)"
            let label = "\(renewalKey) result=\(outcome.resultID)"
            if let id = try await fileProposal(
                estate: estate, state: &state,
                pair: TieredContradictionCore.pairKey(a, b), a: a, b: b,
                tier: 1, renewalKey: renewalKey, label: label) {
                proposed.append(id)
            }
        }

        // ---- Tiers 2/3: the shared lexical pass (P2.5) ----
        // Same retrieval + cue screen the tiered search reads; the
        // lanes' ranked findings become reviewable proposals, capped by
        // the same 2×/3× fetch budgets the search verb applies.
        var proposedTier2: [String] = []
        var proposedTier3: [String] = []
        let effectiveK = TieredContradictionCore.effectiveTopK(lexicalTopK)
        if effectiveK > 0 {
            let scan = try await lexicalTierScan(
                in: handle, modelID: modelID, probeLimit: probeLimit)
            let tier2Findings = scan.tier2Ranked.prefix(
                TieredContradictionCore.fetchBudget(for: .lexicalStructural, topK: effectiveK))
            let tier3Findings = scan.tier3Ranked.prefix(
                TieredContradictionCore.fetchBudget(for: .lexicalValue, topK: effectiveK))
            // Tier 2 files before tier 3: a pair claimed at tier 2 this
            // pass must not also file at tier 3 (livePairs enforces).
            for finding in tier2Findings {
                let renewalKey =
                    "\(Self.tier2ProposalLabelPrefix)\(finding.cueKind ?? "")@\(Self.conflictCueVersion)"
                if let id = try await fileProposal(
                    estate: estate, state: &state,
                    pair: finding.pairKey,
                    a: finding.drawerA, b: finding.drawerB,
                    tier: 2, renewalKey: renewalKey,
                    label: "\(renewalKey) score=\(finding.score ?? 0)") {
                    proposedTier2.append(id)
                }
            }
            for finding in tier3Findings {
                let renewalKey =
                    "\(Self.tier3ProposalLabelPrefix)\(finding.cueKind ?? "")@\(Self.conflictCueVersion)"
                if let id = try await fileProposal(
                    estate: estate, state: &state,
                    pair: finding.pairKey,
                    a: finding.drawerA, b: finding.drawerB,
                    tier: 3, renewalKey: renewalKey,
                    label: "\(renewalKey) score=\(finding.score ?? 0)") {
                    proposedTier3.append(id)
                }
            }
        }

        return ConflictTunnelProposalReport(
            sweep: sweep, proposedTunnelIDs: proposed,
            proposedTier2IDs: proposedTier2, proposedTier3IDs: proposedTier3,
            suppressed: state.suppressed, ceilingSkipped: ceilingSkipped)
    }

    /// Mutable dedup state threaded through one proposal pass. A value
    /// type passed `inout` (not captured by a closure) so the pass
    /// satisfies Swift 6 region isolation across the awaits inside
    /// `fileProposal`.
    internal struct ProposalFilingState {
        /// Pairs with a live (active/proposed) claim — pre-existing OR
        /// filed earlier in THIS pass.
        var livePairs: Set<String>
        /// Withdrawn history per pair within the matrix label families.
        let withdrawnByPair: [String: [(tier: Int, label: String)]]
        /// Live-pair + decline-matrix suppressions, all tiers.
        var suppressed: Int
    }

    /// Shared filing step for every tier: decline-matrix check,
    /// endpoint resolution (never file fabricated coordinates), capture
    /// as `.proposed`. Returns the new tunnel id, or nil when the
    /// filing was suppressed or its endpoints could not resolve.
    private func fileProposal(
        estate: LocusKit.Estate,
        state: inout ProposalFilingState,
        pair: String, a: String, b: String,
        tier: Int, renewalKey: String, label: String
    ) async throws -> String? {
        if state.livePairs.contains(pair) {
            state.suppressed += 1
            return nil
        }
        if Self.declineMatrixSuppresses(
            filingTier: tier, renewalKey: renewalKey,
            withdrawnRecords: state.withdrawnByPair[pair] ?? []) {
            state.suppressed += 1
            return nil
        }
        // Endpoint coordinates from the node tree — a pair whose
        // endpoints cannot be resolved is skipped, same posture as the
        // lexical hunter (never file fabricated coordinates).
        let drawers = try await estate.hydrateBodies(ids: [a, b])
        let byID = Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) })
        guard let da = byID[a], let db = byID[b] else { return nil }
        let names = try await estate.resolveNodeNames(
            parentNodeIds: [da.parentNodeId, db.parentNodeId])
        guard let aNames = names[da.parentNodeId],
              let bNames = names[db.parentNodeId] else { return nil }
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
        // Filing order is tier 1 → 2 → 3, so inserting here also
        // suppresses same-pair filings at the lower tiers of THIS pass
        // — the claim just went on the books.
        state.livePairs.insert(pair)
        return tunnel.id
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
