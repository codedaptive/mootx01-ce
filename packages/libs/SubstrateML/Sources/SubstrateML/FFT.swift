// FFT.swift
//
// Discrete Fourier Transform and rhythm analysis per cookbook
// § 8.10 and § 11.14.
//
// The substrate uses FFT to detect periodicity in the AmbientSample
// stream: by reading a single fingerprint bit across the most
// recent N buckets, we get a binary time series whose dominant
// frequency component reveals the dominant rhythm of whatever
// signal that bit encodes. Heart-rate bits surface circadian
// patterns; calendar bits surface weekly meeting cycles; system-
// load bits on case-2 estates surface daily backup-job cycles.
//
// The reference implementation is Cooley-Tukey radix-2 decimation-
// in-time. It is O(N log N) on power-of-2 lengths and produces
// IEEE-754 Double output. The production NeuronKit implementation
// on Apple silicon routes to vDSP_fft (Accelerate framework, AMX-
// accelerated on M-series) and MUST produce bit-identical output
// to this scalar reference on the conformance test vectors.
//
// CONSTITUTIONAL: FFT input length must be a power of two. The
// cookbook's typical window (1024 samples) satisfies this. For
// non-power-of-two windows, the caller pads with zeros to the
// next power of two; the reference does not implement Bluestein's
// algorithm for arbitrary sizes (deferred until usage requires).

import Foundation
import SubstrateTypes

// MARK: - Complex number type

/// IEEE-754 Double-precision complex number. Real and imaginary
/// parts are independent Doubles. The Swift and Rust references
/// produce bit-identical output on the same Double-arithmetic
/// inputs.
public struct Complex: Hashable, Sendable {
    public var real: Double
    public var imag: Double

    @inlinable
    public init(real: Double, imag: Double) {
        self.real = real
        self.imag = imag
    }

    public static let zero = Complex(real: 0, imag: 0)

    /// Magnitude `sqrt(re² + im²)`. Used for spectrum magnitude
    /// extraction per cookbook § 8.10.
    @inlinable
    public var magnitude: Double {
        return (real * real + imag * imag).squareRoot()
    }

    /// Squared magnitude, avoiding the sqrt. Useful when only
    /// relative ordering matters (e.g., argmax).
    @inlinable
    public var magnitudeSquared: Double {
        return real * real + imag * imag
    }

    @inlinable
    public static func + (a: Complex, b: Complex) -> Complex {
        return Complex(real: a.real + b.real, imag: a.imag + b.imag)
    }

    @inlinable
    public static func - (a: Complex, b: Complex) -> Complex {
        return Complex(real: a.real - b.real, imag: a.imag - b.imag)
    }

    @inlinable
    public static func * (a: Complex, b: Complex) -> Complex {
        return Complex(
            real: a.real * b.real - a.imag * b.imag,
            imag: a.real * b.imag + a.imag * b.real
        )
    }
}

// MARK: - FFT

public enum FFT {

    /// Cooley-Tukey radix-2 decimation-in-time forward FFT.
    /// Input length must be a power of two. Output length equals
    /// input length.
    ///
    /// For real input, the spectrum is conjugate-symmetric:
    /// `spectrum[N - k] = conjugate(spectrum[k])`. The caller
    /// reads only `spectrum[0..N/2]` for the unique frequencies.
    ///
    /// Algorithm:
    ///   1. Bit-reversal permutation of the input.
    ///   2. log₂(N) butterfly stages, each combining N/2 pairs
    ///      with twiddle factors `exp(-2πi k / m)` for stage size m.
    ///
    /// Cost: O(N log N) operations, O(N) memory.
    public static func forward(real input: [Double]) -> [Complex] {
        let n = input.count
        precondition(n > 0 && (n & (n - 1)) == 0,
                     "FFT input length must be a positive power of two")

        // Step 1: bit-reverse permutation into a complex buffer.
        var buffer = [Complex](repeating: .zero, count: n)
        let bits = log2Floor(n)
        for i in 0..<n {
            let j = bitReverse(i, width: bits)
            buffer[j] = Complex(real: input[i], imag: 0)
        }

        // Step 2: butterfly stages. Stage `s` has half-size m/2
        // where m = 2^(s+1), s in 0..<bits.
        var m = 2
        while m <= n {
            let halfM = m / 2
            // Principal twiddle for this stage: exp(-2πi / m).
            let theta = -2.0 * Double.pi / Double(m)
            let wMReal = Foundation.cos(theta)
            let wMImag = Foundation.sin(theta)

            var k = 0
            while k < n {
                // Reset twiddle to w^0 = 1+0i at the start of each
                // group of `m` elements.
                var wReal = 1.0
                var wImag = 0.0
                for j in 0..<halfM {
                    let evenIdx = k + j
                    let oddIdx = k + j + halfM
                    // t = w * buffer[oddIdx]
                    let oddVal = buffer[oddIdx]
                    let tReal = wReal * oddVal.real - wImag * oddVal.imag
                    let tImag = wReal * oddVal.imag + wImag * oddVal.real
                    let evenVal = buffer[evenIdx]
                    // buffer[evenIdx] = evenVal + t
                    buffer[evenIdx] = Complex(
                        real: evenVal.real + tReal,
                        imag: evenVal.imag + tImag
                    )
                    // buffer[oddIdx] = evenVal - t
                    buffer[oddIdx] = Complex(
                        real: evenVal.real - tReal,
                        imag: evenVal.imag - tImag
                    )
                    // Advance twiddle: w *= wM
                    let newWReal = wReal * wMReal - wImag * wMImag
                    let newWImag = wReal * wMImag + wImag * wMReal
                    wReal = newWReal
                    wImag = newWImag
                }
                k += m
            }
            m *= 2
        }

        return buffer
    }

