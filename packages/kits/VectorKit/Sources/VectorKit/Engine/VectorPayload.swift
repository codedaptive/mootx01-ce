// VectorPayload.swift
//
// The typed vector payload: the atomic unit of vector data in the engine.
//
// Lane F foundation type. Defined here first because every parallel
// lane (MIH, float, ColBERT, fusion) contacts the engine through this
// type and VectorRecordKey — never through each other. A lane that
// discovers it needs a new field does NOT add it locally; it files an
// FT-1 update to Lane F.
//
// Binary payloads (kind == .binary) are EXACTLY the existing Engram
// wire form — 32 bytes, 4×UInt64 little-endian — so VectorPayload and
// Engram are inter-convertible with zero copy of meaning and every
// existing binary conformance vector still holds.
//
// Float32 payloads: dim×4 bytes, IEEE-754 little-endian, no scale.
// Int8 payloads: dim bytes (quantized coefficients) + scale field for
// dequantization. The quantization policy (symmetric vs asymmetric,
// per-vector vs per-dim scale) has NOT been ratified. Int8 WRITES are
// REJECTED fail-closed by VectorStore with VectorKitError.int8QuantizationPolicyUndefined
// until a policy is ratified. The case and field remain in the type so
// that a future ratification does not require an API change. See arch
// spec §10.3 and VECTORKIT_SPEC §I-4a.

import EngramLib
import Foundation

/// One row of input for the bulk `VectorStore.addPayloads(_:)` path.
///
/// Bundles a `VectorPayload` with the index metadata (item id, vector
/// index, model id/version, filed-at) that a single `addPayload` call
/// would otherwise take as separate arguments. The import/migration path
/// builds an array of these and submits them in one batch so the resident
/// array, sidecar, and indexes are updated once for the whole batch rather
/// than once per row (TASK #24).
///
/// Thread-safety: value type, fully Sendable.
public struct VectorPayloadInput: Sendable, Equatable {
    /// The owning item (drawer/chunk) id. Joins to `vectors.item_id`.
    public let itemID: String
    /// Multi-vector index: 0 for single-vector models, token position for
    /// late-interaction models.
    public let vectorIndex: UInt32
    /// The typed vector payload (binary, float32, or int8).
    public let payload: VectorPayload
    /// The embedding model id.
    public let modelID: String
    /// The embedding model version.
    public let modelVersion: String
    /// Wall-clock filing time (determinism discipline: passed in, never
    /// read from `Date()` inside the engine).
    public let filedAt: Date

    public init(
        itemID: String,
        vectorIndex: UInt32,
        payload: VectorPayload,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    ) {
        self.itemID = itemID
        self.vectorIndex = vectorIndex
        self.payload = payload
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.filedAt = filedAt
    }
}

/// Wire tag identifying the numeric type of the vector payload.
///
/// Stored as a single byte (raw value 0/1/2) in the `vectors.kind`
/// column (INTEGER DEFAULT 0). Do not reorder; the raw values are
/// on-disk and must be stable.
public enum VectorKind: UInt8, Sendable, Equatable, CaseIterable {
    /// 256-bit SimHash / Engram fingerprint. 32 bytes. Metrics:
    /// Hamming and Jaccard. Determinism: bit-identical four-way.
    case binary  = 0
    /// IEEE-754 float32 coefficients. dim×4 bytes. Metrics: cosine,
    /// l2, dot (via VectorKit's FloatMetric). Determinism:
    /// reproducible-within-config, NOT four-way bit-identical.
    case float32 = 1
    /// Quantized int8 coefficients + per-vector dequant scale. dim
    /// bytes + scale field. The quantization policy (symmetric vs
    /// asymmetric, per-vector vs per-dim scale) has not been ratified.
    /// VectorStore REJECTS int8 writes fail-closed until a policy is
    /// ratified (VectorKitError.int8QuantizationPolicyUndefined). The
    /// case is preserved so a future ratification does not require an
    /// API change. See arch spec §10.3 and VECTORKIT_SPEC §I-4a.
    case int8    = 2
}

/// The typed vector payload: kind tag + dimensionality + raw bytes +
/// optional int8 dequantization scale.
///
/// This is the lowest-level envelope the engine passes around. It
/// carries no index metadata (that lives in VectorRecordKey).
///
/// Thread-safety: value type, fully Sendable.
public struct VectorPayload: Sendable, Equatable {

    // MARK: - Stored fields

    /// Numeric type of the stored vector.
    public let kind: VectorKind

