// CalibrationReads.swift
//
// Calibration curve read and outcome-record write (dormant-surfaces
// mission, Part 4).
//
// Exposes two methods on GeniusLocusKit's estate surface:
//
//   glkCalibrationCurve(for:modelID:)
//     Returns the persisted 20-bucket calibration curve for one model.
//     Returns nil if no observations have been recorded for the model yet.
//
//   glkRecordCalibrationOutcome(for:modelID:claimedConfidence:succeeded:at:)
//     Records one LLM prediction outcome. Applies 30-day-half-life decay
//     lazily (math treatise §8) before recording, so old observations lose
//     influence proportionally to elapsed time without a scheduled sweep.
//     If a MatrixPersistenceBackend is registered for the estate, saves
//     a MatrixSnapshot (tier + calibration) after each update.
//
//   registerMatrixPersistence(_:for:)
//     Wires a MatrixPersistenceBackend to the estate so calibration
//     (and tier) snapshots survive process restarts. The backend is
//     loaded on registration to seed the in-memory registry from any
//     prior snapshot.
//
// Persistence pattern:
//   MatrixSnapshot already contains both `tier: MatrixTier` and
//   `calibration: MatrixCalibrationRegistry`. When a backend is
//   registered, `glkRecordCalibrationOutcome` builds a fresh snapshot
//   from `matrixTiers[handle]` (if registered) and the updated
//   `calibrationRegistries[handle]`, then calls `backend.save`.
//   If no tier is registered, the snapshot carries a zero-initialised
//   MatrixTier — correct for a calibration-only write path.

import Foundation

public extension GeniusLocusKit {

    /// Returns the calibration curve for `modelID` in `handle`'s estate,
    /// or `nil` if no observations have been recorded for that model.
    ///
    /// The curve's twenty buckets map claimed confidence bands (0.05 wide)
    /// to empirical success rates. A bucket with `count == 0` has no
    /// evidence; callers should pass the claimed value through unchanged
    /// for such buckets (which `MatrixCalibrationCurve.calibrate` does).
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - modelID: Stable model identifier (e.g. "anthropic.claude-opus-4-8").
    /// - Returns: The 20-bucket curve, or `nil` if the model is unknown.
    /// - Throws: `.estateNotOpen` if the handle is not in the registry.
    func glkCalibrationCurve(
        for handle: EstateHandle,
        modelID: String
    ) async throws -> MatrixCalibrationCurve? {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return calibrationRegistries[handle]?.curves[modelID]
    }

    /// Record one LLM prediction outcome against the calibration curve.
    ///
    /// Applies lazy multiplicative decay (30-day half-life, math §8) to
    /// the model's bucket counts before recording, so observations from
    /// a month ago carry half the weight of fresh ones. After recording,
    /// if a `MatrixPersistenceBackend` is registered for `handle`, saves
    /// a `MatrixSnapshot` containing both the matrix tier and the updated
    /// calibration registry.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - modelID: Stable model identifier.
    ///   - claimedConfidence: The model's confidence in `[0, 1)`.
    ///   - succeeded: Whether the prediction was correct.
    ///   - now: Current date (caller-supplied for determinism — never call
    ///     `Date()` inside the substrate).
    /// - Throws: `.estateNotOpen`, or underlying persistence errors.
    func glkRecordCalibrationOutcome(
        for handle: EstateHandle,
        modelID: String,
        claimedConfidence: Float,
        succeeded: Bool,
        at now: Date
    ) async throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }

        let outcome: MatrixCalibrationOutcome = succeeded ? .success : .failure
        var registry = calibrationRegistries[handle] ?? MatrixCalibrationRegistry()
        registry.recordWithDecay(
            modelID: modelID,
            claimedConfidence: claimedConfidence,
            outcome: outcome,
            now: now
        )
        calibrationRegistries[handle] = registry

        // Persist the updated snapshot if a backend is wired.
        if let backend = matrixPersistenceBackends[handle] {
            let tier = matrixTiers[handle] ?? MatrixTier()
            let snapshot = MatrixSnapshot(
                tier: tier,
                calibration: registry,
                hlcWatermark: tier.lastHLC
            )
            try backend.save(snapshot)
        }
    }

    /// Wire a `MatrixPersistenceBackend` to `handle`'s estate.
    ///
    /// Call this after `open(_:)` and alongside `registerMatrixTier(_:for:)`
    /// to enable calibration persistence. On registration, any existing
    /// snapshot is loaded and its calibration registry is used to seed the
    /// in-memory `calibrationRegistries[handle]` entry — restoring prior
    /// observations across restarts.
    ///
    /// If the snapshot carries no calibration data (pre-decay-feature
    /// snapshot), the in-memory registry starts empty and observations
    /// accumulate from scratch (correct — no history to restore).
    ///
    /// - Parameters:
    ///   - backend: Configured persistence backend (`.inMemory` or
    ///     `.snapshotted(file:)`).
    ///   - handle: Open estate handle.
    /// - Throws: `.estateNotOpen` if the handle is not in the registry;
    ///   underlying persistence errors on snapshot load failure.
    func registerMatrixPersistence(
        _ backend: MatrixPersistenceBackend,
        for handle: EstateHandle
    ) async throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        matrixPersistenceBackends[handle] = backend

        // Seed the in-memory calibration registry from the existing snapshot.
        if let snapshot = try? backend.load() {
            calibrationRegistries[handle] = snapshot.calibration
            // Also restore the matrix tier if none is registered yet, so the
            // tier and calibration remain in sync after a restart.
            if matrixTiers[handle] == nil {
                matrixTiers[handle] = snapshot.tier
            }
        }
    }
}
