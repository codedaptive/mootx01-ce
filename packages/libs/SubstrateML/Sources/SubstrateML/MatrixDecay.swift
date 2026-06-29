// MatrixDecay.swift
//
// Exponential matrix decay per cookbook § 8.13 / § 6.8.
//
// Every matrix in the substrate's matrix tier (F, C, O, T,
// ActionOutcomes, calibration, W_ranking) carries a half-life
// τ that determines how quickly past evidence loses weight.
// The decay step replaces each cell `m_ij` with:
//
//   m_ij(t + Δt) = m_ij(t) * exp(-Δt * ln(2) / τ)
//
// for elapsed time Δt since the last decay step. Decay runs as
// part of the dreaming daemon (§ 15), typically every 24h on a
// background queue.
//
// Per-matrix half-lives (cookbook § 6.8 table):
//
//   F matrix         (field-presence):      τ =  90 days
//   C matrix         (correlation):         τ = 180 days
//   O matrix         (co-activation):       τ =  60 days
//   T matrix         (temporal causality):  τ =  30 days
//   ActionOutcomes:                         τ = 365 days
//   calibration:                            τ = 730 days  (slow)
//   W_ranking:                              τ =  90 days
//
// CONSTITUTIONAL: decay is monotonic non-increasing. It cannot
// add new evidence; it can only forget. The substrate adds new
// evidence ONLY through verb operations (cookbook § 10).

import Foundation
import SubstrateTypes
import IntellectusLib

/// A square or rectangular floating-point matrix. The reference
/// implementation uses a flat row-major `[Double]` for
/// transparency; the production NeuronKit version uses Accelerate
/// vDSP or SIMD types and must produce bit-equivalent results
/// (within IEEE-754 rounding, since exp is not exact).
public struct DecayingMatrix: Sendable {
    public let rows: Int
    public let cols: Int
    public var values: [Double]
    /// Half-life in seconds.
    public let halfLifeSeconds: Double
    /// HLC physical_time (in seconds) of the last decay step.
    public var lastDecayTimeSeconds: Int64

    public init(rows: Int, cols: Int,
                halfLifeSeconds: Double,
                lastDecayTimeSeconds: Int64 = 0) {
        precondition(rows > 0 && cols > 0, "matrix dimensions must be positive")
        precondition(halfLifeSeconds > 0, "half-life must be positive")
        self.rows = rows
        self.cols = cols
        self.values = [Double](repeating: 0, count: rows * cols)
        self.halfLifeSeconds = halfLifeSeconds
        self.lastDecayTimeSeconds = lastDecayTimeSeconds
    }

    public subscript(row: Int, col: Int) -> Double {
        get { return values[row * cols + col] }
        set { values[row * cols + col] = newValue }
    }
}

public enum MatrixDecay {

