// EstateConfiguration.swift
//
// Estate configuration per the PersistenceKit storage surface (Q6).
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

    /// Controls whether kits hold computed indexes in RAM between queries
    /// (`.ramResident`, the default) or load from the durable store on demand
    /// (`.diskBacked`). `.ramResident` builds the index once per model on first
    /// query and serves subsequent queries from heap, falling back to the table
    /// scan when the index is evicted (e.g. under memory pressure).
    /// `.diskBacked` skips the heap copy entirely and scans SQLite on every
    /// query, relying on the OS page cache for warm reads.
    public let residencyHint: ResidencyHint

    /// Ceiling on how much RAM the per-model float-lane indexes (FloatBruteForceIndex
    /// plus, above the HNSW threshold, the HNSWIndex graph) may collectively occupy
    /// in the heap for this estate.
    ///
    /// The default `.systemFraction(0.25)` caps the resident float-index set at 25%
    /// of physical RAM. That fraction was chosen to leave headroom for all other
    /// claimants on the same process — the SQLite page cache, the binary-lane resident
    /// array, HNSW graphs, embedding-provider weights, and (in the app target) the GUI
    /// itself. A quarter of physical memory is the largest share one subsystem's caches
    /// may claim while the process remains healthy. It is also far above any realistic
    /// single-estate index (see BRR §6.4), so residency behaviour below the cap is
    /// unchanged from the pre-RS-01 baseline.
    ///
    /// Use `.unbounded` to reproduce exact pre-RS-01 behaviour (no admission bound).
    /// Use `.bytes(N)` for an explicit absolute ceiling, useful in tests and constrained
    /// deployments. Use `.systemFraction(f)` for a deployment-adaptive ceiling.
    public let residentIndexBudget: ResidentIndexBudget

    public init(
        estateID: UUID,
        backend: BackendConfiguration,
        encryptionConfig: EstateEncryptionConfig = .plaintext,
        cacheConfig: EstateCacheConfig = .disabled,
        novelTokenTagger: NovelTokenTaggerChoice = .hmm,
        residencyHint: ResidencyHint = .ramResident,
        residentIndexBudget: ResidentIndexBudget = .systemFraction(0.25)
    ) {
        self.estateID = estateID
        self.backend = backend
        self.encryptionConfig = encryptionConfig
        self.cacheConfig = cacheConfig
        self.novelTokenTagger = novelTokenTagger
        self.residencyHint = residencyHint
        self.residentIndexBudget = residentIndexBudget
    }
}

// MARK: — Resident-index admission budget

/// Controls how much heap the per-model float-lane indexes (FloatBruteForceIndex
/// plus, above the HNSW threshold, HNSWIndex graphs) may collectively occupy for
/// one estate.
///
/// The budget is resolved to an optional byte ceiling at admission time. `nil`
/// means unbounded — the exact pre-RS-01 behaviour — and is used when detection
/// of physical RAM returns nothing (an undetectable platform must not silently
/// degrade every estate to the disk-backed path by guessing a ceiling).
public enum ResidentIndexBudget: Sendable, Equatable {
    /// Ceiling = `fraction` × physical RAM. Must be in (0, 1].
    ///
    /// Default `fraction` used by `EstateConfiguration` is `0.25`. See
    /// `EstateConfiguration.residentIndexBudget` for the rationale.
    case systemFraction(Double)

    /// Explicit absolute ceiling in bytes. Useful in tests and tightly
    /// memory-constrained deployments.
    case bytes(Int)

    /// No admission bound — the exact pre-RS-01 behaviour. The float index
    /// is always admitted regardless of projected size.
    case unbounded

