// MerkleCommitmentPrimitive.swift
//
// Canonical Merkle/commitment vectors for NT-P0. The primitive
// validates the byte contract implemented in SubstrateKernel:
// leaf payloads, interior roots, tombstones, empty root, and keyed
// commitments.

import Foundation
import SubstrateKernel
import SubstrateTypes

public enum MerkleCommitmentPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "merkle_commitment",
        cookbookSection: "NT-P0",
        referenceFile: "SubstrateKernel/MerkleCommitment.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        let cases = try canonicalCases()
        var encoder = CanonicalBinaryEncoder()
        for c in cases { try encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "merkle_commitment",
            cookbookSection: "NT-P0",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "SubstrateKernel/MerkleCommitment.swift"),
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

    private static func canonicalCases() throws -> [VectorFile.Case] {
        let leafPlainID = try requireUUID("11111111-1111-4111-8111-111111111111")
        let leafVectorID = try requireUUID("22222222-2222-4222-8222-222222222222")
        let tombstoneID = try requireUUID("33333333-3333-4333-8333-333333333333")

        let vectorPayloads = [
            MerkleVectorPayload(modelID: "zeta-v1", vectorIndex: 2, values: [3.5, -0.0]),
            MerkleVectorPayload(modelID: "alpha-v1", vectorIndex: 1, values: [1.25, -2.5, 0.0]),
            MerkleVectorPayload(modelID: "alpha-v1", vectorIndex: 0, values: [0.5]),
        ]

        let plainPayload = MerkleCommitment.canonicalLeafPayload(
            drawerID: leafPlainID,
            content: "hello moot",
            vectors: [])
        let vectorPayload = MerkleCommitment.canonicalLeafPayload(
            drawerID: leafVectorID,
            content: "Caf\u{00E9}",
            vectors: vectorPayloads)
        let plainDigest = MerkleCommitment.hashLeafPayload(plainPayload).wireBytes
        let vectorDigest = MerkleCommitment.hashLeafPayload(vectorPayload).wireBytes

        let childLow = try requireUUID("00000000-0000-4000-8000-000000000001")
        let childHigh = try requireUUID("FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")
        let interiorRoot = MerkleCommitment.interiorRoot(children: [
            MerkleChild(childID: childHigh, root: MerkleRoot(unchecked: vectorDigest)),
            MerkleChild(childID: childLow, root: MerkleRoot(unchecked: plainDigest)),
        ])
        let tombstone = MerkleCommitment.tombstoneHash(drawerID: tombstoneID)
        let key = Array("nt-p0 canonical key".utf8)
        let commitment = MerkleCommitment.keyedCommitment(
            forCanonicalLeafPayload: vectorPayload,
            key: key,
            keyVersion: 7)

        return [
            VectorFile.Case(
                id: "leaf_empty_vectors",
                description: "leaf hash with NFC content and zero vectors",
                inputs: leafInputs(op: "leaf", drawerID: leafPlainID, content: "hello moot", vectors: []),
                expectedOutput: digestOutput(plainDigest)),
            VectorFile.Case(
                id: "leaf_vector_order",
                description: "leaf hash with vectors sorted by modelID bytes then vectorIndex",
                inputs: leafInputs(op: "leaf", drawerID: leafVectorID, content: "Caf\u{00E9}", vectors: vectorPayloads),
                expectedOutput: digestOutput(vectorDigest)),
            VectorFile.Case(
                id: "interior_sorted_children",
                description: "interior root with children sorted by raw UUID bytes",
                inputs: JSONDict([
                    ("op", .string("interior")),
                    ("children", .array([
                        .dict(childInput(childID: childHigh, root: MerkleRoot(unchecked: vectorDigest))),
                        .dict(childInput(childID: childLow, root: MerkleRoot(unchecked: plainDigest))),
                    ])),
                ]),
                expectedOutput: digestOutput(interiorRoot.wireBytes)),
            VectorFile.Case(
                id: "tombstone",
                description: "tombstone hash over domain tag and drawer id",
                inputs: JSONDict([
                    ("op", .string("tombstone")),
                    ("drawer_id", .string(HexCoding.encode(MerkleCommitment.uuidBytes(tombstoneID)))),
                ]),
                expectedOutput: digestOutput(tombstone.wireBytes)),
            VectorFile.Case(
                id: "empty_root",
                description: "empty subtree root over the empty-root domain tag",
                inputs: JSONDict([
                    ("op", .string("empty_root")),
                ]),
                expectedOutput: digestOutput(MerkleCommitment.emptyRoot.wireBytes)),
            VectorFile.Case(
                id: "keyed_commitment",
                description: "HMAC commitment over the canonical leaf payload with key version",
                inputs: keyedInputs(
                    drawerID: leafVectorID,
                    content: "Caf\u{00E9}",
                    vectors: vectorPayloads,
                    key: key,
                    keyVersion: 7),
                expectedOutput: JSONDict([
                    ("digest", .string(HexCoding.encode(commitment.wireBytes))),
                    ("key_version", .string(HexCoding.u32(commitment.keyVersion))),
                ])),
        ]
    }

    private static func validateCase(_ c: VectorFile.Case,
                                     encoder: inout CanonicalBinaryEncoder)
                                    -> ValidationResult.CaseResult {
        guard case .string(let op) = c.inputs.get("op") ?? .null else {
            return fail(c, "missing op")
        }

        let actualDigest: [UInt8]
        let actualKeyVersion: UInt32?
        do {
            switch op {
            case "leaf":
                let payload = try leafPayload(from: c.inputs)
                actualDigest = MerkleCommitment.hashLeafPayload(payload).wireBytes
                actualKeyVersion = nil
            case "interior":
                actualDigest = try interiorRoot(from: c.inputs).wireBytes
                actualKeyVersion = nil
            case "tombstone":
                let drawerID = try requireInputUUID(c.inputs, "drawer_id")
                actualDigest = MerkleCommitment.tombstoneHash(drawerID: drawerID).wireBytes
                actualKeyVersion = nil
            case "empty_root":
                actualDigest = MerkleCommitment.emptyRoot.wireBytes
                actualKeyVersion = nil
            case "keyed_commitment":
                let payload = try leafPayload(from: c.inputs)
                let key = try requireHex(c.inputs, "key")
                let version = try requireU32(c.inputs, "key_version")
                let commitment = MerkleCommitment.keyedCommitment(
                    forCanonicalLeafPayload: payload,
                    key: key,
                    keyVersion: version)
                actualDigest = commitment.wireBytes
                actualKeyVersion = commitment.keyVersion
            default:
                return fail(c, "unknown op \(op)")
            }
        } catch {
            return fail(c, "\(error)")
        }

        do {
            try encodeDigest(actualDigest, keyVersion: actualKeyVersion, encoder: &encoder)
        } catch {
            return fail(c, "actual output encode failed: \(error)")
        }

        guard case .string(let expectedHex) = c.expectedOutput.get("digest") ?? .null,
              let expectedDigest = try? parseDigest(expectedHex) else {
            return fail(c, "missing or malformed expected digest")
        }
        if actualDigest != expectedDigest {
            return fail(c, "digest mismatch: expected \(expectedHex), got \(HexCoding.encode(actualDigest))")
        }

        if let actualKeyVersion {
            guard case .string(let expectedVersionHex) = c.expectedOutput.get("key_version") ?? .null,
                  let expectedVersion = parseU32(expectedVersionHex) else {
                return fail(c, "missing or malformed expected key_version")
            }
            if actualKeyVersion != expectedVersion {
                return fail(c, "key_version mismatch: expected \(expectedVersion), got \(actualKeyVersion)")
            }
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func leafPayload(from inputs: JSONDict) throws -> [UInt8] {
        let drawerID = try requireInputUUID(inputs, "drawer_id")
        guard case .string(let content) = inputs.get("content") ?? .null else {
            throw PrimitiveError.message("missing content")
        }
        let vectors = try parseVectors(inputs.get("vectors") ?? .array([]))
        return MerkleCommitment.canonicalLeafPayload(
            drawerID: drawerID,
            content: content,
            vectors: vectors)
    }

    private static func interiorRoot(from inputs: JSONDict) throws -> MerkleRoot {
        guard case .array(let arr) = inputs.get("children") ?? .null else {
            throw PrimitiveError.message("missing children")
        }
        let children = try arr.map { value -> MerkleChild in
            guard case .dict(let obj) = value else {
                throw PrimitiveError.message("child is not an object")
            }
            let childID = try requireInputUUID(obj, "child_id")
            let root = MerkleRoot(unchecked: try requireDigest(obj, "root"))
            return MerkleChild(childID: childID, root: root)
        }
        return MerkleCommitment.interiorRoot(children: children)
    }

    private static func leafInputs(
        op: String,
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload]
    ) -> JSONDict {
        JSONDict([
            ("op", .string(op)),
            ("drawer_id", .string(HexCoding.encode(MerkleCommitment.uuidBytes(drawerID)))),
            ("content", .string(content)),
            ("vectors", .array(vectors.map { .dict(vectorInput($0)) })),
        ])
    }

    private static func keyedInputs(
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload],
        key: [UInt8],
        keyVersion: UInt32
    ) -> JSONDict {
        var inputs = leafInputs(op: "keyed_commitment", drawerID: drawerID, content: content, vectors: vectors)
        inputs.set("key", .string(HexCoding.encode(key)))
        inputs.set("key_version", .string(HexCoding.u32(keyVersion)))
        return inputs
    }

    private static func vectorInput(_ vector: MerkleVectorPayload) -> JSONDict {
        JSONDict([
            ("model_id", .string(vector.modelID)),
            ("vector_index", .string(HexCoding.u32(vector.vectorIndex))),
            ("values", .array(vector.values.map { .string(HexCoding.f32($0)) })),
        ])
    }

    private static func childInput(childID: UUID, root: MerkleRoot) -> JSONDict {
        JSONDict([
            ("child_id", .string(HexCoding.encode(MerkleCommitment.uuidBytes(childID)))),
            ("root", .string(HexCoding.encode(root.wireBytes))),
        ])
    }

    private static func digestOutput(_ digest: [UInt8]) -> JSONDict {
        JSONDict([
            ("digest", .string(HexCoding.encode(digest))),
        ])
    }

    private static func parseVectors(_ value: JSONValue) throws -> [MerkleVectorPayload] {
        guard case .array(let arr) = value else {
            throw PrimitiveError.message("vectors must be an array")
        }
        return try arr.map { item in
            guard case .dict(let obj) = item else {
                throw PrimitiveError.message("vector is not an object")
            }
            guard case .string(let modelID) = obj.get("model_id") ?? .null else {
                throw PrimitiveError.message("vector missing model_id")
            }
            let vectorIndex = try requireU32(obj, "vector_index")
            guard case .array(let rawValues) = obj.get("values") ?? .null else {
                throw PrimitiveError.message("vector missing values")
            }
            let values = try rawValues.map { value -> Float32 in
                guard case .string(let hex) = value else {
                    throw PrimitiveError.message("vector value is not hex")
                }
                guard let f = parseF32(hex) else {
                    throw PrimitiveError.message("malformed f32")
                }
                return f
            }
            return MerkleVectorPayload(modelID: modelID, vectorIndex: vectorIndex, values: values)
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                     encoder: inout CanonicalBinaryEncoder) throws {
        let digest = try requireDigest(output, "digest")
        let version: UInt32?
        if output.get("key_version") != nil {
            version = try requireU32(output, "key_version")
        } else {
            version = nil
        }
        try encodeDigest(digest, keyVersion: version, encoder: &encoder)
    }

    private static func encodeDigest(_ digest: [UInt8],
                                     keyVersion: UInt32?,
                                     encoder: inout CanonicalBinaryEncoder) throws {
        guard digest.count == 32 else {
            throw PrimitiveError.message("digest must be 32 bytes")
        }
        encoder.writeBytes(digest)
        if let keyVersion {
            encoder.writeU32(keyVersion)
        }
    }

    private static func requireInputUUID(_ dict: JSONDict, _ key: String) throws -> UUID {
        let bytes = try requireHex(dict, key)
        guard bytes.count == 16 else {
            throw PrimitiveError.message("\(key) must be 16 bytes")
        }
        return uuidFromBytes(bytes)
    }

    private static func requireDigest(_ dict: JSONDict, _ key: String) throws -> [UInt8] {
        let bytes = try requireHex(dict, key)
        guard bytes.count == 32 else {
            throw PrimitiveError.message("\(key) must be 32 bytes")
        }
        return bytes
    }

    private static func requireHex(_ dict: JSONDict, _ key: String) throws -> [UInt8] {
        guard case .string(let hex) = dict.get(key) ?? .null else {
            throw PrimitiveError.message("missing \(key)")
        }
        return try HexCoding.decode(hex)
    }

    private static func requireU32(_ dict: JSONDict, _ key: String) throws -> UInt32 {
        guard case .string(let hex) = dict.get(key) ?? .null,
              let value = parseU32(hex) else {
            throw PrimitiveError.message("missing or malformed \(key)")
        }
        return value
    }

    private static func parseDigest(_ hex: String) throws -> [UInt8] {
        let bytes = try HexCoding.decode(hex)
        guard bytes.count == 32 else {
            throw PrimitiveError.message("digest must be 32 bytes")
        }
        return bytes
    }

    private static func parseU32(_ hex: String) -> UInt32? {
        guard let bytes = try? HexCoding.decode(hex), bytes.count == 4 else { return nil }
        var out: UInt32 = 0
        for i in 0..<4 { out |= UInt32(bytes[i]) << UInt32(i * 8) }
        return out
    }

    private static func parseF32(_ hex: String) -> Float32? {
        guard let bits = parseU32(hex) else { return nil }
        return Float32(bitPattern: bits)
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func requireUUID(_ string: String) throws -> UUID {
        guard let uuid = UUID(uuidString: string) else {
            throw PrimitiveError.message("bad UUID literal \(string)")
        }
        return uuid
    }

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private enum PrimitiveError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let msg): return msg
            }
        }
    }
}
