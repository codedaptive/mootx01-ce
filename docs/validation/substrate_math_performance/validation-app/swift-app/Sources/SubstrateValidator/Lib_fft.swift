// Lib_fft.swift
//
// Lib-side conformance CRC for the `fft` primitive (cookbook §8.10).
// Computes the canonical CRC by calling the SHIPPING lib
// (SubstrateML.FFT.magnitudeSpectrum), not the glref reference, so the
// validator can report lib-vs-glref drift on the magnitude-spectrum
// wire encoding.
//
// Byte mechanism mirrors Harness FFTPrimitive.validateCase exactly
// (its CRC-accumulation path): for each case, decode the `signal`
// array of f64 hex bit-patterns, call FFT.magnitudeSpectrum(real:),
// then emit one `encoder.writeF64(v)` per spectrum element. There is
// NO length prefix on the spectrum — the harness accumulates the f64
// bit patterns directly, back to back, across all cases in case order.
// CRC32 over the accumulated bytes must equal the committed outputCrc32.
//
// Input schema (per case):
//   signal : array of f64 (each a 16-hex IEEE-754 bit pattern, LE);
//            length is a power of two (the generator cycles 4/8/16/32).
//
// Output (per case, accumulated into the shared encoder):
//   spectrum : N × 8-byte f64 LE (IEEE-754 bit pattern), NO u32 prefix.
//              N equals the signal length; each value is the magnitude
//              sqrt(re² + im²) of the corresponding FFT bin.
//
// Complex construction: this primitive's reference output is a REAL
// magnitude spectrum, not interleaved complex pairs. FFT.forward builds
// each input as Complex(real: signal[i], imag: 0) internally, runs the
// Cooley-Tukey radix-2 butterflies, and magnitudeSpectrum maps each bin
// to Complex.magnitude. So there is no real/imag write order to mirror
// at the wire level — only one f64 magnitude per bin. The trig (cos/sin
// twiddle factors) lives inside FFT.forward; magnitude uses
// .squareRoot() (IEEE-754 correctly-rounded), so output is bit-identical
// to the harness given the same libm. No SubstrateKernel symbols are
// referenced, so there is no kernel/protocol module ambiguity here.
//
// Shipping-vs-glref API note: SubstrateML.FFT and the glref reference
// (glref-swift-FFT.swift) are identical here — same enum name `FFT`,
// same `magnitudeSpectrum(real:) -> [Double]` signature, same `Complex`
// type, same radix-2 decimation-in-time algorithm with bit-reverse
// permutation. No glref-vs-shipping drift in the type surface; this lib
// path exercises the shipping module so any future divergence surfaces
// as a CRC mismatch.

import Foundation
import Harness
import SubstrateML

enum Lib_fft {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- signal: array of 16-hex f64 bit patterns (LE) ---
            guard case .array(let arr) = c.inputs.get("signal") ?? .null
            else { continue }

            var signal = [Double]()
            signal.reserveCapacity(arr.count)
            var malformed = false
            for v in arr {
                guard case .string(let s) = v, let f = fftParseF64Hex(s)
                else { malformed = true; break }
                signal.append(f)
            }
            if malformed { continue }

            // Shipping magnitude spectrum: real-input Cooley-Tukey FFT,
            // then per-bin magnitude. Output length equals signal length.
            let spectrum = FFT.magnitudeSpectrum(real: signal)

            // Canonical encoding: one f64 LE (IEEE-754 bit pattern) per
            // spectrum element, NO length prefix — exactly the harness
            // FFTPrimitive.validateCase accumulation path.
            for f in spectrum { enc.writeF64(f) }
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, fft-prefixed to avoid cross-file collisions)

    /// Decode an 8-byte little-endian f64 from its hex bit-pattern string.
    /// Mirrors the harness `parseF64Hex`: byte i contributes bits
    /// [i*8, i*8+8) of the IEEE-754 bit pattern.
    private static func fftParseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }
}