    /// Number of logical dimensions.
    /// - `.binary`: always 256 (the Engram is 256-bit).
    /// - `.float32`: variable; bytes.count == dim × 4.
    /// - `.int8`: variable; bytes.count == dim.
    public let dim: UInt32

    /// Raw vector bytes in the canonical wire format.
    /// - `.binary`: 32 bytes — exactly the Engram wire form (4×UInt64 LE).
    /// - `.float32`: dim×4 bytes, IEEE-754 single-precision, little-endian.
    /// - `.int8`: dim bytes, quantized signed integers.
    public let bytes: [UInt8]

    /// Dequantization scale for int8 vectors; nil for binary and float32.
    /// Multiply each int8 coefficient by this value to recover approximate
    /// float32. The quantization policy has not been ratified — int8 writes
    /// are rejected fail-closed by VectorStore. This field is preserved as
    /// a placeholder so the API does not need to change when the policy
    /// is eventually ratified. See arch spec §10.3 and VECTORKIT_SPEC §I-4a.
    public let scale: Float?

    // MARK: - Initialisers

    /// General initialiser. The caller is responsible for consistency
    /// between kind, dim, bytes, and scale.
    public init(kind: VectorKind, dim: UInt32, bytes: [UInt8], scale: Float? = nil) {
        self.kind = kind
        self.dim = dim
        self.bytes = bytes
        self.scale = scale
    }

    // MARK: - Convenience: binary (Engram)

    /// Construct a binary payload from an Engram.
    ///
    /// The wire bytes of the Engram are stored directly — no copy of
    /// meaning, no transformation. This is the zero-loss round-trip
    /// that preserves every existing binary conformance vector.
    public init(engram: Engram) {
        // Engram wire form: 32 bytes, 4×UInt64 little-endian. This is
        // also the canonical §0.1 layout described in the retrieval
        // algorithms reference (bit i = word w[i/64], position i%64, LSB=0).
        self.kind = .binary
        self.dim = 256
        self.bytes = engram.wireBytes
        self.scale = nil
    }

    // MARK: - Convenience: float32

    /// Construct a float32 payload from a host-endian [Float] slice.
    ///
    /// Serializes to IEEE-754 little-endian on the wire so the `.vec`
    /// sidecar is byte-identical across Apple and Linux hosts. This is
    /// a deliberate serialization choice, not an endian assumption.
    public init(floats: [Float]) {
        self.kind = .float32
        self.dim = UInt32(floats.count)
        // Serialize each Float as 4 bytes, little-endian IEEE-754.
        var raw = [UInt8]()
        raw.reserveCapacity(floats.count * 4)
        for f in floats {
            let bits = f.bitPattern          // UInt32 IEEE-754 representation
            raw.append(UInt8(bits & 0xFF))
            raw.append(UInt8((bits >> 8) & 0xFF))
            raw.append(UInt8((bits >> 16) & 0xFF))
            raw.append(UInt8((bits >> 24) & 0xFF))
        }
        self.bytes = raw
        self.scale = nil
    }

    // MARK: - Accessors

    /// Re-constitute the Engram from a binary payload.
    ///
    /// Returns nil if the payload is not binary or the byte count is
    /// not exactly 32. In production these conditions should never
    /// occur — a malformed payload is a storage bug. Use a safe
    /// fallback rather than crashing to avoid losing a search session.
    public func asEngram() throws -> Engram {
        guard kind == .binary else {
            throw VectorKitError.invalidPayload(
                "asEngram() called on kind=\(kind); expected .binary")
        }
        return try Engram(wireBytes: bytes)
    }

    /// Re-constitute the [Float] slice from a float32 payload.
    ///
    /// Deserializes from IEEE-754 little-endian bytes. Inverse of
    /// `init(floats:)`. Throws if the payload is not float32 or if
    /// the byte count is not a multiple of 4.
    public func asFloats() throws -> [Float] {
        guard kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "asFloats() called on kind=\(kind); expected .float32")
        }
        guard bytes.count % 4 == 0 else {
            throw VectorKitError.invalidPayload(
                "float32 payload byte count \(bytes.count) is not a multiple of 4")
        }
        var floats = [Float]()
        floats.reserveCapacity(bytes.count / 4)
        var idx = 0
        while idx + 3 < bytes.count {
            let bits = UInt32(bytes[idx])
                | (UInt32(bytes[idx + 1]) << 8)
                | (UInt32(bytes[idx + 2]) << 16)
                | (UInt32(bytes[idx + 3]) << 24)
            floats.append(Float(bitPattern: bits))
            idx += 4
        }
        return floats
    }
}

