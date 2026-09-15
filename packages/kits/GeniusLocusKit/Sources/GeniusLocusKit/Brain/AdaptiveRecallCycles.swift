import Foundation

/// Adaptive-recall standing-signal cycles: the hourly temporal-causality
/// fold (architecture spec §11.2, row 7) and the hourly training-daemon
/// tick (row 9). The resident wraps these two methods as the `foldCycle:`
/// and `trainingCycle:` closures of `registerDefaultStandingSignals` while
/// the estate's `.adaptiveRecall` preference is not `.off`; an opted-out
/// estate never schedules either signal.
public extension GeniusLocusKit {

    /// Hourly fold of the new audit-log tail into the temporal causality
    /// matrix. Rebuilds the derived accelerators from the log the same way
    /// estate open does: the persisted matrix snapshot is loaded and folded
    /// forward over the audit tail past its watermark, then re-persisted, so
    /// the `matrixAware` recall lane reads a tier that includes every
    /// capture since the previous fire.
    ///
    /// - Parameters:
    ///   - handle: the estate to fold. Must be an open handle in `handles`.
    ///   - now: the scheduler's deterministic clock, used as the snapshot's
    ///     persist timestamp.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is not in
    ///   the registry; any storage-tier error surfaced by the rebuild.
    func runTemporalCausalityFold(_ handle: EstateHandle, now: Date) async throws {
        try await rebuildDerivedAccelerators(for: handle, now: now)
    }

    /// One training-daemon tick over the kit's matrix tier and calibration
    /// registry for `handle`.
    ///
    /// Runs `TrainingDaemon.runOnce` against the estate's current audit log.
    /// The daemon is minted per tick with the default threshold gate, so its
    /// watermark starts at `.zero` and an active tick folds the full log;
    /// the gate keeps the tick dormant (no matrix work) until the estate has
    /// crossed the transition threshold. The updated tier and calibration
    /// registry are written back to the kit's per-estate maps so the
    /// `matrixAware` recall lane and the calibration reads see the result.
    ///
    /// - Parameters:
    ///   - handle: the estate to train. Must be an open handle in `handles`.
    ///   - now: the scheduler's deterministic clock; carried for the caller's
    ///     diagnostic and not consumed by the daemon, whose ordering keys off
    ///     audit HLCs.
    /// - Returns: a one-line summary of the tick (gate state, transition
    ///   count against threshold, transitions considered, cells touched) for
    ///   the signal's diagnostic emission.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is not in
    ///   the registry; any storage-tier error surfaced by `auditLog(for:)`.
    func runTrainingTick(_ handle: EstateHandle, now: Date) async throws -> String {
        let log = try await auditLog(for: handle)
        var tier = matrixTiers[handle] ?? MatrixTier()
        var calibration = calibrationRegistries[handle] ?? MatrixCalibrationRegistry()
        let daemon = TrainingDaemon()
        let tick = await daemon.runOnce(log: log, tier: &tier, calibration: &calibration)
        matrixTiers[handle] = tier
        calibrationRegistries[handle] = calibration
        let state = tick.decision.isActive ? "active" : "dormant"
        return "training tick \(state): transitions \(tick.decision.transitionCount)/\(tick.decision.threshold), "
            + "considered \(tick.passResult.transitionsConsidered), "
            + "F cells \(tick.passResult.fCellsTouched), O keys \(tick.passResult.oKeysTouched), "
            + "T keys \(tick.passResult.tKeysTouched), "
            + "calibration observations \(tick.passResult.calibrationObservationsRecorded) "
            + "at \(now.ISO8601Format())"
    }
}
