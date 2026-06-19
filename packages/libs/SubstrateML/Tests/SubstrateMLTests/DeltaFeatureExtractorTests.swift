// DeltaFeatureExtractorTests.swift
//
// Swift Testing peer suite for Sources/SubstrateML/DeltaFeatureExtractor.swift.
//
// Covers all five DeltaType cases, both analyzeCategorical and analyzeNumerical,
// and edge cases (M=1, M=2, threshold boundary). Fixtures derived from
// DISTILLATION_MATH_DIFFUSION.md §6 and the mission test requirements.

import Testing
@testable import SubstrateML
import Foundation

@Suite("DeltaFeatureExtractor")
struct DeltaFeatureExtractorTests {

    // Reference dates — chronological order, one day apart.
    private let t0 = Date(timeIntervalSince1970: 0)
    private let t1 = Date(timeIntervalSince1970: 86_400)
    private let t2 = Date(timeIntervalSince1970: 172_800)
    private let t3 = Date(timeIntervalSince1970: 259_200)
    private let tol: Float32 = 1e-5

    // MARK: - DeltaType raw values

    @Test("DeltaType raw values match spec strings")
    func deltaTypeRawValues() {
        #expect(DeltaType.static.rawValue    == "STATIC")
        #expect(DeltaType.convergent.rawValue == "CONVERGENT")
        #expect(DeltaType.monotone.rawValue   == "MONOTONE")
        #expect(DeltaType.oscillating.rawValue == "OSCILLATING")
        #expect(DeltaType.divergent.rawValue  == "DIVERGENT")
    }

    // MARK: - analyzeCategorical — STATIC

