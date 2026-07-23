// CorpusContent.swift
//
// The canonical content boundary (GLK shared-content 1.1, P1).
//
// The common indexing engine consumes CONTENT — identified rows with a
// revision and digest — never storage. In standalone mode CorpusKit's own
// `CorpusDocumentStore` owns the canonical rows (`corpus_documents`); in
// attached mode GLK's LocusKit-backed adapter resolves the same surface
// from Drawers and the canonical public identity is `Drawer.id`. Either
// way the engine sees exactly these values:
//
//   - `CorpusContentRecord(id, revision, digest, text)`;
//   - `CorpusContentChange.upsert(id, revision, digest)` /
//     `.remove(id, revision)`; and
//   - a stable, cursor-based `CorpusContentChangeBatch`.
//
// An upsert is idempotent on (id, revision, digest, indexVersion). The
// worker loads the current record BY ID at work time, rejects a
// revision/digest mismatch without advancing its checkpoint, replaces the
// canonical ID's derived state, then advances `corpus_index_state`
// (identity and indexing contract). Content never rides queues or change
// batches — only identity, revision, digest, and cursor.
//
// Rust twin: `rust/src/content.rs`.

import Foundation
import Crypto

/// The canonical public content identity the engine keys every derived row
/// by. In standalone mode this is the caller's document ID; in attached
/// mode it is the Drawer ID. One identity crosses every lane — recall
/// returns these IDs directly, with no translation join.
public typealias CorpusContentID = String

/// Deterministic content digest — lowercase SHA-256 hex over UTF-8 text.
/// Cross-port identical (Rust twin: `content::content_digest`).
public enum CorpusContentDigest {
    public static func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    /// Digest of raw bytes — the basis-generation anchor (lowercase SHA-256
    /// hex of a serialized basis blob).
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// One canonical content row as the engine consumes it.
public struct CorpusContentRecord: Sendable, Equatable {
    public let id: CorpusContentID
    /// Monotonic per-ID revision, starting at 1. A changed text bumps the
    /// revision; re-putting identical text does not.
    public let revision: Int64
    /// `CorpusContentDigest.digest(text)` — the change-detection anchor.
    public let digest: String
    /// The verbatim canonical text, resolved BY ID at work time. Records
    /// are handed to the engine in memory only; the text never rides a
    /// queue payload or change feed.
    public let text: String

    public init(id: CorpusContentID, revision: Int64, digest: String, text: String) {
        self.id = id
        self.revision = revision
        self.digest = digest
        self.text = text
    }
}

/// One entry of the content change feed. Carries identity, revision, and
/// digest ONLY — never text.
public enum CorpusContentChange: Sendable, Equatable {
    case upsert(id: CorpusContentID, revision: Int64, digest: String)
    case remove(id: CorpusContentID, revision: Int64)

    public var id: CorpusContentID {
        switch self {
        case .upsert(let id, _, _), .remove(let id, _): return id
        }
    }

    public var revision: Int64 {
        switch self {
        case .upsert(_, let revision, _), .remove(_, let revision): return revision
        }
    }
}

/// One page of the change feed. `nextCursor` resumes enumeration exactly
/// after the last change in `changes`; a page is stable — re-reading the
/// same cursor returns the same changes in the same order.
public struct CorpusContentChangeBatch: Sendable, Equatable {
    public let changes: [CorpusContentChange]
    /// Opaque resume cursor. Present iff `changes` is non-empty; pass it
    /// to the next `changes(since:limit:)` call. A nil `since` starts from
    /// the beginning of the feed.
    public let nextCursor: String?

    public init(changes: [CorpusContentChange], nextCursor: String?) {
        self.changes = changes
        self.nextCursor = nextCursor
    }

    public static let empty = CorpusContentChangeBatch(changes: [], nextCursor: nil)
}

/// The read surface the indexing engine consumes — declared by CorpusKit,
/// implemented by the standalone `CorpusDocumentStore` and by GLK's
/// LocusKit-backed adapter (composition: GLK owns the adapter; LocusKit
/// never imports CorpusKit).
public protocol CorpusContentSource: Sendable {
    /// Resolve the CURRENT record for `id`, or nil when the ID does not
    /// resolve to live content. Workers call this at work time so a stale
    /// job can never overwrite a newer revision.
    func record(for id: CorpusContentID) async throws -> CorpusContentRecord?

    /// Enumerate content changes after `cursor` (nil = from the start), at
    /// most `limit` entries, in stable feed order.
    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch

    /// Every live content ID, in deterministic ascending ID order — the
    /// streaming order rebuilds use.
    func activeContentIDs() async throws -> [CorpusContentID]
}

/// The full canonical-content authority — the standalone-mode surface.
/// In attached mode content mutation flows through GLK/LocusKit verbs and
/// source changes; nothing conforms to this protocol on the attached path
/// (`CorpusContentConfiguration` rejects it structurally).
public protocol CorpusContentStore: CorpusContentSource {
    /// Insert or update canonical content. Computes the digest, bumps the
    /// revision iff the text changed, and journals an upsert change.
    /// Re-putting identical text is a no-op (same record back, no new
    /// change entry) — the idempotence anchor.
    @discardableResult
    func put(_ text: String, id: CorpusContentID, now: Date) async throws -> CorpusContentRecord

    /// Remove canonical content and journal a remove change carrying the
    /// removed revision. Removing an absent ID is a no-op.
    func remove(id: CorpusContentID, now: Date) async throws
}
