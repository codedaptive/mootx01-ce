// AnomalyFlagSweep.swift
//
// Room-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter).
//
// Scores each drawer's mean shingle-similarity to its room peers,
// derives z-scores from the room's cohesion distribution, and
// sets/clears bit 26 (`isAnomalous`) of `operationalBitmap`.
//
// Design mirrors the cohesion math in CognitionKit's Contradiction
// recipe (ShingleSimilarity.similarity + negative-z outlier gate),
// but writes a PERSISTENT flag instead of returning a transient list.
// The sweep lives in GeniusLocusKit (not NeuronKit) because it calls
// the write primitive `Estate.setAnomalousFlag` — a LocusKit write
// that GeniusLocusKit owns as the composition layer. NeuronKit depends
// on GeniusLocusKit, so the reverse direction (GLK importing NeuronKit)
// would create a circular dependency.
//
// SubstrateML is the direct dependency for AnomalyDetection and
// ShingleSimilarity — both are already available to GeniusLocusKit
// and are conformance-gated byte-identical Swift+Rust implementations.
//
// Sweep properties:
//   • Room minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-4-shingle Jaccard to all room peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → isAnomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Complexity: O(n²) per room — acceptable on the maintenance path

import Foundation
import MootProductIdentity
import LocusKit
import OSLog
import SubstrateML

// MARK: - Anomaly sweep constants

public extension GeniusLocusKit {

    /// Minimum drawers per room to run the z-score computation (§11.18).
    ///
    /// Below this threshold, the standard deviation is either zero or
    /// statistically unstable. All drawers in under-threshold rooms
    /// have bit 26 cleared — not anomalous by definition.
    static let anomalySweepMinRoomSize: Int = 3

    /// Default z-score threshold for the negative-cohesion anomaly gate (§11.18).
    ///
    /// A drawer is flagged anomalous when its cohesion z-score ≤ −threshold.
    /// Default 2.0 balances sensitivity (catches ~2σ below-mean drawers)
    /// against false-positive rate (~2.3% under a normal distribution).
    static let anomalySweepDefaultThreshold: Float32 = 2.0
}

// MARK: - Anomaly flag sweep

extension GeniusLocusKit {

