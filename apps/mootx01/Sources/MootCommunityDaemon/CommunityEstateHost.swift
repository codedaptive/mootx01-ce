// CommunityEstateHost.swift
//
// The community daemon's one estate opener, and the production
// EstateLifecycleAuthority behind the provider's readiness proof.
//
// The daemon's estate is the catalog's active record (Bob, 2026-09-08;
// DECISION_INSTALL_TAKEOVER_2026-09-08 for where the catalog lives). The host
// opens that record once through GeniusLocusKit, the way `mootx01 serve` and
// aria-mcp open theirs: the shared at-rest posture decides the key, the
// migration catalog's prepare step runs, the Corpus, VectorStore and encode
// queue are wired on the same storage, the derived matrix tier is rebuilt and
// the manifest is refreshed. Every coordinator that needs the estate reaches
// it through this host: the lifecycle, capture and review coordinators take
// the LocusKit estate from the open handle, Obsidian sync and transfer take
// the kit and the handle. One open, one connection, one estate.
//
// DaemonProvider.activate() step 6 calls openEstate() on whatever
// EstateLifecycleAuthority it was composed with. This host does NOT acquire
// the ProviderLock — the provider's activate() already holds the lock.
//
// CORE-01: fail closed on every error. A missing key is NOT permission to
// open plaintext (the posture refuses a ciphertext file whose key is gone).
// A corrupt file is NOT a reason to re-initialise. An absent file is created
// only because the record names it: the catalog, not a path, is the authority.

import Foundation
import MootProductIdentity
import OSLog
import MootDaemonProvider
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "MootCommunityDaemon.EstateHost")

