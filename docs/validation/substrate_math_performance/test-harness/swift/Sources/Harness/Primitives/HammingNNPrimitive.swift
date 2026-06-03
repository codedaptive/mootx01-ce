// HammingNNPrimitive.swift
//
// Hamming nearest-neighbor top-K (cookbook § 8.2). Mirror of
// rust/src/primitives/hamming_nn.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-HammingNN.swift
// via the GeniusLocusReference Swift package.
//
// Tie-breaking note: both legs use a max-heap of size K and
// extract via sort-by-distance. Equal distances may surface in
// different orders between languages. The harness applies a
// deterministic secondary sort by row-ID bytes (lexicographic)
// after each port returns its top-K, producing a canonical list
// that conforms across implementations.
//
// Input schema:
//   anchor       : 32-byte hex Fingerprint256
//   blocks_bitmask: u8 (bit k = block k included)
//   k            : u32
//   cohort       : array of {id: 16-byte hex, fingerprint: 32-byte hex}
//
// Output schema:
//   hits : array of {id: 16-byte hex, distance: u32 hex}
//          length min(k, |cohort|), sorted by (distance ascending,
//          id-bytes ascending).

import Foundation
import GeniusLocusReference

public enum HammingNNPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "hamming_nn",
        cookbookSection: "§8.2",
        referenceFile: "glref-swift-HammingNN.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let anchor = Fingerprint256(
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next())

            // Block mask cycles: full / first-two / odd / single.
            let blocksMask: UInt8 = [0xF, 0x3, 0xA, 0x4][i % 4]
            let blockSet = bitmaskToBlocks(blocksMask)

            let cohortSize = 16
            // Use k == cohort_size so the top-K returns the entire
            // cohort. This sidesteps the tie-breaking ambiguity in
            // both legs' K-bounded heaps: when distances tie at
            // the eviction boundary, Swift and Rust may evict
            // different items. Returning the full cohort and
            // applying the canonical (distance, id-bytes) sort
            // produces a deterministic conforming output.
            let k = cohortSize

            var cohortBytes = [[UInt8]]()
            var cohortFingerprints = [Fingerprint256]()
            var cohort = [(UUID, Fingerprint256)]()
            for _ in 0..<cohortSize {
                let idBytes = randomIDBytes(&rng)
                let fp = Fingerprint256(
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next())
                cohortBytes.append(idBytes)
                cohortFingerprints.append(fp)
                cohort.append((uuidFromBytes(idBytes), fp))
            }

            let hits = HammingNN.topK(
                anchor: anchor, candidates: cohort, k: k, blocks: blockSet)

            // Project hits back to id bytes via lookup.
            // Build id-bytes -> UUID lookup using the original
            // cohort order, then for each hit find its bytes.
            var bytesByUUID = [UUID: [UInt8]]()
            for (idx, b) in cohortBytes.enumerated() {
                bytesByUUID[uuidFromBytes(b)] = b
                _ = idx
            }
            // Canonicalize: distance asc, id-bytes asc.
            let canon = hits.compactMap { hit -> (bytes: [UInt8], distance: UInt32)? in
                guard let b = bytesByUUID[hit.rowID] else { return nil }
                return (b, UInt32(hit.distance))
            }
            .sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                return lexCompare(a.bytes, b.bytes)
            }

            let cohortArr: JSONValue = .array(cohortBytes.enumerated().map { (idx, b) -> JSONValue in
                let fpBytes = encodeFingerprintLE(cohortFingerprints[idx])
                return .dict(JSONDict([
                    ("id",          .string(HexCoding.encode(b))),
                    ("fingerprint", .string(fpBytes)),
                ]))
            })
            let hitsArr: JSONValue = .array(canon.map { (bytes, distance) -> JSONValue in
                return .dict(JSONDict([
                    ("id",       .string(HexCoding.encode(bytes))),
                    ("distance", .string(HexCoding.u32(distance))),
                ]))
            })

            let inputs = JSONDict([
                ("anchor",         .string(encodeFingerprintLE(anchor))),
                ("blocks_bitmask", .string(HexCoding.u8(blocksMask))),
                ("k",              .string(HexCoding.u32(UInt32(k)))),
                ("cohort",         cohortArr),
            ])
            let output = JSONDict([
                ("hits", hitsArr),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "blocks=0x\(String(blocksMask, radix: 16)), k=\(k), |cohort|=\(cohortSize)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "hamming_nn",
            cookbookSection: "§8.2",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-HammingNN.swift"),
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
        guard case .string(let aHex) = c.inputs.get("anchor") ?? .null,
              let anchor = parseFingerprintLE(aHex) else { return fail(c, "missing anchor") }
        guard case .string(let bmHex) = c.inputs.get("blocks_bitmask") ?? .null,
              let bmBytes = try? HexCoding.decode(bmHex),
              bmBytes.count == 1 else { return fail(c, "missing blocks_bitmask") }
        let blocksMask = bmBytes[0]
        let blockSet = bitmaskToBlocks(blocksMask)

        guard case .string(let kHex) = c.inputs.get("k") ?? .null,
              let kBytes = try? HexCoding.decode(kHex),
              kBytes.count == 4 else { return fail(c, "missing k") }
        var kVal: UInt32 = 0
        for j in 0..<4 { kVal |= UInt32(kBytes[j]) << (j * 8) }
        let k = Int(kVal)

        guard case .array(let cohortArr) = c.inputs.get("cohort") ?? .null else {
            return fail(c, "missing cohort")
        }
        var cohort = [(UUID, Fingerprint256)]()
        var bytesByUUID = [UUID: [UInt8]]()
        for v in cohortArr {
            guard case .dict(let obj) = v else { return fail(c, "cohort element not dict") }
            guard case .string(let idHex) = obj.get("id") ?? .null,
                  let idBytes = try? HexCoding.decode(idHex),
                  idBytes.count == 16 else { return fail(c, "cohort id malformed") }
            guard case .string(let fpHex) = obj.get("fingerprint") ?? .null,
                  let fp = parseFingerprintLE(fpHex) else { return fail(c, "cohort fp malformed") }
            let u = uuidFromBytes(idBytes)
            cohort.append((u, fp))
            bytesByUUID[u] = idBytes
        }

        let hits = HammingNN.topK(
            anchor: anchor, candidates: cohort, k: k, blocks: blockSet)
        let canon = hits.compactMap { hit -> (bytes: [UInt8], distance: UInt32)? in
            guard let b = bytesByUUID[hit.rowID] else { return nil }
            return (b, UInt32(hit.distance))
        }
        .sorted { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            return lexCompare(a.bytes, b.bytes)
        }

        guard case .array(let hitsArr) = c.expectedOutput.get("hits") ?? .null else {
            return fail(c, "missing expected hits")
        }
        var expected = [(bytes: [UInt8], distance: UInt32)]()
        for v in hitsArr {
            guard case .dict(let obj) = v else { return fail(c, "hit not dict") }
            guard case .string(let idHex) = obj.get("id") ?? .null,
                  let b = try? HexCoding.decode(idHex), b.count == 16 else {
                return fail(c, "hit id malformed")
            }
            guard case .string(let dHex) = obj.get("distance") ?? .null,
                  let dBytes = try? HexCoding.decode(dHex), dBytes.count == 4 else {
                return fail(c, "hit distance malformed")
            }
            var d: UInt32 = 0
            for j in 0..<4 { d |= UInt32(dBytes[j]) << (j * 8) }
            expected.append((b, d))
        }

        if canon.count != expected.count {
            return fail(c, "hits length mismatch: \(canon.count) vs \(expected.count)")
        }

        for (bytes, d) in canon {
            encoder.writeBytes(bytes)
            encoder.writeU32(d)
        }

        for j in 0..<canon.count {
            if canon[j].bytes != expected[j].bytes {
                return fail(c, "hits[\(j)] id mismatch")
            }
            if canon[j].distance != expected[j].distance {
                return fail(c, "hits[\(j)] distance mismatch: expected \(expected[j].distance), got \(canon[j].distance)")
            }
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .array(let arr) = output.get("hits") ?? .null else {
            fatalError("expected_output missing hits")
        }
        for v in arr {
            guard case .dict(let obj) = v,
                  case .string(let idHex) = obj.get("id") ?? .null,
                  let b = try? HexCoding.decode(idHex), b.count == 16,
                  case .string(let dHex) = obj.get("distance") ?? .null,
                  let dBytes = try? HexCoding.decode(dHex), dBytes.count == 4 else {
                fatalError("expected_output hit malformed")
            }
            var d: UInt32 = 0
            for j in 0..<4 { d |= UInt32(dBytes[j]) << (j * 8) }
            encoder.writeBytes(b)
            encoder.writeU32(d)
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func bitmaskToBlocks(_ mask: UInt8) -> Set<Int> {
        var out = Set<Int>()
        for k in 0..<4 where (mask >> UInt8(k)) & 1 == 1 { out.insert(k) }
        return out
    }

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

    private static func encodeFingerprintLE(_ fp: Fingerprint256) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let blocks = [fp.block0, fp.block1, fp.block2, fp.block3]
        for (i, w) in blocks.enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8((w >> (j * 8)) & 0xFF) }
        }
        return HexCoding.encode(bytes)
    }

    private static func parseFingerprintLE(_ s: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        var blocks = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var w: UInt64 = 0
            for j in 0..<8 { w |= UInt64(bytes[i * 8 + j]) << (j * 8) }
            blocks[i] = w
        }
        return Fingerprint256(block0: blocks[0], block1: blocks[1],
                              block2: blocks[2], block3: blocks[3])
    }

    private static func lexCompare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }
}
