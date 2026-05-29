// BradleyTerryPrimitive.swift
//
// Bradley-Terry online preference update (cookbook § 8.12).
// Mirror of rust/src/primitives/bradley_terry.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-BradleyTerry.swift
// via the GeniusLocusReference Swift package.
//
// Each case:
//   1. Builds a synthetic pre-state theta map.
//   2. Builds a single PreferenceObservation (winner + N losers).
//   3. Runs `observe()` on a fresh estimator initialized with the
//      pre-state theta.
//   4. Records the post-state theta as the expected output.
//
// Determinism note: row IDs are 16-byte synthetic identifiers
// derived from the SplitMix RNG. Swift builds a UUID from those
// bytes; Rust builds a u128 from the same bytes (little-endian).
// Map iteration order in the observation list is preserved by
// using arrays of (id, theta) pairs in the JSON, not dictionaries.
//
// Input schema:
//   learning_rate : f64
//   l2            : f64
//   pre_theta     : array of {id: 16-byte hex, theta: f64-hex}
//   winner_id     : 16-byte hex
//   losers        : array of 16-byte hex
//   weight        : f64
//
// Output schema:
//   post_theta : array of {id: 16-byte hex, theta: f64-hex}
//                ordered by id ascending (canonical)

import Foundation
import GeniusLocusReference

