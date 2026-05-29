// EigenvalueCentralityPrimitive.swift
//
// Power-iteration eigenvalue centrality (cookbook §7.2) — promotes
// the `eigenvalue_centrality` reference into the conformance
// harness per the "Pending future work" entry in
// primitive-catalog.md.
//
// Wired to the real reference at
// GeniusLocusReference/glref-swift-EigenvalueCentrality.swift via
// the GeniusLocusReference Swift package.
//
// Mirror: rust/src/primitives/eigenvalue_centrality.rs
//
// Input schema:
//   n              : u32  (decimal integer)
//   edges          : array of {dst: u32, src: u32, weight: f64}
//   max_iterations : u32  (decimal integer)
//   tolerance      : f64  (16-hex IEEE-754 bit pattern, LE)
//
// Output schema:
//   centrality : array of f64
//
// Binary canonical encoding (alphabetical key order):
//   centrality : u32 LE length + N × 8 bytes f64 LE
//
// Cross-language bit-identity: this primitive uses sqrt() which is
// IEEE-754 mandated correctly-rounded across all conformant libm
// implementations (unlike exp() which has 1-ULP wiggle room). The
// inner accumulation `x_next[j] += w * x[i]` proceeds in the same
// loop order in both languages so the floating-point reduction is
// bit-identical. Convergence detection `diff_sq.sqrt() < tolerance`
// fires at the same iteration in both languages.

import Foundation
import GeniusLocusReference

