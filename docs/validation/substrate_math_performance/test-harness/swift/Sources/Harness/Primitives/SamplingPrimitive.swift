// SamplingPrimitive.swift
//
// Sampling primitives (cookbook §8.17). Mirror of
// rust/src/primitives/sampling.rs.
//
// Wired to the production reference at
// packages/libs/SubstrateML/Sources/SubstrateML/Sampling.swift via the
// SubstrateML Swift package (the same wire-up association_rule_mining
// and formal_concept_analysis use). No glref stub — the harness calls
// the real provider so the conformance gate protects the shipping code.
//
// The three sampling primitives (Normal via Box-Muller, Gamma via
// Marsaglia-Tsang, Beta via the Gamma ratio) are RNG-derived: each
// case seeds one SplitMix64 stream and draws a fixed-length sample
// sequence. Outputs are exact IEEE-754 f64 values; cross-port
// bit-identity is the conformance gate. The algorithms use
// transcendentals (log, sqrt, cos, pow) — same regime as FFT (§8.10),
// whose cos/sin twiddles are already gated to f64 bit equality.
//
// CRITICAL — Gamma's variable RNG consumption: sampleGamma runs a
// rejection loop and (for shape < 1) a recursive reduction, so a single
// Gamma draw consumes a data-dependent number of RNG words. The whole
// point of the cross-port gate is that this consumption pattern is
// identical in Swift and Rust given the same seed and inputs. Cases
// span shape < 1, shape = 1, and shape >> 1 to exercise every branch.
//
// Input schema per case:
//   distribution : string — "normal" | "gamma" | "beta"
//   seed         : u64 LE-hex — the SplitMix64 seed for this case's stream
//   count        : u64 LE-hex — number of samples to draw from the stream
//   alpha        : f64 LE-hex — Gamma shape / Beta α (absent for normal)
//   beta         : f64 LE-hex — Beta β (present only for beta)
//
// Output schema per case:
//   samples : array of f64 LE-hex — the drawn sequence, in draw order
//
// Canonical binary encoding (alphabetical key order, single field):
//   per sample : f64 (writeF64) in draw order
//
// Cross-language bit-identity: the conformance check. JSON is the audit
// trail; CRC32 over the f64 sample sequence is the gate.

import Foundation
import SubstrateML