public enum BradleyTerryPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "bradley_terry",
        cookbookSection: "§8.12",
        referenceFile: "glref-swift-BradleyTerry.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            // Population: 4 distinct row IDs per case.
            let populationSize = 4
            var rowIDs = [UUID]()
            var rowBytes = [[UInt8]]()
            for _ in 0..<populationSize {
                let bytes = randomIDBytes(&rng)
                rowBytes.append(bytes)
                rowIDs.append(uuidFromBytes(bytes))
            }

            // Pre-state theta: small random values for each id.
            var preTheta = [(UUID, [UInt8], Double)]()
            for k in 0..<populationSize {
                let raw = rng.next()
                let theta = (Double(raw >> 40) / Double(1 << 24)) * 2.0 - 1.0
                preTheta.append((rowIDs[k], rowBytes[k], theta))
            }

            // Observation: pick a winner index, the rest are losers.
            let winnerIdx = Int(rng.next() % UInt64(populationSize))
            let winner = rowIDs[winnerIdx]
            let winnerBytes = rowBytes[winnerIdx]
            var losers = [UUID]()
            var loserBytes = [[UInt8]]()
            for k in 0..<populationSize where k != winnerIdx {
                losers.append(rowIDs[k])
                loserBytes.append(rowBytes[k])
            }
            let weight = 1.0

            // Cycle hyperparameters across cases.
            let learningRate: Double = [0.05, 0.1, 0.025, 0.5][i % 4]
            let l2: Double = [0.001, 0.01, 0.0, 0.05][i % 4]

            // Build initial theta dictionary.
            var thetaInit = [UUID: Double]()
            for (id, _, t) in preTheta { thetaInit[id] = t }

            var est = BradleyTerryEstimator(
                learningRate: learningRate, l2: l2, theta: thetaInit)
            est.observe(PreferenceObservation(
                winnerID: winner, losers: losers, weight: weight))

            // Canonical output: sort the post-state by id-bytes.
            let postPairs = preTheta.map { (id, bytes, _) -> (UUID, [UInt8], Double) in
                let t = est.theta[id] ?? 0.0
                return (id, bytes, t)
            }.sorted { lexCompare($0.1, $1.1) }

            // Build pre/post arrays as JSON.
            let preArr: JSONValue = .array(preTheta
                .sorted { lexCompare($0.1, $1.1) }
                .map { (_, bytes, t) -> JSONValue in
                    return .dict(JSONDict([
                        ("id",    .string(HexCoding.encode(bytes))),
                        ("theta", .string(HexCoding.f64(t))),
                    ]))
                })
            let postArr: JSONValue = .array(postPairs.map { (_, bytes, t) -> JSONValue in
                return .dict(JSONDict([
                    ("id",    .string(HexCoding.encode(bytes))),
                    ("theta", .string(HexCoding.f64(t))),
                ]))
            })
            let losersArr: JSONValue = .array(loserBytes.map { .string(HexCoding.encode($0)) })

            let inputs = JSONDict([
                ("learning_rate", .string(HexCoding.f64(learningRate))),
                ("l2",            .string(HexCoding.f64(l2))),
                ("pre_theta",     preArr),
                ("winner_id",     .string(HexCoding.encode(winnerBytes))),
                ("losers",        losersArr),
                ("weight",        .string(HexCoding.f64(weight))),
            ])
            let output = JSONDict([
                ("post_theta", postArr),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "lr=\(learningRate), l2=\(l2), |losers|=\(losers.count)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "bradley_terry",
            cookbookSection: "§8.12",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-BradleyTerry.swift"),
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
        guard case .string(let lrHex) = c.inputs.get("learning_rate") ?? .null,
              let lr = parseF64Hex(lrHex) else { return fail(c, "missing learning_rate") }
        guard case .string(let l2Hex) = c.inputs.get("l2") ?? .null,
              let l2 = parseF64Hex(l2Hex) else { return fail(c, "missing l2") }
        guard case .array(let preArr) = c.inputs.get("pre_theta") ?? .null else {
            return fail(c, "missing pre_theta")
        }
        guard case .string(let winnerHex) = c.inputs.get("winner_id") ?? .null,
              let winnerBytes = try? HexCoding.decode(winnerHex),
              winnerBytes.count == 16 else {
            return fail(c, "missing or malformed winner_id")
        }
        guard case .array(let losersArr) = c.inputs.get("losers") ?? .null else {
            return fail(c, "missing losers")
        }
        guard case .string(let wHex) = c.inputs.get("weight") ?? .null,
              let weight = parseF64Hex(wHex) else { return fail(c, "missing weight") }

        // Parse pre_theta into dict + parallel id-bytes list.
        var thetaInit = [UUID: Double]()
        var idBytesAll = [[UInt8]]()
        for v in preArr {
            guard case .dict(let obj) = v else { return fail(c, "pre_theta element not object") }
            guard case .string(let idHex) = obj.get("id") ?? .null,
                  let idBytes = try? HexCoding.decode(idHex),
                  idBytes.count == 16 else { return fail(c, "pre_theta id malformed") }
            guard case .string(let tHex) = obj.get("theta") ?? .null,
                  let t = parseF64Hex(tHex) else { return fail(c, "pre_theta theta malformed") }
            thetaInit[uuidFromBytes(idBytes)] = t
            idBytesAll.append(idBytes)
        }

        var losers = [UUID]()
        for v in losersArr {
            guard case .string(let s) = v,
                  let lb = try? HexCoding.decode(s), lb.count == 16 else {
                return fail(c, "loser id malformed")
            }
            losers.append(uuidFromBytes(lb))
        }
        let winner = uuidFromBytes(winnerBytes)

        var est = BradleyTerryEstimator(
            learningRate: lr, l2: l2, theta: thetaInit)
        est.observe(PreferenceObservation(
            winnerID: winner, losers: losers, weight: weight))

        // Build actual post-state: same id ordering as pre, sorted by bytes.
        let actualPostSorted = idBytesAll.sorted { lexCompare($0, $1) }
            .map { bytes -> (bytes: [UInt8], theta: Double) in
                let id = uuidFromBytes(bytes)
                return (bytes, est.theta[id] ?? 0.0)
            }

        // Parse expected post.
        guard case .array(let postArr) = c.expectedOutput.get("post_theta") ?? .null else {
            return fail(c, "missing expected post_theta")
        }
        if postArr.count != actualPostSorted.count {
            return fail(c, "post_theta length mismatch")
        }
        var expectedPost = [(bytes: [UInt8], theta: Double)]()
        for v in postArr {
            guard case .dict(let obj) = v else { return fail(c, "post_theta element not object") }
            guard case .string(let idHex) = obj.get("id") ?? .null,
                  let idBytes = try? HexCoding.decode(idHex),
                  idBytes.count == 16 else { return fail(c, "post_theta id malformed") }
            guard case .string(let tHex) = obj.get("theta") ?? .null,
                  let t = parseF64Hex(tHex) else { return fail(c, "post_theta theta malformed") }
            expectedPost.append((idBytes, t))
        }

        // Encode actual to canonical binary AND compare.
        for (bytes, t) in actualPostSorted {
            encoder.writeBytes(bytes)
            encoder.writeF64(t)
        }

        for k in 0..<actualPostSorted.count {
            let a = actualPostSorted[k]
            let e = expectedPost[k]
            if a.bytes != e.bytes {
                return fail(c, "post_theta id ordering mismatch at \(k)")
            }
            if a.theta.bitPattern != e.theta.bitPattern {
                return fail(c, "post_theta value mismatch at \(k): expected \(HexCoding.f64(e.theta)) got \(HexCoding.f64(a.theta))")
            }
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let postArr) = output.get("post_theta") ?? .null else {
            fatalError("expected_output missing post_theta")
        }
        for v in postArr {
            guard case .dict(let obj) = v,
                  case .string(let idHex) = obj.get("id") ?? .null,
                  let idBytes = try? HexCoding.decode(idHex),
                  idBytes.count == 16,
                  case .string(let tHex) = obj.get("theta") ?? .null,
                  let t = parseF64Hex(tHex) else {
                fatalError("expected_output post_theta element malformed")
            }
            encoder.writeBytes(idBytes)
            encoder.writeF64(t)
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseF64Hex(_ s: String) -> Double? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var bits: UInt64 = 0
        for (i, b) in bytes.enumerated() { bits |= UInt64(b) << (i * 8) }
        return Double(bitPattern: bits)
    }

    /// Produce 16 bytes of synthetic ID. Two u64 draws, LE-packed
    /// into a contiguous 16-byte array; Rust uses the same draws
    /// to build a u128 (which on LE is the same byte order).
    private static func randomIDBytes(_ rng: inout SplitMix64) -> [UInt8] {
        let lo = rng.next()
        let hi = rng.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for j in 0..<8 { bytes[j]     = UInt8((lo >> (j * 8)) & 0xFF) }
        for j in 0..<8 { bytes[8 + j] = UInt8((hi >> (j * 8)) & 0xFF) }
        return bytes
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func lexCompare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }
}