    /// Apply exponential decay to every cell. `nowSeconds` is the
    /// current HLC physical_time (in seconds). If `nowSeconds <=
    /// matrix.lastDecayTimeSeconds` this is a no-op (decay never
    /// goes backward).
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals.edgeDecayedWeight` with the decay factor applied,
    /// tagged by estate, matrix dimensions, and elapsed seconds.
    /// When Δt == 0 (no-op), the emitted value is 1.0 (factor = no decay).
    /// Off-path is a single atomic-bool load.
    ///
    /// - Parameters:
    ///   - matrix: The matrix to decay in-place.
    ///   - nowSeconds: Current HLC physical_time in seconds.
    ///   - estate: Estate identifier for VizGraph telemetry.
    ///   - ts: Caller-supplied epoch seconds for telemetry.
    public static func apply(to matrix: inout DecayingMatrix,
                              nowSeconds: Int64,
                              estate: String = "",
                              ts: Double = 0) {
        let dt = Double(nowSeconds - matrix.lastDecayTimeSeconds)
        guard dt > 0 else {
            // No-op: elapsed time is zero. Emit factor = 1.0 (no decay
            // occurred) so the Topology view knows a decay check ran but
            // nothing changed. This distinguishes "daemon ran and found no
            // work" from "daemon never ran."
            Intellectus.report(.metric(
                name: VizGraphSignals.edgeDecayedWeight,
                value: 1.0,
                tags: [
                    "estate": estate,
                    "matrix_rows": "\(matrix.rows)",
                    "matrix_cols": "\(matrix.cols)",
                    "elapsed_seconds": "0",
                ],
                ts: ts
            ))
            return
        }
        let factor = exp(-dt * Double.ln2 / matrix.halfLifeSeconds)
        for i in 0..<matrix.values.count {
            matrix.values[i] *= factor
        }
        matrix.lastDecayTimeSeconds = nowSeconds

        // VizGraph emit: edge.decayed_weight — decay pass complete.
        // Value = the multiplicative factor applied to every cell
        // (0 < factor ≤ 1.0). The Topology view uses this to decide
        // whether to refresh edge-weight rendering (a factor close to 1
        // means little has changed; a factor far below 1 means the graph
        // has lost significant weight and the layout may shift).
        Intellectus.report(.metric(
            name: VizGraphSignals.edgeDecayedWeight,
            value: factor,
            tags: [
                "estate": estate,
                "matrix_rows": "\(matrix.rows)",
                "matrix_cols": "\(matrix.cols)",
                // dt is a Double derived from an Int64 subtraction, so
                // for normal wall-clock values it fits in Int64 safely.
                // However, `isFinite` alone does not guard against a very
                // large finite dt (e.g. ≥ Double(Int64.max) ≈ 9.2e18 s):
                // `Int64(dt)` traps on overflow for those inputs. The
                // combined guard (isFinite AND < Int64.max as Double)
                // produces Int64.max for pathological inputs, which is
                // correct "saturate" behaviour rather than a trap.
                "elapsed_seconds": {
                    let secs: Int64 = (dt.isFinite && dt < Double(Int64.max))
                        ? Int64(dt)
                        : Int64.max
                    return "\(secs)"
                }(),
            ],
            ts: ts
        ))
    }

    /// Compute the decay factor that would be applied for a given
    /// elapsed time and half-life. Useful for projecting "what
    /// will this matrix look like in 30 days" without mutating.
    public static func decayFactor(elapsedSeconds: Double,
                                    halfLifeSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return 1.0 }
        return exp(-elapsedSeconds * Double.ln2 / halfLifeSeconds)
    }

    /// Apply decay AND add new evidence atomically. Decay first
    /// (to current time), then add. This is the canonical pattern
    /// for online updates from the verb layer.
    public static func decayAndAdd(to matrix: inout DecayingMatrix,
                                    nowSeconds: Int64,
                                    row: Int, col: Int,
                                    increment: Double) {
        apply(to: &matrix, nowSeconds: nowSeconds)
        matrix[row, col] += increment
    }

    // MARK: - Adapter overloads used by Block 2a/2b code
    //
    // Block 2a/2b DreamingDaemon code calls
    // `MatrixDecay.applyExponentialDecay(to:halfLifeDays:atHLC:)`
    // against the concrete MatrixF / MatrixO / MatrixC types. The
    // canonical decay path lives in those types (and is exercised
    // through `DecayingMatrix` above for the reference); these
    // overloads provide the named entry point for the daemon
    // without forcing the daemon to thread `DecayingMatrix`
    // instances through its context. They no-op at the reference
    // level; production wires this to the per-matrix decay
    // routine in NeuronKit.
    public static func applyExponentialDecay(to matrix: inout MatrixF,
                                              halfLifeDays: Double,
                                              atHLC hlc: HLC) {
        _ = matrix; _ = halfLifeDays; _ = hlc
    }

    public static func applyExponentialDecay(to matrix: inout MatrixO,
                                              halfLifeDays: Double,
                                              atHLC hlc: HLC) {
        _ = matrix; _ = halfLifeDays; _ = hlc
    }

    public static func applyExponentialDecay(to matrix: inout MatrixC,
                                              halfLifeDays: Double,
                                              atHLC hlc: HLC) {
        _ = matrix; _ = halfLifeDays; _ = hlc
    }
}

extension Double {
    /// ln(2) constant for half-life math. Defined here to avoid
    /// pulling Darwin's M_LN2 macro and to match Rust's f64::LN_2.
    static let ln2: Double = 0.6931471805599453
}

// MARK: - Recommended half-lives (cookbook § 6.8 table)
//
// These constants are illustrative; the actual half-lives live in
// the manifest under `decay_half_lives.<matrix_name>` and can be
// tuned per-estate via dreaming-daemon rule 11 (cookbook § 15.11).

public enum DecayHalfLives {
    public static let fieldPresenceSeconds:      Double = 90 * 86400
    public static let correlationSeconds:        Double = 180 * 86400
    public static let coActivationSeconds:       Double = 60 * 86400
    public static let temporalCausalitySeconds:  Double = 30 * 86400
    public static let actionOutcomesSeconds:     Double = 365 * 86400
    public static let calibrationSeconds:        Double = 730 * 86400
    public static let wRankingSeconds:           Double = 90 * 86400
}

// MARK: - Properties
//
//   monotonic non-increasing: |m_ij(t+Δt)| ≤ |m_ij(t)| for Δt > 0.
//   half-life:                m_ij decays to half its value after
//                             exactly τ seconds.
//   commutes with addition:   decay(m + n) = decay(m) + decay(n)
//                             where decay is applied with same Δt.
//   idempotent at Δt=0:       apply(m, t) where t == lastDecayTime
//                             leaves m unchanged.
