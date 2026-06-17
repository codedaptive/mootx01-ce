import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The Bradley-Terry preference fit is the conformance-gated SubstrateML
// primitive surfaced through NeuronKit's `Bias` lens (`learnedPreference`,
// the anchor-reduction fitter). This producer is a CADENCE WRAPPER over that
// oracle: it shapes the estate's recall-trace reward outcomes into per-drawer
// (endorsements, dismissals) records, calls `NeuronKit.learnedPreference`, and
// caches the per-drawer preference strengths. It owns no fitting math (I-17).
//
// This is the SIBLING of GraphCentralityProducer.swift: same governor-duty
// shape, same dark→live contract, different oracle and different input graph.
// ─────────────────────────────────────────────────────────────────

/// Pre-built per-drawer learned-preference cache for one estate.
///
/// Holds the Bradley-Terry preference strength for every drawer that appears in
/// the estate's recall-trace reward history, computed by
/// `AutonomicGovernor.preferenceScan` on a cadence. Implements the GLK
/// `PreferenceStore` consumption protocol: the `matrixAware` / `unionBest`
/// recall path reads `preferenceScore(for:)` per candidate drawer to populate
/// the `preference` score column. Drawers absent from the snapshot score 0.0,
/// which is correct (a drawer never surfaced in a recall has no learned
/// preference — neutral, identical to "no store registered").
///
/// Immutable after construction — the producer builds a fresh cache each
/// cadence and re-registers it, so a registered store never mutates under a
/// concurrent recall read. `Sendable` via the immutable dictionary. Mirrors
/// `GraphCentralityCache`.
public final class PreferenceCache: PreferenceStore, Sendable {

    /// drawerID → Bradley-Terry preference strength (Float). Built once at
    /// construction.
    private let scores: [String: Float]

    /// Wrap a per-drawer preference snapshot.
    public init(scores: [String: Float]) {
        self.scores = scores
    }

    /// The preference score for `drawerID`, or 0.0 when the drawer is not in the
    /// snapshot. A pure dictionary lookup — no estate traversal, no synchronous
    /// model update, honouring the candidate-frontier-lookup-only contract
    /// (spec §15). Mirrors `GraphCentralityCache.graphScore(for:)`.
    public func preferenceScore(for drawerID: String) -> Float {
        scores[drawerID] ?? 0.0
    }

    /// Number of drawers in the snapshot. Diagnostic accessor surfaced in the
    /// producer's tick log. Mirrors `GraphCentralityCache.count`.
    public var count: Int { scores.count }
}

/// Shapes the estate's recall-trace reward outcomes into the per-drawer
/// `(label, endorsements, dismissals)` records the `NeuronKit.learnedPreference`
/// Bradley-Terry fitter consumes — the EXACT input shape its anchor reduction
/// expects. The Rust producer (`preference_outcomes` in preference_producer.rs)
/// builds the IDENTICAL record multiset so both ports feed the fitter the same
/// outcomes and obtain identical preference strengths.
public enum PreferenceOutcomes {

    /// One per-drawer Bradley-Terry curation record. `endorsements` is the count
    /// of recall traces where the drawer was surfaced AND picked (`used == true`);
    /// `dismissals` is the count where it was surfaced but passed over
    /// (`used == false`). This is the implicit relevance signal (C-15):
    /// what the user picked vs what they ignored.
    public struct Record: Sendable, Equatable {
        public let label: String
        public let endorsements: Int
        public let dismissals: Int
    }

    /// Build the per-drawer curation records from recall traces.
    ///
    /// One record per DISTINCT trace target (drawer id). A drawer surfaced N
    /// times accrues N outcomes split into endorsements (used) and dismissals
    /// (not used). Each appearance is one pairwise comparison against the neutral
    /// baseline inside the fitter's anchor reduction.
    ///
    /// Determinism: records are returned sorted ascending by label so the same
    /// trace set always yields the same record sequence — required for cross-port
    /// byte-identity of the fitter input. `learnedPreference` itself sorts its
    /// output, but the INPUT order is fixed here so the two ports submit an
    /// identical record vector. The fitter requires unique labels; grouping by
    /// target guarantees that.
    public static func build(traces: [RecallTraceItem]) -> [Record] {
        // Group by target drawer id; tally used vs not-used.
        var endorsementsByID: [String: Int] = [:]
        var dismissalsByID: [String: Int] = [:]
        for trace in traces {
            if trace.used {
                endorsementsByID[trace.target, default: 0] += 1
            } else {
                dismissalsByID[trace.target, default: 0] += 1
            }
        }
        // Distinct target set, sorted for a deterministic record sequence.
        var labels = Set(endorsementsByID.keys)
        labels.formUnion(dismissalsByID.keys)
        return labels.sorted().map { label in
            Record(label: label,
                   endorsements: endorsementsByID[label] ?? 0,
                   dismissals: dismissalsByID[label] ?? 0)
        }
    }
}
