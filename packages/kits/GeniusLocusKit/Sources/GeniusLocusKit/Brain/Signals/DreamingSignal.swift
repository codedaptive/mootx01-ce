import Foundation
import LocusKit

/// Dreaming daemon — architecture spec §11.2 row 1, cookbook §15
/// (the dreaming-daemon update rules).
///
/// What it does: reads the substrate's blob/JSON tier and association
/// graph and emits two emission classes:
///
/// - `propose` for mining-pattern matches and novel structural
///   alignments uncovered by cold-path rules 6–13 (weekly NMF, weekly
///   T-matrix increment, daily eigenvalue centrality, daily community
///   detection).
/// - `associate` for Hebbian weight reinforcement on the association
///   graph (cookbook §15.1 rule 9 — "Weekly T-matrix incremental
///   update from co-active rows").
///
/// What it does NOT do: write to bitmap state directly. Every emission
/// goes through the GLK-02 propose/associate verb boundary. The actual
/// substrate-level NMF and matrix work belongs to the dreaming
/// implementation that lands when the Brain layer's verb bodies ship;
/// this signal supplies the cadence and the emission shape on the
/// GLK-04 scheduler.
///
/// Cadence: weekly. Cookbook §15.2 schedules the cold-path NMF and
/// T-matrix work at a weekly cadence; that is the slowest of the
/// dreaming-daemon rules and the one that bounds the signal's
/// emission tempo.
public enum DreamingSignal {

    /// Default cadence in seconds (604 800 = 7 days). Cookbook §15.2.
    public static let defaultCadenceSeconds: TimeInterval = 604_800

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "dreaming-daemon"

    /// Build the default signal spec. The emit closure produces a
    /// mining-pattern proposal plus a representative association on
    /// every firing. Production tuning (candidate row selection,
    /// proposal density, NMF residuals) is later sub-mission territory.
    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Mining-pattern candidate: a proposal targeting the
                // substrate's dreaming queue. The actual NMF residual
                // and the row identity are computed by the cold-path
                // implementation that ships when the Brain layer's
                // verb bodies land. Until then the emission shape is
                // what the scheduler dispatches.
                let mining = ProposalFrame(
                    target: "dreaming/mining-candidate",
                    kind: .miningPattern,
                    justification:
                        "weekly NMF candidate (cookbook §15.1 rule 8); signal=\(context.signalID.rawValue)")
                // Hebbian association proposal: a co-active row pair
                // the dreaming daemon would have folded into the
                // T-matrix's incremental update (cookbook §15.1
                // rule 9 / §6.4).
                let association = AssociationFrame(
                    a: "dreaming/source",
                    b: "dreaming/target",
                    weight: 1.0)
                return [
                    .propose(mining),
                    .associate(association),
                ]
            })
    }
}