    @Test("M=1 categorical produces STATIC with score 1.0")
    func categoricalM1IsStatic() {
        let seq = [(value: "A", timestamp: t0)]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq)
        #expect(result.deltaType == .static)
        #expect(result.terminalValue == "A")
        #expect(abs(result.convergenceScore - 1.0) < tol)
    }

    @Test("all-identical categorical sequence produces STATIC with score 1.0")
    func categoricalAllSameIsStatic() {
        let seq = [
            (value: "X", timestamp: t0),
            (value: "X", timestamp: t1),
            (value: "X", timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq)
        #expect(result.deltaType == .static)
        #expect(result.terminalValue == "X")
        #expect(abs(result.convergenceScore - 1.0) < tol)
    }

    // MARK: - analyzeCategorical — CONVERGENT

    @Test("mission fixture: A B B with λ=0.5 → CONVERGENT, score≈0.667, terminal=B")
    func categoricalConvergentFixture() {
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
            (value: "B", timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.5)
        #expect(result.deltaType == .convergent)
        #expect(result.terminalValue == "B")
        // C = k/M = 2/3 ≈ 0.667
        #expect(abs(result.convergenceScore - Float32(2.0 / 3.0)) < 1e-4)
    }

    @Test("convergence exactly at threshold is classified CONVERGENT")
    func categoricalConvergentAtThreshold() {
        // M=4, k=2 → C=0.5; λ=0.5; C >= λ → CONVERGENT
        let seq = [
            (value: "A", timestamp: t0),
            (value: "A", timestamp: t1),
            (value: "B", timestamp: t2),
            (value: "B", timestamp: t3),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.5)
        #expect(result.deltaType == .convergent)
        #expect(result.terminalValue == "B")
        #expect(abs(result.convergenceScore - 0.5) < tol)
    }

    // MARK: - analyzeCategorical — OSCILLATING

    @Test("mission fixture: A B A B → OSCILLATING")
    func categoricalOscillatingFixture() {
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
            (value: "A", timestamp: t2),
            (value: "B", timestamp: t3),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq)
        #expect(result.deltaType == .oscillating)
    }

    // MARK: - analyzeCategorical — DIVERGENT

    @Test("three distinct values with low trailing score → DIVERGENT")
    func categoricalDivergent() {
        // A B C — terminal is "C", k=1, C=1/3 < 0.5 → DIVERGENT
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
            (value: "C", timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.5)
        #expect(result.deltaType == .divergent)
        #expect(result.terminalValue == "C")
    }

    @Test("below-threshold convergence with higher λ → DIVERGENT")
    func categoricalBelowLambdaIsDivergent() {
        // A B B → C = 2/3 but λ = 0.9 → DIVERGENT
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
            (value: "B", timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.9)
        #expect(result.deltaType == .divergent)
    }

    // MARK: - analyzeNumerical — STATIC

    @Test("M=1 numerical produces STATIC")
    func numericalM1IsStatic() {
        let seq = [(value: 42.0, timestamp: t0)]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq)
        #expect(result.deltaType == .static)
    }

    @Test("all-identical numerical sequence produces STATIC with slope 0")
    func numericalAllSameIsStatic() {
        let seq = [
            (value: 5.0, timestamp: t0),
            (value: 5.0, timestamp: t1),
            (value: 5.0, timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq)
        #expect(result.deltaType == .static)
        #expect(result.slope.map { abs($0) < tol } ?? false)
    }

    // MARK: - analyzeNumerical — MONOTONE

    @Test("mission fixture: 1 2 3 with λ=0.8 → MONOTONE, slope=1.0")
    func numericalMonotoneFixture() {
        let seq = [
            (value: 1.0, timestamp: t0),
            (value: 2.0, timestamp: t1),
            (value: 3.0, timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq, decayLambda: 0.8)
        #expect(result.deltaType == .monotone)
        #expect(abs((result.slope ?? -1) - 1.0) < tol)
        #expect(abs(result.confidence - 0.8) < tol)
    }

    @Test("strictly decreasing sequence → MONOTONE with negative slope")
    func numericalMonotoneDecreasing() {
        let seq = [
            (value: 10.0, timestamp: t0),
            (value: 7.0,  timestamp: t1),
            (value: 4.0,  timestamp: t2),
            (value: 1.0,  timestamp: t3),
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq)
        #expect(result.deltaType == .monotone)
        #expect((result.slope ?? 0) < 0)
    }

    // MARK: - analyzeNumerical — OSCILLATING

    @Test("alternating up/down numerical sequence → OSCILLATING")
    func numericalOscillating() {
        // diffs: +2, -2, +2 — strictly alternating
        let seq = [
            (value: 1.0, timestamp: t0),
            (value: 3.0, timestamp: t1),
            (value: 1.0, timestamp: t2),
            (value: 3.0, timestamp: t3),
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq)
        #expect(result.deltaType == .oscillating)
    }

    // MARK: - analyzeNumerical — DIVERGENT

    @Test("mixed-sign non-alternating numerical sequence → DIVERGENT")
    func numericalDivergent() {
        // diffs: +1, +1, -3 — not all same sign and not purely alternating
        let seq = [
            (value: 1.0, timestamp: t0),
            (value: 2.0, timestamp: t1),
            (value: 3.0, timestamp: t2),
            (value: 0.0, timestamp: t3),
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: seq)
        #expect(result.deltaType == .divergent)
    }

    // MARK: - DeltaAnalysis struct

    @Test("DeltaAnalysis Equatable: same parameters produce equal values")
    func deltaAnalysisEquatable() {
        let a = DeltaAnalysis(deltaType: .convergent, terminalValue: "B",
                              convergenceScore: 0.667, slope: nil, confidence: 0.667)
        let b = DeltaAnalysis(deltaType: .convergent, terminalValue: "B",
                              convergenceScore: 0.667, slope: nil, confidence: 0.667)
        #expect(a == b)
    }

    @Test("DeltaAnalysis Equatable: differing deltaType produces inequality")
    func deltaAnalysisNotEqual() {
        let a = DeltaAnalysis(deltaType: .convergent, terminalValue: "B",
                              convergenceScore: 0.667, slope: nil, confidence: 0.667)
        let b = DeltaAnalysis(deltaType: .static, terminalValue: "B",
                              convergenceScore: 0.667, slope: nil, confidence: 0.667)
        #expect(a != b)
    }

    // MARK: - Edge cases

    @Test("empty categorical sequence returns STATIC with empty terminal")
    func categoricalEmptySequence() {
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: [])
        #expect(result.deltaType == .static)
        #expect(result.terminalValue == "")
    }

    @Test("empty numerical sequence returns STATIC")
    func numericalEmptySequence() {
        let result = DeltaFeatureExtractor.analyzeNumerical(sequence: [])
        #expect(result.deltaType == .static)
    }

    @Test("M=2 categorical at threshold: C=0.5 == λ=0.5 → CONVERGENT (>= is inclusive)")
    func categoricalM2AtThresholdIsConvergent() {
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
        ]
        // k=1, M=2, C=0.5; λ=0.5; C >= λ → CONVERGENT (boundary is inclusive).
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.5)
        #expect(result.deltaType == .convergent)
        #expect(result.terminalValue == "B")
        #expect(abs(result.convergenceScore - 0.5) < tol)
    }

    @Test("M=3 A B A is not OSCILLATING (period-2 check requires M>=4)")
    func categoricalM3AlternatingShorter() {
        // A B A — M=3, period-2 check skipped; k=1, C=1/3 < 0.5 → DIVERGENT
        let seq = [
            (value: "A", timestamp: t0),
            (value: "B", timestamp: t1),
            (value: "A", timestamp: t2),
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(sequence: seq, decayLambda: 0.5)
        #expect(result.deltaType == .divergent)
    }
}