public enum EigenvalueCentralityPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "eigenvalue_centrality",
        cookbookSection: "§7.2",
        referenceFile: "glref-swift-EigenvalueCentrality.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let spec = generateCaseSpec(i, rng: &rng)
            let adjacency = buildAdjacency(n: spec.n, edges: spec.edges)
            let centrality = EigenvalueCentrality.compute(
                adjacency: adjacency,
                maxIterations: spec.maxIterations,
                tolerance: spec.tolerance)

            let edgesJSON: JSONValue = .array(spec.edges.map { edge in
                .dict(JSONDict([
                    ("dst",    .integer(Int64(edge.dst))),
                    ("src",    .integer(Int64(edge.src))),
                    ("weight", .string(HexCoding.f64(edge.weight))),
                ]))
            })
            let centralityJSON: JSONValue = .array(
                centrality.map { .string(HexCoding.f64($0)) })

            let inputs = JSONDict([
                ("n",              .integer(Int64(spec.n))),
                ("edges",          edgesJSON),
                ("max_iterations", .integer(Int64(spec.maxIterations))),
                ("tolerance",      .string(HexCoding.f64(spec.tolerance))),
            ])
            let output = JSONDict([
                ("centrality", centralityJSON),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: spec.description,
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "eigenvalue_centrality",
            cookbookSection: "§7.2",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-EigenvalueCentrality.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases {
            caseResults.append(validateCase(c, encoder: &encoder))
        }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    // MARK: - Validation

    private static func validateCase(_ c: VectorFile.Case,
                                      encoder: inout CanonicalBinaryEncoder)
                                     -> ValidationResult.CaseResult {
        guard case .integer(let nI) = c.inputs.get("n") ?? .null,
              let n = Int(exactly: nI), n >= 0 else {
            return fail(c, "missing or invalid n")
        }
        guard case .integer(let maxIterI) = c.inputs.get("max_iterations") ?? .null,
              let maxIter = Int(exactly: maxIterI), maxIter > 0 else {
            return fail(c, "missing or invalid max_iterations")
        }
        guard case .string(let tolHex) = c.inputs.get("tolerance") ?? .null,
              let tolerance = parseF64Hex(tolHex) else {
            return fail(c, "missing or malformed tolerance")
        }
        guard case .array(let edgesArr) = c.inputs.get("edges") ?? .null else {
            return fail(c, "missing edges")
        }
        var edges = [(src: Int, dst: Int, weight: Double)]()
        edges.reserveCapacity(edgesArr.count)
        for e in edgesArr {
            guard case .dict(let edgeDict) = e else {
                return fail(c, "edge not a dict")
            }
            guard case .integer(let srcI) = edgeDict.get("src") ?? .null,
                  let src = Int(exactly: srcI), src >= 0, src < n else {
                return fail(c, "missing or invalid edge.src")
            }
            guard case .integer(let dstI) = edgeDict.get("dst") ?? .null,
                  let dst = Int(exactly: dstI), dst >= 0, dst < n else {
                return fail(c, "missing or invalid edge.dst")
            }
            guard case .string(let wHex) = edgeDict.get("weight") ?? .null,
                  let w = parseF64Hex(wHex) else {
                return fail(c, "missing or malformed edge.weight")
            }
            edges.append((src: src, dst: dst, weight: w))
        }

        let adjacency = buildAdjacency(n: n, edges: edges)
        let actual = EigenvalueCentrality.compute(
            adjacency: adjacency,
            maxIterations: maxIter,
            tolerance: tolerance)

        guard case .array(let expectedArr) = c.expectedOutput.get("centrality") ?? .null else {
            return fail(c, "missing expected centrality")
        }
        if expectedArr.count != n {
            return fail(c, "expected centrality length \(expectedArr.count) != n \(n)")
        }
        if actual.count != n {
            return fail(c, "computed centrality length \(actual.count) != n \(n)")
        }

        encoder.writeU32(UInt32(actual.count))
        for v in actual { encoder.writeF64(v) }

        for (idx, ev) in expectedArr.enumerated() {
            guard case .string(let s) = ev, let expected = parseF64Hex(s) else {
                return fail(c, "malformed expected centrality[\(idx)]")
            }
            if actual[idx].bitPattern != expected.bitPattern {
                return ValidationResult.CaseResult(
                    id: c.id, passed: false,
                    diagnostic: "centrality[\(idx)] mismatch: expected \(HexCoding.f64(expected)), got \(HexCoding.f64(actual[idx]))")
            }
        }
        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = output.get("centrality") ?? .null else {
            fatalError("expected_output missing centrality")
        }
        encoder.writeU32(UInt32(arr.count))
        for v in arr {
            guard case .string(let s) = v, let f = parseF64Hex(s) else {
                fatalError("malformed centrality hex")
            }
            encoder.writeF64(f)
        }
    }

    // MARK: - Adjacency construction
    //
    // Edges are processed in JSON-array order. adjacency[src]
    // receives entries in the order they appear in the edges
    // array. Both languages MUST iterate the edges array in the
    // same order to preserve the floating-point accumulation
    // order in the inner loop.

    private static func buildAdjacency(n: Int,
                                        edges: [(src: Int, dst: Int, weight: Double)])
                                       -> EigenvalueCentrality.Adjacency {
        var adj: EigenvalueCentrality.Adjacency = Array(repeating: [], count: n)
        for edge in edges {
            adj[edge.src].append((neighbor: edge.dst, weight: edge.weight))
        }
        return adj
    }

    // MARK: - Case generation
    //
    // Cases 0..3:  edge cases (empty / single / isolated / triangle)
    // Cases 4..7:  star graphs (3, 5, 7, 9 nodes) — bipartite, tests Perron shift
    // Cases 8..31: random sparse graphs from SplitMix64, sizes 4..30,
    //              edge counts ~1..4 × n, positive weights

    private struct CaseSpec {
        let n: Int
        let edges: [(src: Int, dst: Int, weight: Double)]
        let maxIterations: Int
        let tolerance: Double
        let description: String
    }

    private static func generateCaseSpec(_ i: Int, rng: inout SplitMix64) -> CaseSpec {
        switch i {
        case 0:
            return CaseSpec(n: 0, edges: [], maxIterations: 100, tolerance: 1.0e-6,
                            description: "empty graph (n=0)")
        case 1:
            return CaseSpec(n: 1,
                            edges: [(src: 0, dst: 0, weight: 1.0)],
                            maxIterations: 100, tolerance: 1.0e-6,
                            description: "single node, self-loop weight 1.0")
        case 2:
            return CaseSpec(n: 5, edges: [], maxIterations: 100, tolerance: 1.0e-6,
                            description: "isolated graph n=5 (no edges) -> uniform 1/sqrt(n)")
        case 3:
            // Symmetric triangle
            return CaseSpec(n: 3,
                            edges: [
                                (0, 1, 1.0), (1, 0, 1.0),
                                (1, 2, 1.0), (2, 1, 1.0),
                                (0, 2, 1.0), (2, 0, 1.0),
                            ],
                            maxIterations: 200, tolerance: 1.0e-9,
                            description: "symmetric triangle (3 nodes, 6 directed edges)")
        case 4...7:
            // Star graphs of increasing size: n in {3, 5, 7, 9}.
            // Symmetric: hub<->leaves.
            let n = 3 + 2 * (i - 4)
            var edges = [(src: Int, dst: Int, weight: Double)]()
            for leaf in 1..<n {
                edges.append((src: 0, dst: leaf, weight: 1.0))
                edges.append((src: leaf, dst: 0, weight: 1.0))
            }
            return CaseSpec(n: n, edges: edges,
                            maxIterations: 200, tolerance: 1.0e-9,
                            description: "symmetric star n=\(n) (hub=0, \(n-1) leaves)")
        default:
            // Random sparse graphs.
            let n = 4 + Int(rng.next() % 26)        // n in [4, 29]
            let edgeCount = max(n, n + Int(rng.next() % UInt64(3 * n))) // ~1..4 edges/node
            var edges = [(src: Int, dst: Int, weight: Double)]()
            edges.reserveCapacity(edgeCount)
            for _ in 0..<edgeCount {
                let src = Int(rng.next() % UInt64(n))
                let dst = Int(rng.next() % UInt64(n))
                let w = f64FromUInt64Pos(rng.next(), scale: 5.0) + 0.1
                edges.append((src: src, dst: dst, weight: w))
            }
            // Vary maxIter and tolerance slightly across cases.
            let maxIter = i % 3 == 0 ? 50 : (i % 3 == 1 ? 200 : 500)
            let tol = i % 4 == 0 ? 1.0e-4 : (i % 4 == 1 ? 1.0e-6 : 1.0e-9)
            return CaseSpec(n: n, edges: edges,
                            maxIterations: maxIter, tolerance: tol,
                            description: "random sparse n=\(n), edges=\(edgeCount), maxIter=\(maxIter), tol=\(tol)")
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            bits |= UInt64(b) << (i * 8)
        }
        return Double(bitPattern: bits)
    }

    /// Map u64 to positive f64 in [0, scale). Mirror of Rust's
    /// f64_from_u64_pos so RNG-derived weights match across ports.
    private static func f64FromUInt64Pos(_ raw: UInt64, scale: Double) -> Double {
        let normalized = Double(raw >> 11) / Double(1 << 53)
        return normalized * scale
    }
}
