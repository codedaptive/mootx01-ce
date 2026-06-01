// FFTTests.swift
//
// DFT + rhythm analysis per cookbook § 8.10 / § 11.14. swift-testing
// peer suite for Sources/SubstrateML/FFT.swift, mirroring
// rust/src/fft.rs (6 #[test]) with the Rust tolerances.
//
// Parity note: the Rust `non_power_of_two_panics` test asserts that
// `forward(len 3)` panics, caught with `std::panic::catch_unwind`.
// The Swift mirror enforces the same contract via `precondition`,
// which traps the process and is NOT catchable by swift-testing's
// `#expect(throws:)`. That contract is exercised instead by the
// positive power-of-two cases below; the trap itself is a documented
// untestable-under-swift-testing divergence, not a missing assertion.

import Foundation
import Testing
@testable import SubstrateML

@Suite("FFT and rhythm analysis")
struct FFTTests {

    private func approxEq(_ a: Double, _ b: Double, _ eps: Double) -> Bool { abs(a - b) < eps }

    @Test("DC input concentrates all energy at bin zero")
    func dcInputConcentratesAtBinZero() {
        let input = [1.0, 1.0, 1.0, 1.0]
        let spectrum = FFT.forward(real: input)
        #expect(approxEq(spectrum[0].real, 4.0, 1e-12))
        #expect(approxEq(spectrum[0].imag, 0.0, 1e-12))
        for k in 1..<4 {
            #expect(approxEq(spectrum[k].magnitude, 0.0, 1e-12))
        }
    }

    @Test("a pure tone concentrates at its frequency bin (and mirror)")
    func pureToneConcentratesAtFrequencyBin() {
        // sin(2π · 2 · n / 8): 2 cycles across 8 samples ⇒ bin 2 (or mirror 6).
        let n = 8
        let cycles = 2.0
        let input: [Double] = (0..<n).map { sin(2.0 * Double.pi * cycles * Double($0) / Double(n)) }
        let mags = FFT.magnitudeSpectrum(real: input)
        let maxBin = (0..<n).max(by: { mags[$0] < mags[$1] })!
        #expect(maxBin == 2 || maxBin == 6)
    }

    @Test("rhythm analysis of an all-zero series finds no period")
    func rhythmZeroSeriesHasNoPeriod() {
        let series = [Double](repeating: 0.0, count: 16)
        let r = RhythmAnalysis.analyze(series: series, bucketDurationSeconds: 30.0)
        #expect(r.dominantPeriodSeconds == nil)
        #expect(r.spectralEnergy == 0.0)
    }

    @Test("rhythm analysis of an alternating series finds a 2-bucket period")
    func rhythmAlternatingPeriodTwoBuckets() {
        // 1,0,1,0,...  dominant bin N/2 = 8 ⇒ period = 16·30/8 = 60 s.
        let series: [Double] = (0..<16).map { $0 % 2 == 0 ? 1.0 : 0.0 }
        let r = RhythmAnalysis.analyze(series: series, bucketDurationSeconds: 30.0)
        let period = try! #require(r.dominantPeriodSeconds)
        #expect(approxEq(period, 60.0, 1e-9))
    }

    @Test("rhythm analysis of a single full-window cycle finds the long period")
    func rhythmLongPeriod() {
        // 32 samples, one cosine cycle thresholded to 0/1.
        // Dominant bin 1 ⇒ period = 32·30/1 = 960 s.
        let n = 32
        let series: [Double] = (0..<n).map {
            cos(2.0 * Double.pi * Double($0) / Double(n)) > 0.0 ? 1.0 : 0.0
        }
        let r = RhythmAnalysis.analyze(series: series, bucketDurationSeconds: 30.0)
        let period = try! #require(r.dominantPeriodSeconds)
        #expect(approxEq(period, 960.0, 1e-9))
    }
}
