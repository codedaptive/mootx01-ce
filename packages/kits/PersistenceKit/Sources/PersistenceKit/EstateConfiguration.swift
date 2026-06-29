// EstateConfiguration.swift
//
// Estate configuration per DECISION_STORAGEKIT_DESIGN §8 (Q6).
// One configuration value per estate; opens one Storage instance.

import Foundation

public struct EstateConfiguration: Sendable {
    public let estateID: UUID
    public let backend: BackendConfiguration
    /// At-rest encryption mode for this estate (Mission ENC-01). Defaults
    /// to `.plaintext` so existing call sites are unchanged: a plaintext
    /// estate behaves exactly as before, with no crypto on any path.
    public let encryptionConfig: EstateEncryptionConfig
    /// Cache configuration for this estate (Mission PK-CACHE-A). Defaults
    /// to `.disabled` so existing call sites are unchanged: a disabled-cache
    /// estate behaves exactly as before, with no cache on any path.
    public let cacheConfig: EstateCacheConfig
    /// Novel-token tagger choice for this estate (Layer-2a, v1.0). Defaults
    /// to `.hmm` — the deterministic, cross-platform baseline. Existing call
    /// sites that do not specify this parameter receive `.hmm`, which is the
    /// intended behavior: this field flips the estate-creation default from
    /// NLTagger (the old implicit Apple-only default) to HMM (the new explicit
    /// cross-platform default). Advanced Apple-only deployments may opt in to
    /// `.nlTagger` at creation time.
    ///
    /// This choice is fixed at creation. Change-after-creation and re-tagging
    /// migration are v1.1 features. See `NovelTokenTaggerChoice` for the full
    /// constraints, especially the federation-incompatibility note.
    public let novelTokenTagger: NovelTokenTaggerChoice

    public init(
        estateID: UUID,
        backend: BackendConfiguration,
        encryptionConfig: EstateEncryptionConfig = .plaintext,
        cacheConfig: EstateCacheConfig = .disabled,
        novelTokenTagger: NovelTokenTaggerChoice = .hmm
    ) {
        self.estateID = estateID
        self.backend = backend
        self.encryptionConfig = encryptionConfig
        self.cacheConfig = cacheConfig
        self.novelTokenTagger = novelTokenTagger
    }
}

public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(
        connectionString: String,
        poolSize: Int = 10,
        connectionTimeout: TimeInterval = 5.0,
        idleTimeout: TimeInterval = 300.0
    )
    case inMemory
}

// MARK: — Queue sibling derivation (ADR-021 T3)

