// DeltaFeatureExtractor.swift
//
// Delta feature analysis per DISTILLATION_MATH_DIFFUSION.md §6.
//
// Analyzes an ordered sequence of (value, timestamp) observations for a
// single feature (REL, ENT, or NUM schema) and classifies the sequence's
// trajectory. Feeds Stage 2.5 of the distillation pipeline, which rescues
// CONVERGENT and MONOTONE features that would otherwise fail the structural
// recurrence threshold (df < 2/M).
//
// DeltaType classification:
//   STATIC      — all values identical (handled by Stage 2 majority vote)
//   CONVERGENT  — categorical sequence converges to a stable terminal value
//   MONOTONE    — numerical sequence trends monotonically (all diffs same sign)
//   OSCILLATING — period-2 pattern detected (A→B→A→B); flag as unstable
//   DIVERGENT   — no classifiable pattern; drop
//
// Used by:
//   DistillationScorer.deltaPrePass   — Stage 2.5 feature promotion
//   DISTILLATION_MATH_DIFFUSION.md   — §6 (temporal patches)
//
// Pattern: pure enum namespace, no state, no I/O. Mirrors InformationTheory.swift.

import Foundation

/// Trajectory classification for a feature's value sequence across memories.
/// Raw values are the canonical string form used in the DIST header (§1 of
/// DISTILLATION_DESIGN.md) and the DistillationOutput.deltaType field.
public enum DeltaType: String, Sendable, Codable, Equatable {
    case `static`    = "STATIC"
    case convergent  = "CONVERGENT"
    case monotone    = "MONOTONE"
    case oscillating = "OSCILLATING"
    case divergent   = "DIVERGENT"
}

/// Result of delta feature analysis for a single feature across a memory cluster.
/// terminalValue is always the most recent observation's string representation.
/// slope is non-nil only for MONOTONE classifications (average diff per step).
/// convergenceScore is C = k/M for categorical, 1.0 for MONOTONE/STATIC.
public struct DeltaAnalysis: Sendable, Equatable {
    public let deltaType: DeltaType
    /// String representation of the most recent value in the sequence.
    public let terminalValue: String
    /// C = k/M (trailing matches to terminal) for categorical; 1.0 for MONOTONE/STATIC.
    public let convergenceScore: Float32
    /// Average per-step difference; non-nil only for numerical sequences.
    public let slope: Float32?
    /// Composite confidence used by Stage 2.5 promotion logic.
    public let confidence: Float32

    public init(
        deltaType: DeltaType,
        terminalValue: String,
        convergenceScore: Float32,
        slope: Float32?,
        confidence: Float32
    ) {
        self.deltaType = deltaType
        self.terminalValue = terminalValue
        self.convergenceScore = convergenceScore
        self.slope = slope
        self.confidence = confidence
    }
}

/// Pure namespace for delta feature analysis. No stored state; all methods
/// are deterministic over their inputs. Mirrors the InformationTheory pattern.
public enum DeltaFeatureExtractor {

    // MARK: - Categorical analysis