/// Production `EstateLifecycleAuthority` for the Community edition daemon,
/// and the daemon's shared estate access.
///
/// ## Idempotency
/// `openEstate()` caches its result. Calling it twice on the same actor
/// instance returns the same proof without re-opening the file.
///
/// ## Fail-closed (CORE-01)
/// Every error from the posture, the storage backend or GeniusLocusKit
/// propagates to the caller. No fallback to plaintext. No "create fresh"
/// retry on a failed open.
public actor CommunityEstateHost: EstateLifecycleAuthority {

    // MARK: - Configuration

    /// The catalog record this host opens. A registered record is the
    /// machine's estate (Keychain key, Keychain identity, federation); a
    /// transient record is plaintext with its identity in memory.
    public let record: EstateRecord

    /// The kit the estate is open in. Coordinators that compose on
    /// GeniusLocusKit (Obsidian sync, transfer) share it.
    public let kit: GeniusLocusKit

    /// Owner identifier for the LocusKit `OwnerCredentials`. Must be non-empty
    /// (LocusKit enforces this) and stable across daemon restarts so the
    /// manifest's owner field is consistent.
    private let ownerIdentifier: String

    /// Identity custody override. When given it is used for either record
    /// kind (a test observes the one key minted into it). When nil, the record
    /// kind decides: nil to the kit for a registered record, so the backend
    /// resolves the Keychain; an in-memory store for a transient record, so no
    /// test or proof host leaves Keychain residue.
    private let identityKeyStore: (any EstateIdentityKeyStore)?

    // MARK: - Actor-isolated state

    /// Cached result of the first successful `openEstate()` call.
    private var cachedProof: EstateReadyProof?

    /// The open in flight, when one is. `openEstate()` suspends at several
    /// awaits and the actor is re-entrant at each of them, so a second caller
    /// arriving before `cachedProof` is set would otherwise start a second
    /// open of the same file. The second caller awaits this task instead and
    /// receives the same proof, or the same error. Cleared when the task
    /// settles, so a failed open can be retried by an explicit call.
    private var opening: Task<EstateReadyProof, Error>?

    /// The open handle and its storage, kept until `closeEstate()`.
    private var openHandle: EstateHandle?
    private var storage_: SQLiteStorage?

    // MARK: - Init

    /// - Parameters:
    ///   - record: The catalog record to open.
    ///   - kit: The GeniusLocusKit the estate is opened in.
    ///   - ownerIdentifier: Non-empty daemon service label for OwnerCredentials.
    ///   - identityKeyStore: Custody override for the estate identity. nil
    ///     follows the record kind: the Keychain for a registered record, an
    ///     in-memory store for a transient one.
    public init(
        record: EstateRecord,
        kit: GeniusLocusKit,
        ownerIdentifier: String,
        identityKeyStore: (any EstateIdentityKeyStore)? = nil
    ) {
        self.record = record
        self.kit = kit
        self.ownerIdentifier = ownerIdentifier
        self.identityKeyStore = identityKeyStore
    }

    // MARK: - Shared access

    /// The open handle, opening the estate first when needed.
    public func handle() async throws -> EstateHandle {
        _ = try await openEstate()
        guard let openHandle else { throw CommunityDaemonError.estateAbsent(record.databaseURL) }
        return openHandle
    }

    /// The LocusKit estate behind the open handle, for the coordinators that
    /// work in LocusKit terms (rooms, drawers, capture, archive).
    public func estate() async throws -> LocusKit.Estate {
        try await kit.estate(for: handle())
    }

    /// True when the record's database file exists. The lifecycle contract's
    /// CORE-01 gates read this: inspect never creates the file, and capture
    /// or review never create it as a side effect.
    public nonisolated var databaseExists: Bool {
        FileManager.default.fileExists(atPath: record.databaseURL.path)
    }

    // MARK: - EstateLifecycleAuthority

    /// Open (or create on a fresh record) the estate and return its identity proof.
    public func openEstate() async throws -> EstateReadyProof {
        if let proof = cachedProof { return proof }
        if let opening { return try await opening.value }
        let task = Task { try await self.performOpen() }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    /// The open itself. Runs once per open; `openEstate()` serialises callers
    /// onto it through `opening`.
    private func performOpen() async throws -> EstateReadyProof {
        // 1. The at-rest posture: the one decision every opener makes. A
        //    registered record is created encrypted and loads its EXISTING key
        //    on reopen, failing closed when the key is missing; a transient
        //    record is plaintext.
        let resolved = try EstateOpenPosture.resolve(for: record)
        let isFirstRun = !databaseExists

        // 2. The storage. `estateID` is the storage-layer identity of this open
        //    instance, not the LocusKit manifest UUID, which is read after open.
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: record.databaseURL, busyTimeout: 5.0),
            encryptionConfig: resolved.encryption
        ))
        let owner = OwnerCredentials(ownerIdentifier: ownerIdentifier)

        // 3. Open through the kit. A fresh record is created first, as serve
        //    does; an existing file is opened, never re-initialised. The
        //    identity store follows the record kind; the daemon's estate
        //    federates.
        let keyStore: (any EstateIdentityKeyStore)? = identityKeyStore
            ?? (record.kind == .registered ? nil : InMemoryEstateIdentityKeyStore())
        await kit.setModelDirectoryResolver(
            BundledModelDirectoryResolver(dataDirectory: EstateCatalog.configurationDirectory))
        if isFirstRun {
            _ = try await Estate.create(storage: storage, owner: owner)
        }
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: keyStore, federate: true)
        if isFirstRun {
            try await kit.provisionDefaultEncoderIfAbsent(for: handle)
        }
        // 4. The same post-open sequence as every other opener: prepare, wire
        //    the Corpus, VectorStore and encode queue on this storage, rebuild
        //    the derived matrix tier, and make the manifest say what is on disk.
        let preparation = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
        try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        try await kit.rebuildDerivedAccelerators(for: handle)
        try EstateManifestRefresh.afterPrepare(preparation, estate: record, encryption: resolved.encryption, now: Date())

        // 5. The proof: the estate's UUID and the highest migration version
        //    applied across the kits sharing this storage.
        let version = try await storage.currentSchemaVersion()
        guard version >= 0 else { throw CommunityDaemonError.unexpectedSchemaVersion(version) }
        let proof = EstateReadyProof(estateIdentifier: handle.estateUUID, schemaVersion: UInt64(version))

        openHandle = handle
        storage_ = storage
        cachedProof = proof
        log.debug("estate opened: record=\(self.record.name, privacy: .public) uuid=\(proof.estateIdentifier) schema=\(proof.schemaVersion)")
        return proof
    }

    /// Stop new writes to the estate. Handover step 3 (MACD-3 scope).
    ///
    /// Production write-quiescence will be wired here when the MACD-3 migration
    /// routing mission lands. At this phase the daemon is the sole writer and
    /// `DaemonProvider.activate()` calls this before draining; no concurrent
    /// writers exist.
    public func stopWrites() async throws {
        // MACD-3: drain the write queue and mark the estate read-only. The
        // production DAG: stopWrites → drain → checkpoint → closeEstate.
    }

    /// Drain in-flight work after writes stop. Handover step 4 (MACD-3 scope).
    public func drain() async throws {
        // MACD-3: drain in-flight async work items here.
    }

    /// Checkpoint the WAL after draining. Handover step 5 (MACD-3 scope).
    public func checkpoint() async throws {
        // MACD-3: run a TRUNCATE checkpoint so the target provider can open a
        // WAL-empty estate (CommunitySourceEstateAccess.checkpointTruncate()).
    }

    /// Close the estate. Handover step 6.
    ///
    /// Closes the estate through the kit (which closes the storage and the
    /// WAL connection) and clears the cached proof. Idempotent; `openEstate()`
    /// afterwards re-opens.
    public func closeEstate() async throws {
        guard let handle = openHandle else { return }
        try await kit.close(handle)
        openHandle = nil
        storage_ = nil
        cachedProof = nil
        log.debug("estate closed: record=\(self.record.name, privacy: .public)")
    }
}