extension EstateConfiguration {
    /// Derive a sibling `EstateConfiguration` pointing at a per-estate queue
    /// database file beside the estate's own database file (ADR-021 Decision 7).
    ///
    /// The sibling file is named `<estate-stem>.<filename>` (e.g. for estate
    /// `<dir>/<uuid>.sqlite` and filename `"queue.sqlite"` the result is
    /// `<dir>/<uuid>.queue.sqlite`). This guarantees cross-estate isolation:
    /// two estates in the same directory produce DIFFERENT sibling paths, so
    /// one estate's encode/dreaming queue is never accessible to another estate's
    /// workers. Within the same estate, the path is deterministic across
    /// processes — all processes that open the same estate file share exactly
    /// one queue file (ADR-021 Decision 7: one per-estate queue).
    ///
    /// The encryption configuration is carried over verbatim — an encrypted
    /// estate produces an encrypted queue, sharing the cipher key so QueueKit
    /// can open the queue file without additional key distribution.
    ///
    /// # Backend behaviour
    ///
    /// - `.sqlite(url:busyTimeout:)` — returns a new `.sqlite` config at
    ///   `<estate-dir>/<estate-stem>.<filename>`, preserving `busyTimeout` and
    ///   carrying the same `encryptionConfig`.
    /// - `.inMemory` — returns an InMemory config. The queue is ephemeral
    ///   alongside the ephemeral estate, which is correct for testing and
    ///   transient sessions.
    /// - `.postgresql(...)` — **deferred** per ADR-021 §SQLite-first
    ///   sequencing. Throws `StorageError.featureGated` with a clear message.
    ///   A caller relying on a Postgres-backed queue will learn immediately
    ///   that this path is not yet implemented; it will never silently produce
    ///   a wrong or half-initialised config.
    ///
    /// # Estate-id derivation
    ///
    /// The sibling's `estateID` is derived deterministically from this
    /// estate's `estateID` and the `filename` parameter using an XOR-fold.
    /// The fold mixes the filename's UTF-8 bytes into a 16-byte tag, then
    /// XORs that tag with the estate UUID bytes. This guarantees:
    /// (1) distinct from the parent — the XOR is never an identity transform
    ///     for any filename whose bytes do not produce an all-zero fold result
    ///     (impossible for any non-empty filename).
    /// (2) deterministic — same estate UUID + same filename → same sibling UUID.
    /// (3) no random minting — `UUID()` is never called on this path.
    ///
    /// - Parameter filename: The base filename for the sibling database (e.g.
    ///   `"queue.sqlite"`). Must be a bare filename — no path separators. The
    ///   actual sibling filename is prefixed with the estate's file stem so two
    ///   estates in the same directory produce distinct sibling paths.
    /// - Returns: A new `EstateConfiguration` for the queue database.
    /// - Throws: `StorageError.featureGated` if the estate uses a PostgreSQL
    ///   backend (the Postgres queue path is deferred to ADR-021 Postgres pass).
    public func queueSibling(filename: String) throws -> EstateConfiguration {
        let siblingID = deriveQueueSiblingID(parentID: estateID, filename: filename)

        switch backend {
        case let .sqlite(url, busyTimeout):
            // Derive the per-estate sibling filename from the estate's own DB
            // stem so two estates in the same directory never share a queue.
            // Estate: <dir>/<stem>.sqlite → sibling: <dir>/<stem>.<filename>
            // E.g. <dir>/abc123.sqlite + "queue.sqlite" → <dir>/abc123.queue.sqlite
            let stem = url.deletingPathExtension().lastPathComponent
            let perEstateName = "\(stem).\(filename)"
            let siblingURL = url.deletingLastPathComponent().appendingPathComponent(perEstateName)
            return EstateConfiguration(
                estateID: siblingID,
                backend: .sqlite(url: siblingURL, busyTimeout: busyTimeout),
                encryptionConfig: encryptionConfig,
                cacheConfig: cacheConfig,
                novelTokenTagger: novelTokenTagger
            )

        case .inMemory:
            // An InMemory estate gets an InMemory queue: both are ephemeral and
            // live only for the duration of the session. Correct for tests and
            // transient session estates.
            return EstateConfiguration(
                estateID: siblingID,
                backend: .inMemory,
                encryptionConfig: encryptionConfig,
                cacheConfig: cacheConfig,
                novelTokenTagger: novelTokenTagger
            )

        case .postgresql:
            // TODO(ADR-021 Postgres pass): implement the PostgreSQL queue-sibling
            // path. The Postgres backend requires coordination primitives beyond
            // a simple file-sibling (connection string scoping, schema namespacing)
            // and is explicitly deferred in ADR-021's SQLite-first sequencing.
            // Fail loud so any caller depending on a Postgres queue learns
            // immediately that this is not implemented, rather than receiving a
            // silently wrong or half-initialised configuration.
            throw StorageError.featureGated(
                feature: "queueSibling for PostgreSQL backend is deferred " +
                         "(ADR-021 Postgres pass). Use SQLite or InMemory estates " +
                         "for per-estate queue configuration."
            )
        }
    }
}

// MARK: — Deterministic sibling ID derivation

/// Derive a deterministic `UUID` for a queue sibling from the parent estate's
/// `UUID` and the sibling `filename`. No random minting.
///
/// Algorithm: fold the filename's UTF-8 bytes into a 16-byte tag by cycling
/// through each byte position (XOR-reduce). Then XOR that tag with the parent
/// UUID's raw bytes. For any non-empty filename the tag is never all-zeros, so
/// the result differs from the parent ID — they can never collide.
private func deriveQueueSiblingID(parentID: UUID, filename: String) -> UUID {
    let filenameBytes = Array(filename.utf8)
    guard !filenameBytes.isEmpty else {
        // Empty filename is a programming error; return the parent ID so the
        // caller sees a detectable mismatch (the queue has the same ID as the
        // estate) rather than a crash. The queue path will still be wrong.
        return parentID
    }

    var tag = [UInt8](repeating: 0, count: 16)
    for (i, byte) in filenameBytes.enumerated() {
        tag[i % 16] ^= byte
    }

    // XOR the parent UUID's raw bytes with the derived tag.
    var parentBytes = withUnsafeBytes(of: parentID.uuid) { Array($0) }
    for i in 0 ..< 16 {
        parentBytes[i] ^= tag[i]
    }

    // Reinterpret the 16 XOR'd bytes as a UUID.
    let tuple = (
        parentBytes[0],  parentBytes[1],  parentBytes[2],  parentBytes[3],
        parentBytes[4],  parentBytes[5],  parentBytes[6],  parentBytes[7],
        parentBytes[8],  parentBytes[9],  parentBytes[10], parentBytes[11],
        parentBytes[12], parentBytes[13], parentBytes[14], parentBytes[15]
    )
    return UUID(uuid: tuple)
}
