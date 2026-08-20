// QIDAdjacencyPrimitive.swift
//
// Q-ID adjacency (Wikidata graph) distance — the Q-ID half of
// cookbook §8.3 lattice distance, ruled a canonical primitive
// 2026-08-20 (S8 wave: live on the precise/temporal doors through
// NeuronKit's QIDClosure-backed provider). Mirror of
// rust/src/primitives/qid_adjacency.rs.
//
// Wired to the PRODUCTION reference at
// packages/libs/SubstrateML/Sources/SubstrateML/LatticeDistance.swift
// (`WikidataGraphDistance.shortestPathLength` / `.distance`) via the
// SubstrateML package. Each case carries its OWN adjacency graph in
// the inputs, so the vectors gate the §8.3 math — depth-4 BFS,
// 1 − exp(−len/3) normalization, null-Q-ID and unreachable → 1.0 —
// independent of the vendored QIDClosure artifact. (The pinned
// artifact is provenance-stamped and golden-pinned in LatticeLib;
// the production glue mapping "Q<n>" strings to these integer Q-IDs
// is NeuronKit's QIDClosureAdjacency.)
//
// Input schema (34 cases):
//   a     : u64 hex (integer Q-ID; 0 = null Q-ID)
//   b     : u64 hex
//   edges : { "<u64 hex>": [<u64 hex>, ...] } — undirected adjacency
//           (both directions present, matching the production
//           closure's parent+child neighbor set); values sorted
//           numerically, keys lex-sorted (fixed-width hex ⇒ numeric).
//
// Case construction cycles i % 4 over 32 seeded cases (random
// connected tree + extra edges, symmetrized):
//   0 : independent random pair       (typical interior path)
//   1 : b = a                         (identical -> path 0, 0.0)
//   2 : a = 0                         (null Q-ID -> sentinel, 1.0)
//   3 : b = isolated node             (unreachable -> sentinel, 1.0)
// plus two fixed cases: case_032 direct neighbors (path 1),
// case_033 a 6-chain whose ends are 5 apart — beyond the depth-4
// budget, pinning maxDepth (unreachable -> sentinel, 1.0).
//
// Output schema:
//   path_len : u32 hex — BFS shortest path length; 0xffffffff is the
//              NO-PATH sentinel (unreachable within depth 4, or
//              either Q-ID null — the distance function never runs
//              the BFS for null Q-IDs)
//   distance : f64 hex (WikidataGraphDistance.distance, [0, 1])

import Foundation
import SubstrateML