public enum SamplingPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "sampling",
        cookbookSection: "§8.17",
        referenceFile: "SubstrateML/Sources/SubstrateML/Sampling.swift",
        generate: generate,
        validate: validate
    )

    // The distributions and parameter grid exercised, in a fixed order
    // so case indices are stable across regenerations and across ports.
    // Each entry: (distribution, alpha?, beta?, count). alpha doubles as
    // Gamma's shape. The grid hits Gamma's three branches (shape<1,
    // shape=1, shape>1), the Box-Muller path, and Beta corner shapes.
    private struct CaseSpec {
        let distribution: String
        let alpha: Double?
        let beta: Double?
        let count: Int
    }

    private static let grid: [CaseSpec] = [
        // Normal(0,1): pure Box-Muller, fixed two-uniform consumption.
        CaseSpec(distribution: "normal", alpha: nil,  beta: nil,  count: 64),
        // Gamma shape < 1 → Ahrens-Dieter reduction branch.
        CaseSpec(distribution: "gamma",  alpha: 0.25, beta: nil,  count: 32),
        CaseSpec(distribution: "gamma",  alpha: 0.5,  beta: nil,  count: 32),
        CaseSpec(distribution: "gamma",  alpha: 0.9,  beta: nil,  count: 32),
        // Gamma shape == 1 → boundary into the Marsaglia-Tsang branch.
        CaseSpec(distribution: "gamma",  alpha: 1.0,  beta: nil,  count: 32),
        // Gamma shape > 1 → Marsaglia-Tsang squeeze/log rejection.
        CaseSpec(distribution: "gamma",  alpha: 2.0,  beta: nil,  count: 32),
        CaseSpec(distribution: "gamma",  alpha: 7.5,  beta: nil,  count: 32),
        CaseSpec(distribution: "gamma",  alpha: 50.0, beta: nil,  count: 32),
        // Beta: the bandit's actual draw. Uniform prior + skewed posteriors.
        CaseSpec(distribution: "beta",   alpha: 1.0,  beta: 1.0,  count: 32),
        CaseSpec(distribution: "beta",   alpha: 2.0,  beta: 5.0,  count: 32),
        CaseSpec(distribution: "beta",   alpha: 0.5,  beta: 0.5,  count: 32),
        CaseSpec(distribution: "beta",   alpha: 201.0, beta: 1.0, count: 32),
    ]

    // Per-case seed derivation from the generator seed. Deterministic and
    // identical in both ports (a SplitMix64 mix of the base seed and the
    // case index), so each case draws an independent but reproducible
    // stream.
    private static func caseSeed(base: UInt64, index: Int) -> UInt64 {
        // Use SubstrateML's SplitMix64 (same mixer the Rust harness uses)
        // so both ports derive identical per-case seeds.
        var rng = SubstrateML.SplitMix64(seed: base &+ UInt64(index) &* 0x9E3779B97F4A7C15)
        return rng.next()
    }

    public static func generate(seed: UInt64) throws -> VectorFile {
        var cases = [VectorFile.Case]()

        for (i, spec) in grid.enumerated() {
            let cseed = caseSeed(base: seed, index: i)
            let samples = draw(spec, seed: cseed)

            var inputs = JSONDict([
                ("distribution", .string(spec.distribution)),
                ("seed",  .string(HexCoding.u64(cseed))),
                ("count", .string(HexCoding.u64(UInt64(spec.count)))),
            ])
            if let a = spec.alpha { inputs.set("alpha", .string(HexCoding.f64(a))) }
            if let b = spec.beta  { inputs.set("beta",  .string(HexCoding.f64(b))) }

            let output = JSONDict([
                ("samples", .array(samples.map { .string(HexCoding.f64($0)) })),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: caseDescription(spec),
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "sampling",
            cookbookSection: "§8.17",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "SubstrateML/Sources/SubstrateML/Sampling.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases { caseResults.append(validateCase(c, encoder: &encoder)) }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    private static func validateCase(_ c: VectorFile.Case,
                                      encoder: inout CanonicalBinaryEncoder)
                                     -> ValidationResult.CaseResult {
        guard case .string(let dist) = c.inputs.get("distribution") ?? .null else {
            return fail(c, "missing distribution")
        }
        guard case .string(let seedHex) = c.inputs.get("seed") ?? .null,
              let cseed = parseU64Hex(seedHex) else {
            return fail(c, "missing or malformed seed")
        }
        guard case .string(let countHex) = c.inputs.get("count") ?? .null,
              let count = parseU64Hex(countHex) else {
            return fail(c, "missing or malformed count")
        }
        let alpha = parseOptF64(c.inputs.get("alpha"))
        let beta  = parseOptF64(c.inputs.get("beta"))

        let spec = CaseSpec(distribution: dist, alpha: alpha, beta: beta, count: Int(count))
        let actual = draw(spec, seed: cseed)

        guard case .array(let expArr) = c.expectedOutput.get("samples") ?? .null else {
            return fail(c, "missing expected samples")
        }
        var expected = [Double]()
        expected.reserveCapacity(expArr.count)
        for v in expArr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                return fail(c, "malformed expected sample")
            }
            expected.append(f)
        }

        if actual.count != expected.count {
            return fail(c, "sample length mismatch: \(actual.count) vs \(expected.count)")
        }

        for f in actual { encoder.writeF64(f) }

        for k in 0..<actual.count {
            if actual[k].bitPattern != expected[k].bitPattern {
                return ValidationResult.CaseResult(
                    id: c.id, passed: false,
                    diagnostic: "samples[\(k)] mismatch: expected \(HexCoding.f64(expected[k])), got \(HexCoding.f64(actual[k]))")
            }
        }
        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = output.get("samples") ?? .null else {
            fatalError("expected_output missing samples")
        }
        for v in arr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                fatalError("malformed sample element")
            }
            encoder.writeF64(f)
        }
    }

    // MARK: - Reference invocation

    /// Draw `spec.count` samples from a single SplitMix64 stream seeded
    /// at `seed`, calling the production SubstrateML.Sampling provider.
    /// The RNG is threaded across draws (never re-seeded between samples)
    /// so the full sequence shares one stream — exactly how the bandit
    /// draws one Beta per arm.
    private static func draw(_ spec: CaseSpec, seed: UInt64) -> [Double] {
        // Qualify SubstrateML.SplitMix64 explicitly: the harness exposes
        // its own Harness.SplitMix64 (used by FFT/BradleyTerry vectors),
        // but Sampling's entry points take the SubstrateML RNG type. The
        // two are bit-identical mixers; the production provider owns the
        // one the conformance gate must protect.
        var rng = SubstrateML.SplitMix64(seed: seed)
        var out = [Double]()
        out.reserveCapacity(spec.count)
        switch spec.distribution {
        case "normal":
            for _ in 0..<spec.count {
                out.append(Sampling.sampleNormal(rng: &rng))
            }
        case "gamma":
            let shape = spec.alpha ?? 1.0
            for _ in 0..<spec.count {
                out.append(Sampling.sampleGamma(shape: shape, rng: &rng))
            }
        case "beta":
            let a = spec.alpha ?? 1.0
            let b = spec.beta ?? 1.0
            for _ in 0..<spec.count {
                out.append(Sampling.sampleBeta(alpha: a, beta: b, rng: &rng))
            }
        default:
            // Unknown distribution: empty sequence. The length-mismatch
            // check in validateCase turns this into a clear failure.
            break
        }
        return out
    }

    private static func caseDescription(_ spec: CaseSpec) -> String {
        switch spec.distribution {
        case "normal": return "normal, \(spec.count) samples"
        case "gamma":  return "gamma shape=\(spec.alpha ?? 1.0), \(spec.count) samples"
        case "beta":   return "beta a=\(spec.alpha ?? 1.0) b=\(spec.beta ?? 1.0), \(spec.count) samples"
        default:       return spec.distribution
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseOptF64(_ v: JSONValue?) -> Double? {
        guard case .string(let s)? = v else { return nil }
        return parseF64Hex(s)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }

    private static func parseU64Hex(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return bits
    }
}
