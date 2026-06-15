// Chunk.swift
//
// A unit of text retrievable from a RAG bundle. One Chunk maps
// to one BundleRow in storage, paired with one StoredVector in
// VectorKit's vectors table via (drawerID, modelID).
//
// The chunk identifier is content-addressed: it is a deterministic
// RFC 4122 v5 UUID derived from (sourceID, startOffset, text). Two
// chunkings of the same source text with the same configuration
// therefore produce identical ids, which is what makes re-ingestion
// idempotent at the bundle level and what lets the sync layer's
// .appendOnly conflict policy reconcile the same chunk arriving from
// two devices. The derivation is fixed by RFC 4122, so the Swift and
// Rust ports produce byte-identical ids for identical inputs (see
// CorpusKit/rust/src/chunk.rs::derive_id and the parity test).

import Foundation
import Crypto
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

public struct Chunk: Sendable, Equatable, Codable {
    /// Content-addressed primary key. A deterministic v5 UUID over
    /// (sourceID, startOffset, text). Use `Chunk.deriveID` to compute
    /// it directly; the content-addressed initializer assigns it.
    public let id: UUID

    /// Identifier of the source document this chunk belongs to.
    /// Free-form string; callers typically use a file path, a
    /// drawer ID, a URL, or any other stable handle.
    public let sourceID: String

    /// Character offset of this chunk in the source.
    public let startOffset: Int

    /// Character length of this chunk's text.
    public let length: Int

    /// Verbatim chunk text. Stored as is; the kit does not
    /// normalize or lowercase.
    public let text: String

    /// HLC for ordering across replicas. Filled in by the bundle
    /// store on insert.
    public let hlc: HLC

    /// Free-form per-chunk metadata. Encoded as JSON in storage.
    public let metadata: [String: String]

    /// Content-addressed initializer. The id is derived from
    /// (sourceID, startOffset, text); identical content yields an
    /// identical id. This is the initializer the chunker and all
    /// normal ingestion paths use.
    public init(
        sourceID: String,
        startOffset: Int,
        length: Int,
        text: String,
        hlc: HLC,
        metadata: [String: String] = [:]
    ) {
        self.id = Self.deriveID(
            sourceID: sourceID, startOffset: startOffset, text: text)
        self.sourceID = sourceID
        self.startOffset = startOffset
        self.length = length
        self.text = text
        self.hlc = hlc
        self.metadata = metadata
    }

    /// Explicit-id initializer. Used when reconstructing a chunk
    /// whose id is already known (decoding a stored row, or a test
    /// that needs a specific id). Normal ingestion uses the
    /// content-addressed initializer above instead.
    public init(
        id: UUID,
        sourceID: String,
        startOffset: Int,
        length: Int,
        text: String,
        hlc: HLC,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.startOffset = startOffset
        self.length = length
        self.text = text
        self.hlc = hlc
        self.metadata = metadata
    }

    // MARK: - Content-addressed id

    /// Fixed namespace for CorpusKit chunk ids, as raw bytes. This value
    /// MUST NOT change: changing it re-keys every chunk fleet-wide and
    /// breaks the join to existing vectors and the idempotency of
    /// existing stores. It is the UUID d6f3a1b2-7c84-4e5f-9a0b-1c2d3e4f5061.
    private static let namespaceBytes: [UInt8] = [
        0xd6, 0xf3, 0xa1, 0xb2, 0x7c, 0x84, 0x4e, 0x5f,
        0x9a, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61
    ]

    /// Field separator for the content-address name. A unit separator
    /// (0x1F) cannot appear in normal source ids or text, so it keeps
    /// the three fields unambiguous: ("a", 0, "bc") and ("a", 0, "b",
    /// "c") cannot collide.
    private static let fieldSeparator = "\u{1F}"

    /// Derive the content-addressed v5 UUID for a chunk. The name is
    /// the UTF-8 encoding of `sourceID + US + startOffset + US + text`;
    /// the algorithm is RFC 4122 section 4.3 (namespace bytes followed
    /// by name bytes, SHA-1, first 16 bytes, version 5, RFC variant).
    public static func deriveID(
        sourceID: String,
        startOffset: Int,
        text: String
    ) -> UUID {
        let name = "\(sourceID)\(fieldSeparator)\(startOffset)\(fieldSeparator)\(text)"
        var input = Data(namespaceBytes)
        input.append(contentsOf: Array(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input))   // 20 bytes
        b[6] = (b[6] & 0x0F) | 0x50                       // version 5
        b[8] = (b[8] & 0x3F) | 0x80                       // RFC 4122 variant
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }
}

/// Identity of a chunk plus its retrieval score. Returned by
/// hybrid retrieval.
public struct ScoredChunk: Sendable, Equatable {
    public let chunk: Chunk
    public let score: Float
    public let vectorScore: Float?
    public let keywordScore: Float?

    public init(
        chunk: Chunk,
        score: Float,
        vectorScore: Float? = nil,
        keywordScore: Float? = nil
    ) {
        self.chunk = chunk
        self.score = score
        self.vectorScore = vectorScore
        self.keywordScore = keywordScore
    }
}
