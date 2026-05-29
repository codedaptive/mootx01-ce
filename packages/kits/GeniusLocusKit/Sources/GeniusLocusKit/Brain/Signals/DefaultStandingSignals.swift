import Foundation
import LocusKit

/// Registration helper for the six v1 standing signals — architecture
/// spec §11.2.
///
/// Calling `registerDefaultStandingSignals(in:now:)` registers all
/// six default signal specs against the addressed estate's scheduler
/// at their architecture-spec cadences. The returned dictionary maps
/// each signal's stable name to its freshly-minted `SignalID` so the
/// application can subscribe, inspect, or unregister selectively.
///
/// Order of registration is fixed and stable: the dictionary's keys
/// are the signal-name constants from each signal file. The scheduler
/// itself orders dispatch by `SignalID.rawValue`, so registration
/// order is a property of this helper rather than of the scheduler.
public extension GeniusLocusKit {

    /// Names of the six v1 standing signals, in the order they are
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
        ]
    }

    /// Register every architecture-spec §11.2 standing signal against
    /// the addressed estate's scheduler at its default cadence.
    ///
    /// - Parameters:
    ///   - handle: the estate to register against. Must be an open
    ///     handle in `handles`.
    ///   - now: the deterministic clock — flowed through to the
    ///     scheduler's registration so interval triggers schedule
    ///     their first run relative to a known time.
    /// - Returns: a name → SignalID map, one entry per signal.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   not in the registry.
    @discardableResult
    func registerDefaultStandingSignals(
        in handle: EstateHandle,
        now: Date
    ) async throws -> [String: SignalID] {
        let specs: [SignalSpec] = [
            DreamingSignal.defaultSpec(),
            MaintenanceSignal.defaultSpec(),
            VectorSimilaritySignal.defaultSpec(),
            DecaySweepSignal.defaultSpec(),
            ByReferenceValiditySignal.defaultSpec(),
            EndOfDayTournamentSignal.defaultSpec(),
        ]
        var registered: [String: SignalID] = [:]
        for spec in specs {
            let id = try await registerStandingSignal(spec, in: handle, now: now)
            registered[spec.name] = id
        }
        return registered
    }
}