    /// Classify the trajectory of a categorical observation sequence.
    ///
    /// Detection order (early-exit):
    ///   1. M = 1 → STATIC.
    ///   2. All values identical → STATIC.
    ///   3. Period-2 on last 4 observations → OSCILLATING.
    ///   4. C = k/M >= decayLambda → CONVERGENT.
    ///   5. Otherwise → DIVERGENT.
    ///
    /// - Parameters:
    ///   - sequence: Chronologically ordered (value, timestamp) pairs. Oldest first.
    ///   - decayLambda: Convergence threshold. Default 0.5 (half of observations
    ///     must be the terminal value for CONVERGENT classification).
    public static func analyzeCategorical(
        sequence: [(value: String, timestamp: Date)],
        decayLambda: Float32 = 0.5
    ) -> DeltaAnalysis {
        let M = sequence.count

        guard M > 1 else {
            let v = sequence.isEmpty ? "" : sequence[0].value
            return DeltaAnalysis(deltaType: .static, terminalValue: v,
                                 convergenceScore: 1.0, slope: nil, confidence: 1.0)
        }

        let terminal = sequence[M - 1].value

        // STATIC: all observations carry the same value.
        if sequence.allSatisfy({ $0.value == terminal }) {
            return DeltaAnalysis(deltaType: .static, terminalValue: terminal,
                                 convergenceScore: 1.0, slope: nil, confidence: 1.0)
        }

        // OSCILLATING: period-2 detected on the last 4 observations (A B A B pattern).
        // Requires at least 4 observations to avoid false positives on short sequences.
        if M >= 4 {
            let tail = sequence.suffix(4).map { $0.value }
            if tail[0] == tail[2] && tail[1] == tail[3] && tail[0] != tail[1] {
                return DeltaAnalysis(deltaType: .oscillating, terminalValue: terminal,
                                     convergenceScore: 0.0, slope: nil, confidence: 0.0)
            }
        }

        // Convergence score C = k/M where k is the count of consecutive trailing
        // observations equal to the terminal value.
        var k = 0
        for obs in sequence.reversed() {
            if obs.value == terminal { k += 1 } else { break }
        }
        let C = Float32(k) / Float32(M)

        if C >= decayLambda {
            return DeltaAnalysis(deltaType: .convergent, terminalValue: terminal,
                                 convergenceScore: C, slope: nil, confidence: C)
        }

        return DeltaAnalysis(deltaType: .divergent, terminalValue: terminal,
                             convergenceScore: C, slope: nil, confidence: 0.0)
    }

    // MARK: - Numerical analysis

    /// Classify the trajectory of a numerical observation sequence.
    ///
    /// Detection order (early-exit):
    ///   1. M = 1 → STATIC.
    ///   2. All diffs zero → STATIC.
    ///   3. All diffs positive or all negative → MONOTONE.
    ///   4. Diffs strictly alternate sign across all steps → OSCILLATING.
    ///   5. Otherwise → DIVERGENT.
    ///
    /// - Parameters:
    ///   - sequence: Chronologically ordered (value, timestamp) pairs. Oldest first.
    ///   - decayLambda: Confidence for a MONOTONE result. Default 0.8 reflects the
    ///     high decay rate of NUM features (DISTILLATION_MATH_DIFFUSION.md §2 table).
    public static func analyzeNumerical(
        sequence: [(value: Double, timestamp: Date)],
        decayLambda: Float32 = 0.8
    ) -> DeltaAnalysis {
        let M = sequence.count

        guard M > 1 else {
            let v = sequence.isEmpty ? 0.0 : sequence[0].value
            return DeltaAnalysis(deltaType: .static, terminalValue: String(v),
                                 convergenceScore: 1.0, slope: nil, confidence: 1.0)
        }

        let terminal = sequence[M - 1].value
        let terminalStr = String(terminal)

        // Consecutive differences: diffs[i] = seq[i+1].value - seq[i].value
        let values = sequence.map { $0.value }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }

        let posCount = diffs.filter { $0 > 0 }.count
        let negCount = diffs.filter { $0 < 0 }.count
        let slope = Float32(diffs.reduce(0, +) / Double(diffs.count))

        // STATIC: no variation across any step.
        if posCount == 0 && negCount == 0 {
            return DeltaAnalysis(deltaType: .static, terminalValue: terminalStr,
                                 convergenceScore: 1.0, slope: 0.0, confidence: 1.0)
        }

        // MONOTONE: every difference shares the same non-zero sign.
        if posCount == diffs.count || negCount == diffs.count {
            return DeltaAnalysis(deltaType: .monotone, terminalValue: terminalStr,
                                 convergenceScore: 1.0, slope: slope, confidence: decayLambda)
        }

        // OSCILLATING: sign strictly alternates across all consecutive steps.
        if diffs.count >= 2 {
            let signs = diffs.map { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
            let allAlternate = zip(signs, signs.dropFirst()).allSatisfy { $0 * $1 < 0 }
            if allAlternate {
                return DeltaAnalysis(deltaType: .oscillating, terminalValue: terminalStr,
                                     convergenceScore: 0.0, slope: slope, confidence: 0.0)
            }
        }

        return DeltaAnalysis(deltaType: .divergent, terminalValue: terminalStr,
                             convergenceScore: 0.0, slope: slope, confidence: 0.0)
    }
}
