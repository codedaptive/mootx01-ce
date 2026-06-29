// DreamingDecision.swift
//
// The DETERMINISTIC DECISION CORE of the dreaming daemon's seven-step
// tick (NEURONKIT_SPEC § 3.1 steps 3–6), factored out of `DreamingDaemon`
// so it is a pure function of pre-gathered inputs — no actor, no seam I/O,
// no clock, no `Date()`. This is the Swift side of NeuronKit's Rust-parity
// Bucket A; the Rust version at `NeuronKit/rust/src/dreaming_decision.rs`
// implements the same logic and both gate on shared fixtures.
//
// What stays in the actor: the async seam reads (dreaming queue drain,
// co-recall window accumulation, recall traces for reward, existing tunnels),
// the per-target reward reduction, the proposal emission (`sink.propose`),
// the diary write, and the across-cycle state (`consolidated`, `proposedKeys`,
// `cycleCount`).
// What moves here: every DECISION — the InfoNCE contrastive score (step 3),
// the EWC++ consolidation blend (step 4), duplicate suppression against
// existing tunnels + already-proposed keys (step 5), and the
// confidence-AND-attempts gate (step 6). The actor gathers inputs, calls
// `decide`, then enacts the result (emit proposals for the emitted
// candidates, fold the returned consolidation back into its state).
//
// Splitting decision from I/O is what makes the math portable and
// conformance-gateable while the seam-bound actor stays Swift-only.

import Foundation

/// Pure dreaming-cycle decision logic shared by the Swift `DreamingDaemon`
/// and the Rust version. Identity-free (`RowID` is its `String` alias); no
/// substrate types appear in the signatures.
public enum DreamingDecision {

    /// InfoNCE softmax temperature for the contrastive score (step 3).
    /// Matches `DreamingDaemon.temperature`.
    public static let temperature: Double = 0.2

    /// EWC++ retention factor (step 4). A consolidated confidence decays by
    /// at most this factor per barren cycle rather than being overwritten.
    /// Matches `DreamingDaemon.ewcRetention`.
    public static let ewcRetention: Float = 0.9

    /// A co-recall window drained from the dreaming queue — the identity-free
    /// projection of a dreaming queue item (no substrate dependency).
    public struct Observation: Sendable, Equatable {
        public let endpointA: String
        public let endpointB: String
        public let attempts: Int
        public let evidenceTargets: [String]
        public init(
            endpointA: String, endpointB: String,
            attempts: Int, evidenceTargets: [String]
        ) {
            self.endpointA = endpointA
            self.endpointB = endpointB
            self.attempts = attempts
            self.evidenceTargets = evidenceTargets
        }
    }

    /// A candidate the gate cleared for proposal. The actor turns each into
    /// a `ProposeFrame` (target = `endpointA`, kind `.miningPattern`, the
    /// justification embedding `confidence`).
    public struct EmittedCandidate: Sendable, Equatable {
        public let key: String
        public let endpointA: String
        public let endpointB: String
        public let attempts: Int
        public let confidence: Float
    }

    /// The cycle's decisions. `updatedConsolidated` folds the EWC++ value
    /// for every observation considered (not just the emitted ones) so the
    /// actor can replace its consolidation map wholesale.
    public struct Outcome: Sendable, Equatable {
        public let emitted: [EmittedCandidate]
        public let suppressedDuplicates: Int
        public let belowThreshold: Int
        public let scores: [String: Float]
        public let updatedConsolidated: [String: Float]
    }