    /// Logger for the anomaly-flag sweep, fleet-standard subsystem + category.
    private static var anomalyLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
    }

    /// Compute room-cohesion z-scores and set/clear the `isAnomalous` bit
    /// (bit 26 of `operationalBitmap`) on every active drawer in the estate.
    ///
    /// For each room with ≥ `GeniusLocusKit.anomalySweepMinRoomSize` drawers:
    ///   1. Compute each drawer's mean char-4-shingle Jaccard similarity to
    ///      all OTHER drawers in the room (cohesion score) via
    ///      `ShingleSimilarity.similarity(_:_:)`.
    ///   2. Derive z-scores from the room's cohesion distribution (mean, stddev).
    ///   3. Set bit 26 on drawers whose cohesion z-score ≤ −threshold
    ///      (low-cohesion outlier); clear bit 26 on all others in the room.
    ///
    /// Rooms with fewer than `anomalySweepMinRoomSize` drawers have all members'
    /// bit 26 cleared — z-score is statistically unstable with too few peers.
    ///
    /// This is a DERIVED SIGNAL write: no audit event, no supersession cascade,
    /// no lifecycle or lineage field touched. The bit is owned entirely by this
    /// sweep and should not be set through any other path.
    ///
    /// Thread the cycle's `now` parameter for call-site determinism discipline;
    /// the write itself carries no timestamp (bit 26 is stateless).
    ///
    /// - Parameters:
    ///   - handle: The estate handle to sweep. Must be open in this kit.
    ///   - threshold: Z-score threshold; drawers with z ≤ −threshold are
    ///     flagged. Default `anomalySweepDefaultThreshold` (2.0).
    ///   - now: Caller-supplied instant (deterministic clock discipline).
    /// - Returns: Count of drawers whose bit 26 changed state.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    public func anomalyFlagSweep(
        handle: EstateHandle,
        threshold: Float32 = GeniusLocusKit.anomalySweepDefaultThreshold,
        now: Date
    ) async throws -> Int {
        let estate = try estate(for: handle)
        var changed = 0

        // Rooms-first sweep: enumerate room-level fingerprint entries,
        // then load drawers per room. Matches the subject backfill's
        // iteration pattern (SubjectBackfillCycle.swift) for consistency.
        let rooms = try await estate.roomLevelFingerprints()

        for entry in rooms {
            // Sensitivity cohort gate (codex finding 2026-08-26):
            // restricted/secret drawers are EXCLUDED from the cohesion
            // cohort entirely — they neither receive bit 26 nor influence
            // any other drawer's score. Including them let a caller without
            // a sensitivity grant plant visible probe rows and read
            // anomalous_filter results to observe lexical similarity to
            // hidden content. Excluded rows also get any stale bit 26
            // cleared, matching the small-room path's flag hygiene.
            let allDrawers = try await estate.drawersIn(wing: entry.wing, room: entry.room)
            var drawers: [Drawer] = []
            for drawer in allDrawers {
                if drawer.sensitivity == .restricted || drawer.sensitivity == .secret {
                    if drawer.isAnomalous {
                        changed += try await estate.setAnomalousFlag(
                            drawerId: drawer.id, anomalous: false, now: now)
                    }
                } else {
                    drawers.append(drawer)
                }
            }
            guard !drawers.isEmpty else { continue }

            if drawers.count < GeniusLocusKit.anomalySweepMinRoomSize {
                // Too few peers for a meaningful z-score. Clear bit 26
                // on any drawer that currently has it set. Drawers in
                // small rooms are not anomalous by definition — the room
                // has no cohesion baseline to score against.
                for drawer in drawers where drawer.isAnomalous {
                    let n = try await estate.setAnomalousFlag(
                        drawerId: drawer.id, anomalous: false, now: now)
                    changed += n
                }
                continue
            }

            // Step 1: Compute per-drawer cohesion = mean shingle-similarity
            // to all OTHER drawers in the room.
            //
            // Complexity O(n²) per room. Acceptable on the maintenance path
            // (rooms are small in practice; the sweep is rate-limited by
            // the caller's maintenance cycle). Same formula as
            // CognitionKit.Contradiction for cross-recipe result parity.
            let count = drawers.count
            var cohesion: [Float32] = Array(repeating: 0, count: count)
            for i in 0..<count {
                var sum: Float32 = 0
                for j in 0..<count where i != j {
                    // char-4-shingle Jaccard similarity; conformance-gated
                    // byte-identical across Swift and Rust legs.
                    sum += ShingleSimilarity.similarity(
                        drawers[i].content, drawers[j].content)
                }
                // (count - 1) peers; safe because count >= anomalySweepMinRoomSize (3).
                cohesion[i] = sum / Float32(count - 1)
            }

            // Step 2: Derive z-scores from the room's cohesion distribution.
            let n = Float32(count)
            let mean = cohesion.reduce(0, +) / n
            let variance = cohesion.reduce(Float32(0)) { acc, x in
                let d = x - mean
                return acc + d * d
            } / n
            let stddev = variance.squareRoot()

            // Step 3: Set/clear bit 26 on each drawer per its z-score.
            // Anomalous = low-cohesion outlier: z ≤ −threshold.
            // zScore returns 0 when stddev == 0 (all identical content) —
            // safe: threshold > 0 so no drawer is flagged in that case.
            for (idx, drawer) in drawers.enumerated() {
                let z = AnomalyDetection.zScore(
                    value: cohesion[idx], mean: mean, stddev: stddev)
                // Negative z = below-average cohesion = low-cohesion outlier.
                let shouldBeAnomalous = z <= -threshold
                // Skip write when the bit is already in the correct state;
                // avoids spurious UPDATE traffic on stable estates.
                guard drawer.isAnomalous != shouldBeAnomalous else { continue }
                let n = try await estate.setAnomalousFlag(
                    drawerId: drawer.id, anomalous: shouldBeAnomalous, now: now)
                changed += n
            }
        }

        Self.anomalyLog.debug(
            "anomalyFlagSweep: \(changed, privacy: .public) drawer(s) updated")
        return changed
    }
}