    /// Compute the magnitude spectrum of a real-input series.
    /// Returns `[magnitude(spectrum[k]) for k in 0..N]`.
    public static func magnitudeSpectrum(real input: [Double]) -> [Double] {
        return forward(real: input).map { $0.magnitude }
    }

    // MARK: - Helpers

    @usableFromInline
    static func bitReverse(_ x: Int, width: Int) -> Int {
        var v = x
        var r = 0
        for _ in 0..<width {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }

    @usableFromInline
    static func log2Floor(_ x: Int) -> Int {
        precondition(x > 0, "log2Floor undefined for non-positive")
        var v = x
        var r = 0
        while v > 1 {
            v >>= 1
            r += 1
        }
        return r
    }
}

// MARK: - Rhythm analysis (cookbook § 8.10 / § 11.14)

/// Result of rhythm analysis over a binary time series extracted
/// from one fingerprint bit across N AmbientSamples.
///
/// `dominantPeriodSeconds` is `nil` when no dominant period can
/// be identified (e.g., the series is constant or all energy
/// concentrates at DC). The cookbook recommends treating a nil
/// dominant period as "no rhythm" rather than a default value.
public struct RhythmResult: Sendable, Hashable {
    public let dominantPeriodSeconds: Double?
    public let spectralEnergy: Double
    public let windowBuckets: Int
    public let bucketDurationSeconds: Double

    public init(dominantPeriodSeconds: Double?,
                spectralEnergy: Double,
                windowBuckets: Int,
                bucketDurationSeconds: Double) {
        self.dominantPeriodSeconds = dominantPeriodSeconds
        self.spectralEnergy = spectralEnergy
        self.windowBuckets = windowBuckets
        self.bucketDurationSeconds = bucketDurationSeconds
    }
}

public enum RhythmAnalysis {

    /// Analyze rhythm from a binary time series. Input is a
    /// power-of-two length array of 0.0/1.0 values (one per
    /// AmbientSample bucket, in chronological order).
    ///
    /// `bucketDurationSeconds` is the AmbientSample bucket size
    /// (30.0 for system-30-sec buckets, 300.0 for 5-min buckets).
    ///
    /// Returns the dominant period in seconds and the total
    /// spectral energy excluding DC.
    public static func analyze(series: [Double],
                                bucketDurationSeconds: Double) -> RhythmResult {
        let n = series.count
        precondition(n > 0 && (n & (n - 1)) == 0,
                     "rhythm series length must be a positive power of two")
        precondition(bucketDurationSeconds > 0,
                     "bucket duration must be positive")

        let spectrum = FFT.forward(real: series)
        let magnitudes = spectrum.map { $0.magnitude }

        // Search the positive-frequency half excluding DC for the
        // dominant magnitude. The Nyquist bin sits at N/2; the
        // unique positive frequencies are bins 1..N/2 inclusive.
        let halfN = n / 2
        var bestBucket = 0
        var bestMag = 0.0
        for k in 1...halfN {
            if magnitudes[k] > bestMag {
                bestMag = magnitudes[k]
                bestBucket = k
            }
        }

        // Spectral energy excluding DC (bin 0).
        var energy = 0.0
        for k in 1..<n {
            energy += magnitudes[k]
        }

        // Dominant period: total span (N * bucket duration) divided
        // by dominant frequency bin. If no positive bin had energy,
        // there is no dominant period.
        let dominantPeriod: Double?
        if bestBucket == 0 || bestMag == 0.0 {
            dominantPeriod = nil
        } else {
            dominantPeriod = (Double(n) * bucketDurationSeconds) / Double(bestBucket)
        }

        return RhythmResult(
            dominantPeriodSeconds: dominantPeriod,
            spectralEnergy: energy,
            windowBuckets: n,
            bucketDurationSeconds: bucketDurationSeconds
        )
    }

    /// Extract the binary series for a given fingerprint bit
    /// position across an ordered list of AmbientSample
    /// fingerprints, then analyze. Convenience wrapper around
    /// `analyze(series:bucketDurationSeconds:)`.
    public static func analyze(fingerprints: [Fingerprint256],
                                block: Int,
                                bitPosition: Int,
                                bucketDurationSeconds: Double) -> RhythmResult {
        precondition((0..<4).contains(block),
                     "block must be 0..3")
        precondition((0..<64).contains(bitPosition),
                     "bit position within block must be 0..63")
        let absoluteBit = block * 64 + bitPosition
        let series = fingerprints.map { $0.bit(at: absoluteBit) ? 1.0 : 0.0 }
        return analyze(series: series,
                       bucketDurationSeconds: bucketDurationSeconds)
    }
}

// MARK: - Properties (informally verified)
//
//   linearity:      FFT(α·x + β·y) = α·FFT(x) + β·FFT(y)
//   conjugate sym:  real input ⇒ spectrum[N-k] = conj(spectrum[k])
//   Parseval:       sum(|x[n]|²) = (1/N) · sum(|X[k]|²)
//   pure DC input:  forward([1, 1, 1, 1]) yields [4, 0, 0, 0]
//                   (spectrum bin 0 = sum; all others zero)
//   pure tone:      a sine wave at bin k produces magnitude peak
//                   at bin k AND bin N-k (mirror); the rhythm
//                   analyzer reads the lower-half peak only.
//
// MARK: - Performance budget
//
// Cookbook § 8.10: O(N log N), ~10 µs at N=1024 on Apple Silicon.
// This scalar reference is slower (single-threaded Swift, no SIMD)
// but still completes in well under 1 ms for N=1024. Production
// vDSP_fft on M-series via Accelerate hits the budget. Conformance
// is bit-identical output, not wall-clock parity.