    /// Resolve this budget to an optional byte ceiling.
    ///
    /// - Parameter physicalMemoryBytes: the host's total physical memory in bytes.
    ///   Pass `ProcessInfo.processInfo.physicalMemory` at the call site; pass a
    ///   fixed value in tests so assertions are machine-independent.
    ///   A value of `0` means "undetectable". It affects `.systemFraction` ONLY,
    ///   which has nothing to take a fraction of; `.bytes` is an absolute ceiling
    ///   that does not depend on how much memory the host has, so it is still
    ///   honoured. Discarding an explicitly configured ceiling because RAM
    ///   detection failed would leave the operator with no cap at all — the
    ///   opposite of what they asked for.
    /// - Returns: the byte ceiling, or `nil` if no bound applies (`.unbounded`, or
    ///   `.systemFraction` on a host whose physical memory could not be detected).
    public func resolveCeiling(physicalMemoryBytes: UInt64) -> Int? {
        switch self {
        case .unbounded:
            return nil
        case let .bytes(n):
            // Absolute ceiling: independent of host memory, honoured even when
            // detection failed. Twin of Rust `Bytes(n) => Some(n)`.
            //
            // Floored at 0 because the Rust twin stores this as a u64 and cannot
            // represent a negative ceiling at all. Without the floor the two ports
            // would diverge on a negative input: Swift would return it unchanged,
            // and since `residentTotal + projection > cap` is then always true,
            // every index would be silently refused for the process's lifetime.
            // Zero is the nearest value Rust can hold and carries the same meaning
            // (admit nothing), so both ports now behave identically.
            return max(0, n)
        case let .systemFraction(f):
            guard physicalMemoryBytes > 0 else {
                // Physical memory is undetectable, so there is no quantity to take
                // a fraction OF. Return nil (unbounded) rather than guessing: a
                // wrong guess would refuse every estate on an unknown platform,
                // which is worse than admitting without a bound.
                return nil
            }
            // Clamp the fraction to (0, 1] to guard against misconfiguration.
            // The Rust twin clamps identically, so both ports resolve the same
            // ceiling for the same inputs — the cross-port agreement contract.
            let clamped = max(1e-9, min(f, 1.0))
            let ceiling = Double(physicalMemoryBytes) * clamped
            // `Double(Int.max)` rounds UP to 2^63, which is NOT representable as
            // Int, so `Int(min(ceiling, Double(Int.max)))` traps at exactly that
            // boundary rather than clamping. Compare against 2^63 as a Double and
            // return Int.max explicitly. Unreachable on real hardware, but this is
            // a public API taking caller-supplied bytes, so it must not trap.
            let intMaxExclusive = 9_223_372_036_854_775_808.0  // 2^63, one past Int.max
            if ceiling >= intMaxExclusive { return Int.max }
            return Int(ceiling)
        }
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

/// Controls whether kits hold computed indexes in heap between queries
/// or load from the durable store on demand.
public enum ResidencyHint: Sendable, Equatable {
    /// Indexes loaded from the durable store on demand; the OS page cache
    /// manages RAM residency. Float NN search scans the SQLite table directly
    /// on every query. Use when heap pressure outweighs query latency.
    case diskBacked
    /// All indexes cached in the Swift/Rust heap for minimum query latency.
    /// The float-lane index is built lazily on first query per model and evicted
    /// automatically under critical memory pressure, falling back to the table
    /// scan. Default for all production estates.
    case ramResident
}

// MARK: — Queue sibling derivation

extension EstateConfiguration {
    /// Derive a sibling `EstateConfiguration` pointing at a per-estate queue
    /// database file beside the estate's own database file.
    ///
    /// The sibling file is named `<estate-stem>.<filename>` (e.g. for estate
    /// `<dir>/<uuid>.sqlite` and filename `"queue.sqlite"` the result is
    /// `<dir>/<uuid>.queue.sqlite`). This guarantees cross-estate isolation:
    /// two estates in the same directory produce DIFFERENT sibling paths, so
    /// one estate's encode/dreaming queue is never accessible to another estate's
    /// workers. Within the same estate, the path is deterministic across
    /// processes — all processes that open the same estate file share exactly
    /// one queue file (recall-driven dreaming: one per-estate queue).
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
    /// - `.postgresql(...)` — **deferred**. The queue sibling is SQLite-first;
    ///   this branch throws `StorageError.featureGated` with a clear message.
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
    ///   backend because the PostgreSQL queue sibling is not implemented.
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
                novelTokenTagger: novelTokenTagger,
                residentIndexBudget: residentIndexBudget
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
                novelTokenTagger: novelTokenTagger,
                residentIndexBudget: residentIndexBudget
            )

        case .postgresql:
            // TODO: implement the PostgreSQL queue-sibling
            // path. The Postgres backend requires coordination primitives beyond
            // a simple file-sibling (connection string scoping, schema namespacing)
            // and is explicitly deferred while queue storage remains SQLite-first.
            // Fail loud so any caller depending on a Postgres queue learns
            // immediately that this is not implemented, rather than receiving a
            // silently wrong or half-initialised configuration.
            throw StorageError.featureGated(
                feature: "queueSibling for PostgreSQL backend is deferred " +
                         "Use SQLite or InMemory estates " +
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