    /// Canonical, order-independent key for an endpoint pair, so A↔B and
    /// B↔A collapse to one candidate. Matches `DreamingDaemon.candidateKey`.
    public static func candidateKey(_ a: String, _ b: String) -> String {
        a <= b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// InfoNCE-inspired contrastive confidence in `[0, 1]` (step 3).
    /// Positive logit = mean derived reward of the evidence targets;
    /// negative logit = `baseline` (the policy's `minSuccessRate`); two-way
    /// softmax at `temperature`. No evidence → 0. Matches
    /// `DreamingDaemon.contrastiveConfidence` bit-for-bit (Double exps
    /// narrowed to Float).
    public static func contrastiveConfidence(
        evidenceTargets: [String],
        rewardByTarget: [String: Float],
        baseline: Float
    ) -> Float {
        guard !evidenceTargets.isEmpty else { return 0 }
        var sum: Float = 0
        for target in evidenceTargets { sum += rewardByTarget[target] ?? 0 }
        let mean = sum / Float(evidenceTargets.count)
        let pos = exp(Double(mean) / temperature)
        let neg = exp(Double(baseline) / temperature)
        return Float(pos / (pos + neg))
    }

    /// Decide one dreaming cycle over pre-gathered inputs (steps 3–6).
    ///
    /// - `observations`: latent candidates, in their incoming order
    ///   (preserved through `emitted` so emission order is deterministic).
    /// - `rewardByTarget`: per-target reward (used→1, unused→0), already
    ///   reduced by the actor from the recall traces.
    /// - `existingTunnelKeys`: candidate keys of drawer-to-drawer tunnels
    ///   the substrate already records (step 5 suppression).
    /// - `alreadyProposedKeys`: keys proposed in a prior cycle (B-4
    ///   idempotency — never re-proposed).
    /// - `consolidated`: EWC++ consolidated confidence by key from prior
    ///   cycles.
    /// - `minConfidence` / `minAttempts` / `minSuccessRate`: policy gates.
    ///
    /// For each observation, in order: compute the contrastive score,
    /// blend with `consolidated[key] * ewcRetention` (keep the larger —
    /// step 4), record it; suppress if the key duplicates an existing
    /// tunnel or an already-proposed key; otherwise emit iff
    /// `effective >= minConfidence && attempts >= minAttempts`.
    public static func decide(
        observations: [Observation],
        rewardByTarget: [String: Float],
        existingTunnelKeys: Set<String>,
        alreadyProposedKeys: Set<String>,
        consolidated: [String: Float],
        minConfidence: Float,
        minAttempts: Int,
        minSuccessRate: Float
    ) -> Outcome {
        var emitted: [EmittedCandidate] = []
        var suppressedDuplicates = 0
        var belowThreshold = 0
        // Reserve up front: each grows by up to one entry per observation, and on
        // a high-traffic estate `observations` can be a large co-recall pair set
        // (bounded by the recalled set² within the drain window, not estate shape).
        // Without this, Swift's Dictionary/Set rehash-on-grow
        // (_copyOrMoveAndResize → String.hash) dominated the dreaming cycle —
        // profiled as the top CPU consumer once the ingest write path was fixed.
        // reserveCapacity changes no results (the Rust twin uses BTreeMap and
        // needs no equivalent — tree inserts never rehash).
        var scores: [String: Float] = [:]
        scores.reserveCapacity(observations.count)
        var updatedConsolidated = consolidated
        updatedConsolidated.reserveCapacity(consolidated.count + observations.count)
        // Track keys emitted THIS cycle too, so a duplicate pair within one
        // observation batch is not proposed twice (mirrors the actor
        // inserting into proposedKeys as it emits).
        var emittedKeysThisCycle: Set<String> = []
        emittedKeysThisCycle.reserveCapacity(observations.count)

        for obs in observations {
            let key = candidateKey(obs.endpointA, obs.endpointB)

            // Step 3 + 4: contrastive score, then EWC++ consolidation.
            let raw = contrastiveConfidence(
                evidenceTargets: obs.evidenceTargets,
                rewardByTarget: rewardByTarget,
                baseline: minSuccessRate)
            let retained = (updatedConsolidated[key] ?? 0) * ewcRetention
            let effective = Swift.max(raw, retained)
            updatedConsolidated[key] = effective
            scores[key] = effective

            // Step 5: suppress duplicates of existing tunnels or prior /
            // this-cycle proposals.
            if existingTunnelKeys.contains(key)
                || alreadyProposedKeys.contains(key)
                || emittedKeysThisCycle.contains(key) {
                suppressedDuplicates += 1
                continue
            }

            // Step 6: gate on confidence AND attempts.
            guard effective >= minConfidence, obs.attempts >= minAttempts else {
                belowThreshold += 1
                continue
            }
            emitted.append(EmittedCandidate(
                key: key,
                endpointA: obs.endpointA,
                endpointB: obs.endpointB,
                attempts: obs.attempts,
                confidence: effective))
            emittedKeysThisCycle.insert(key)
        }

        return Outcome(
            emitted: emitted,
            suppressedDuplicates: suppressedDuplicates,
            belowThreshold: belowThreshold,
            scores: scores,
            updatedConsolidated: updatedConsolidated)
    }
}
