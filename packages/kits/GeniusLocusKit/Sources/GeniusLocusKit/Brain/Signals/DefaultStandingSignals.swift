import Foundation
import LocusKit
import VectorKit

/// Registration helper for the seven v1 standing signals — architecture
/// spec §11.2.
///
/// Calling `registerDefaultStandingSignals(in:now:)` registers all
/// seven default signal specs against the addressed estate's scheduler
/// at their architecture-spec cadences. The returned dictionary maps
/// each signal's stable name to its freshly-minted `SignalID` so the
/// application can subscribe, inspect, or unregister selectively.
///
/// Order of registration is fixed and stable: the dictionary's keys
/// are the signal-name constants from each signal file. The scheduler
/// itself orders dispatch by `SignalID.rawValue`, so registration
/// order is a property of this helper rather than of the scheduler.
///
/// Signal 7 (TemporalCausalitySignal) was added 2026-06-04 per
/// DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md, superseding the
/// weekly cadence in cookbook §6.4. It is registered using
/// `defaultSpec()` (diagnostic no-op); production callers wire a live
/// fold closure via `TemporalCausalitySignal.spec(foldCycle:)`.
public extension GeniusLocusKit {

    /// Names of the seven v1 standing signals, in the order they are
    /// registered by `registerDefaultStandingSignals`. Exposed as a
    /// stable array so tests and diagnostics can assert against the
    /// vocabulary without hard-coding string literals.
    static var defaultStandingSignalNames: [String] {
        [
            DreamingSignal.signalName,
            MaintenanceSignal.signalName,
            VectorSimilaritySignal.signalName,
            DecaySweepSignal.signalName,
            ByReferenceValiditySignal.signalName,
            EndOfDayTournamentSignal.signalName,
            TemporalCausalitySignal.signalName,
        ]
    }

    /// Register every architecture-spec §11.2 standing signal against
    /// the addressed estate's scheduler at its default cadence.
    ///
    /// - Parameters:
    ///   - handle: the estate to register against. Must be an open
    ///     handle in `handles`.
    ///   - vectorStore: the estate's `VectorStore`, passed to
    ///     `VectorSimilaritySignal.spec(vectorStore:modelID:)` so the
    ///     signal can query real row embeddings on each fire.
    ///   - dreamingCycle: the daemon cycle closure forwarded to
    ///     `DreamingSignal.spec(daemonCycle:)`. The caller constructs a
    ///     `DreamingDaemon` (NeuronKit) with production adapters and wraps
    ///     `daemon.triggerDreamingCycle(now:).proposalsEmitted` here.
    ///     Defaults to a no-op that returns zero proposals — correct for
    ///     test registration where no live daemon is available.
    ///   - modelID: the embedding model whose stored vectors are scanned
    ///     by the vector-similarity signal. Default `"minilm-v6"`.
    ///   - now: the deterministic clock — flowed through to the
    ///     scheduler's registration so interval triggers schedule
    ///     their first run relative to a known time.
    /// - Returns: a name → SignalID map, one entry per signal.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   not in the registry.
    @discardableResult
    func registerDefaultStandingSignals(
        in handle: EstateHandle,
        vectorStore: VectorStore,
        dreamingCycle: @escaping @Sendable (Date) async throws -> [ProposeFrame] = { _ in [] },
        modelID: String = "minilm-v6",
        now: Date
    ) async throws -> [String: SignalID] {
        let specs: [SignalSpec] = [
            DreamingSignal.spec(daemonCycle: dreamingCycle),
            MaintenanceSignal.defaultSpec(),
            VectorSimilaritySignal.spec(vectorStore: vectorStore, modelID: modelID),
            DecaySweepSignal.defaultSpec(),
            ByReferenceValiditySignal.defaultSpec(),
            EndOfDayTournamentSignal.defaultSpec(),
            // TemporalCausalitySignal registered with its diagnostic no-op
            // spec. Production callers replace this with
            // TemporalCausalitySignal.spec(foldCycle:) to wire a live fold
            // closure. The default is appropriate here because
            // registerDefaultStandingSignals cannot supply estate-specific
            // context (audit log, mutable MatrixTier) without breaking the
            // method's generic signature.
            TemporalCausalitySignal.defaultSpec(),
        ]
        var registered: [String: SignalID] = [:]
        for spec in specs {
            let id = try await registerStandingSignal(spec, in: handle, now: now)
            registered[spec.name] = id
        }
        return registered
    }
}
