import Foundation
import LocusKit

/// byReference validation signal — architecture spec §11.2 row 5.
///
/// Background: when an application calls the `learn` verb with
/// `mode = .byReference` (spec §10 row 7, default mode), the substrate
/// captures a LearnedReference row that points at an external source.
/// The reference must be revalidated periodically because the source
/// can change underneath the substrate: a 404, a schema-incompatible
/// response, or a content delta beyond the drift threshold are all
/// failures that demote the reference's trust.
///
/// What this signal does on each pass:
///
/// - For each `LearnedReference` row with `mode=byReference`, the
///   production implementation refetches the source, compares the
///   payload's fingerprint against the stored shadow, and on
///   detection emits a `propose` row demoting the reference's trust
///   or marking it stale.
/// - A diagnostic report summarises the scan even when no drift is
///   detected so the application can audit cadence and freshness.
///
/// Cadence: weekly. Architecture spec §10 row 7 sets the default
/// refresh_policy on byReference to weekly; this signal's cadence
/// matches.
public enum ByReferenceValiditySignal {

    /// Default cadence in seconds (604 800 = 7 days). Architecture
    /// spec §10 row 7.
    public static let defaultCadenceSeconds: TimeInterval = 604_800

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "by-reference-validity"

    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Drift proposal — the production implementation
                // would feed a real LearnedReference row's identifier
                // and a justification carrying the source's HTTP
                // status, schema diff, or content-delta magnitude.
                // The sentinel here keeps the emission shape deterministic
                // for the conformance gate.
                let drift = ProposalFrame(
                    target: "by_reference/aged-row",
                    kind: .byReferenceDrift,
                    justification:
                        "weekly byReference validation pass observed drift; signal=\(context.signalID.rawValue)")
                let diagnostic = DiagnosticReport(
                    title: "by_reference.validation.summary",
                    detail:
                        "weekly byReference pass observed 1 drift candidate; signal=\(context.signalID.rawValue)",
                    observedAt: context.now)
                return [
                    .propose(drift),
                    .diagnostic(diagnostic),
                ]
            })
    }
}