public enum QIDAdjacencyPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "qid_adjacency",
        cookbookSection: "§8.3",
        referenceFile: "LatticeDistance.swift",
        generate: generate,
        validate: validate
    )

    /// The no-path sentinel for `path_len`.
    static let noPathSentinel: UInt32 = 0xFFFF_FFFF

    /// Case-local adjacency provider over the case's `edges` map — the
    /// same shape production builds over the pinned QIDClosure edges.
    struct MapAdjacency: WikidataAdjacencyProvider {
        let adj: [UInt64: Set<UInt64>]
        func neighbors(of qid: UInt64) -> Set<UInt64> { adj[qid] ?? [] }
    }

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let seededCount = 32

        for i in 0..<seededCount {
            // Random connected graph: nodes 1...n as integer Q-IDs
            // (0 is reserved as the null Q-ID), a spanning tree plus
            // random extra edges, symmetrized.
            let n = 8 + Int(rng.next() % 25)
            var adj: [UInt64: Set<UInt64>] = [:]
            for k in 1...n { adj[UInt64(k)] = [] }
            for k in 2...n {
                let p = UInt64(1 + Int(rng.next() % UInt64(k - 1)))
                adj[UInt64(k)]!.insert(p)
                adj[p]!.insert(UInt64(k))
            }
            let extra = Int(rng.next() % UInt64(n))
            for _ in 0..<extra {
                let u = UInt64(1 + Int(rng.next() % UInt64(n)))
                let v = UInt64(1 + Int(rng.next() % UInt64(n)))
                if u != v {
                    adj[u]!.insert(v)
                    adj[v]!.insert(u)
                }
            }

            var a: UInt64
            var b: UInt64
            switch i % 4 {
            case 0:
                a = UInt64(1 + Int(rng.next() % UInt64(n)))
                b = UInt64(1 + Int(rng.next() % UInt64(n)))
            case 1:
                a = UInt64(1 + Int(rng.next() % UInt64(n)))
                b = a
            case 2:
                a = 0
                b = UInt64(1 + Int(rng.next() % UInt64(n)))
            default:
                a = UInt64(1 + Int(rng.next() % UInt64(n)))
                let isolated = UInt64(n + 1)
                adj[isolated] = []
                b = isolated
            }
            cases.append(makeCase(index: i, a: a, b: b, adj: adj))
        }

        // Fixed case: direct neighbors — path length exactly 1.
        cases.append(makeCase(index: seededCount, a: 1, b: 2,
                              adj: [1: [2], 2: [1]]))
        // Fixed case: 6-chain, ends 5 apart — beyond the depth-4 budget,
        // pinning maxDepth (unreachable -> sentinel, 1.0).
        cases.append(makeCase(index: seededCount + 1, a: 1, b: 6,
                              adj: [1: [2], 2: [1, 3], 3: [2, 4],
                                    4: [3, 5], 5: [4, 6], 6: [5]]))

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "qid_adjacency",
            cookbookSection: "§8.3",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "LatticeDistance.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    private static func compute(a: UInt64, b: UInt64,
                                adj: [UInt64: Set<UInt64>]) -> (UInt32, Double) {
        let provider = MapAdjacency(adj: adj)
        let distance = WikidataGraphDistance.distance(from: a, to: b, provider: provider)
        // The distance function never runs the BFS for null Q-IDs; the
        // path output uses the sentinel for that case too.
        let pathLen: UInt32
        if a == 0 || b == 0 {
            pathLen = noPathSentinel
        } else if let len = WikidataGraphDistance.shortestPathLength(
            from: a, to: b, provider: provider) {
            pathLen = UInt32(len)
        } else {
            pathLen = noPathSentinel
        }
        return (pathLen, distance)
    }

    private static func makeCase(index: Int, a: UInt64, b: UInt64,
                                 adj: [UInt64: Set<UInt64>]) -> VectorFile.Case {
        let (pathLen, distance) = compute(a: a, b: b, adj: adj)
        var edgesDict = JSONDict()
        for (node, neighbors) in adj.sorted(by: { $0.key < $1.key }) {
            edgesDict.set(HexCoding.u64(node), .array(
                neighbors.sorted().map { .string(HexCoding.u64($0)) }))
        }
        let inputs = JSONDict([
            ("a", .string(HexCoding.u64(a))),
            ("b", .string(HexCoding.u64(b))),
            ("edges", .dict(edgesDict)),
        ])
        let output = JSONDict([
            ("path_len", .string(HexCoding.u32(pathLen))),
            ("distance", .string(HexCoding.f64(distance))),
        ])
        let pathDescription = pathLen == noPathSentinel ? "none" : "\(pathLen)"
        return VectorFile.Case(
            id: String(format: "case_%03d", index),
            description: "path \(pathDescription), distance \(distance)",
            inputs: inputs, expectedOutput: output)
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
        guard case .string(let aHex) = c.inputs.get("a") ?? .null,
              let a = parseU64(aHex) else { return fail(c, "missing or malformed a") }
        guard case .string(let bHex) = c.inputs.get("b") ?? .null,
              let b = parseU64(bHex) else { return fail(c, "missing or malformed b") }
        guard case .dict(let edgesDict) = c.inputs.get("edges") ?? .null else {
            return fail(c, "missing edges")
        }
        var adj: [UInt64: Set<UInt64>] = [:]
        for key in edgesDict.keys {
            guard let node = parseU64(key),
                  case .array(let arr) = edgesDict.get(key) ?? .null else {
                return fail(c, "malformed edges entry")
            }
            var neighbors = Set<UInt64>()
            for item in arr {
                guard case .string(let s) = item, let v = parseU64(s) else {
                    return fail(c, "malformed neighbor")
                }
                neighbors.insert(v)
            }
            adj[node] = neighbors
        }

        let (actualPath, actualDistance) = compute(a: a, b: b, adj: adj)

        guard case .string(let pathHex) = c.expectedOutput.get("path_len") ?? .null,
              let expectedPath = parseU32(pathHex) else {
            return fail(c, "missing or malformed expected path_len")
        }
        guard case .string(let distHex) = c.expectedOutput.get("distance") ?? .null,
              let expectedDistance = parseF64Hex(distHex) else {
            return fail(c, "missing or malformed expected distance")
        }

        encoder.writeU32(actualPath)
        encoder.writeF64(actualDistance)

        if actualPath == expectedPath
            && actualDistance.bitPattern == expectedDistance.bitPattern {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        }
        return ValidationResult.CaseResult(
            id: c.id, passed: false,
            diagnostic: "mismatch: expected path \(HexCoding.u32(expectedPath)) "
                + "dist \(HexCoding.f64(expectedDistance)), got path "
                + "\(HexCoding.u32(actualPath)) dist \(HexCoding.f64(actualDistance))")
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        // Order MUST match validateCase (path_len then distance) so
        // generator and validator produce identical canonical byte streams.
        guard case .string(let pathHex) = output.get("path_len") ?? .null,
              let p = parseU32(pathHex),
              case .string(let distHex) = output.get("distance") ?? .null,
              let d = parseF64Hex(distHex) else {
            fatalError("expected_output missing or malformed path_len/distance")
        }
        encoder.writeU32(p)
        encoder.writeF64(d)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseU64(_ s: String) -> UInt64? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, byte) in bytes.enumerated() { v |= UInt64(byte) << (i * 8) }
        return v
    }

    private static func parseU32(_ s: String) -> UInt32? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for (i, byte) in bytes.enumerated() { v |= UInt32(byte) << (i * 8) }
        return v
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, byte) in bytes.enumerated() { bits |= UInt64(byte) << (i * 8) }
        return Double(bitPattern: bits)
    }
}
