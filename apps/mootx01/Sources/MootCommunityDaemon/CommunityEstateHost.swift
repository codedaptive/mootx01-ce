// CommunityEstateHost.swift
//
// Production EstateLifecycleAuthority for the MOOTx01 Community daemon.
//
// Wave A1a: the first production conformer of EstateLifecycleAuthority.
// DaemonProvider.activate() step 6 calls estate.openEstate() on whatever
// EstateLifecycleAuthority it was composed with; until this file existed,
// no production conformer existed (frozen package graph on MootDaemonProvider).
//
// This conformer is the composition root's responsibility to build. It does
// NOT acquire the ProviderLock — the provider's activate() already holds the
// lock before calling openEstate(). This host is solely responsible for:
//   1. Resolving encryption config via the injected key provider.
//   2. Opening (or creating on a fresh install) the SQLite estate via
//      LocusKit + PersistenceKitSQLite.
//   3. Returning the estate's true UUID and schema version as EstateReadyProof.
//   4. Caching the proof so subsequent openEstate() calls are idempotent.
//   5. Providing stub implementations of stopWrites/drain/checkpoint/closeEstate
//      for the MACD-3 handover path (not wired at this phase).
//
// CORE-01: fail closed on every error. An empty path is NOT permission to
// create a replacement estate. A missing key is NOT permission to open
// plaintext. A corrupt manifest is NOT a reason to re-initialize.

import Foundation
import OSLog
import MootDaemonProvider
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

private let log = Logger(subsystem: "com.mootx01", category: "CommunityEstateHost")

/// Production `EstateLifecycleAuthority` for the Community edition daemon.
///
/// Opens (or creates on a genuinely-fresh install) the real estate database
/// via LocusKit and PersistenceKitSQLite, returning `EstateReadyProof` with
/// the estate's true UUID and schema version.
///
/// ## Idempotency
/// `openEstate()` caches its result. Calling it twice on the same actor
/// instance returns the same proof without re-opening the file.
///
/// ## Fail-closed (CORE-01)
/// Every error from the key provider, the storage backend, or LocusKit
/// propagates to the caller. No fallback to plaintext. No "create fresh"
/// retry on a failed open.
///
/// ## Thread safety
/// Actor-isolated. All mutable state (cached proof, LocusKit estate actor,
/// SQLiteStorage) is accessed only on this actor's executor.
public actor CommunityEstateHost: EstateLifecycleAuthority {

    // MARK: - Injected dependencies

    /// Canonical path of the estate file (e.g. `<AppGroup>/MOOTx01/estate.sqlite`).
    /// The containing directory MUST exist before this host is called; the provider
    /// root layout (ProviderRootLayout) is responsible for creating it.
    private let estateURL: URL

    /// Provides the at-rest encryption configuration for the estate.
    ///
    /// Returns `EstateEncryptionConfig.plaintext` for unencrypted estates;
    /// `EstateEncryptionConfig.fullDatabase(key:)` for SQLCipher-encrypted ones.
    ///
    /// Called exactly once — on the first `openEstate()` call when no proof
    /// is cached. A throwing key provider fails the open (fail-closed; never
    /// fall back to plaintext).
    private let keyProvider: @Sendable (URL) throws -> EstateEncryptionConfig

    /// Owner identifier for the LocusKit `OwnerCredentials`. Must be non-empty
    /// (LocusKit enforces this); should be stable across daemon restarts so the
    /// manifest's owner field is consistent. The daemon shell supplies its
    /// service label, e.g. `"com.mootx01.daemon"`.
    private let ownerIdentifier: String

    // MARK: - Actor-isolated state

    /// Cached result of the first successful `openEstate()` call.
    /// Non-nil once the estate is open; subsequent calls return this immediately.
    private var cachedProof: EstateReadyProof?

    /// The live LocusKit estate. Kept alive so the underlying SQL connection
    /// stays open; released in `closeEstate()`.
    private var openEstate_: Estate?

    /// The underlying SQLiteStorage. Kept alive so the WAL connection and any
    /// open transactions stay live; released in `closeEstate()`.
    private var storage_: SQLiteStorage?

    // MARK: - Init

    /// Construct a host for the estate at `estateURL`.
    ///
    /// - Parameters:
    ///   - estateURL: Absolute path to the estate file.
    ///   - ownerIdentifier: Non-empty daemon service label for OwnerCredentials.
    ///   - keyProvider: Closure that returns the encryption config for `estateURL`.
    public init(
        estateURL: URL,
        ownerIdentifier: String,
        keyProvider: @Sendable @escaping (URL) throws -> EstateEncryptionConfig
    ) {
        self.estateURL = estateURL
        self.ownerIdentifier = ownerIdentifier
        self.keyProvider = keyProvider
    }

    // MARK: - EstateLifecycleAuthority

    /// Open (or create on a fresh install) the estate and return its identity proof.
    ///
    /// Idempotent: if the estate is already open, the cached proof is returned
    /// without re-opening the file.
    ///
    /// Fail-closed (CORE-01): any error from the key provider, the storage backend,
    /// or LocusKit propagates directly. No fallback. No retry.
    public func openEstate() async throws -> EstateReadyProof {
        // Fast path: estate already open — return cached proof immediately.
        // This makes the call idempotent for the provider's step 6 (activate)
        // and the handover's open-on-target-side call.
        if let proof = cachedProof { return proof }

        // 1. Resolve encryption config. Fail-closed: a throwing key provider
        //    means the estate cannot be opened safely.
        let encConfig = try keyProvider(estateURL)

        // 2. Build the PersistenceKit storage configuration.
        //    `estateID` here is the STORAGE-LAYER identity (a UUID that names
        //    this open instance in PersistenceKit's internal bookkeeping); it is
        //    NOT the LocusKit manifest UUID. A new UUID() per call is intentional
        //    and correct: the storage-layer ID is not persisted anywhere and has
        //    no meaning across process restarts. The manifest UUID (the true estate
        //    identity) is read from the database after open.
        let storageConfig = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: encConfig
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: storageConfig)
        } catch {
            // Throw directly — do not wrap. The caller (DaemonProvider) logs the
            // underlying StorageError, which carries enough context. Wrapping
            // would lose the structured error type.
            throw error
        }

        // 3. Open the estate via LocusKit.
        //    `Estate.open` internally calls `DrawerStore(storage:)`, which runs
        //    `storage.open(schema: LocusKitSchema.declaration)` — this is where
        //    schema migrations are applied. On a fresh install, `SQLITE_OPEN_CREATE`
        //    inside SQLiteStorage creates the file; the manifest and schema tables
        //    are seeded by the migration.
        //
        //    `InMemoryEstateIdentityKeyStore` is used because this daemon host
        //    does not own the estate's Ed25519 federation keypair — that is a
        //    federation-layer concern (MACD-3 scope). The in-memory store mints
        //    a fresh ephemeral keypair on each open, which is acceptable because
        //    the `EstateReadyProof` carries only the estate UUID and schema version
        //    (not the keypair). The Keychain store (KeychainEstateIdentityKeyStore)
        //    is for apps that need the persistent signing identity across launches.
        let locusEstate: Estate
        do {
            locusEstate = try await Estate.open(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: ownerIdentifier),
                identityKeyStore: InMemoryEstateIdentityKeyStore()
            )
        } catch {
            // Any LocusKit error (EstateError.manifestMismatch, substrateUnavailable,
            // etc.) is a fail-closed condition: the estate is not openable as-is.
            // Do NOT suppress or retry.
            throw error
        }

        // 4. Read the integer schema version for EstateReadyProof.
        //    `currentSchemaVersion()` returns the highest migration version applied
        //    across all kits sharing this storage (e.g. 13 for LocusKit migrations
        //    through the current schema). The `UInt64` cast is safe: a negative
        //    schema version is a LocusKit internal bug (migrations are forward-only),
        //    not a corrupt estate file.
        let version = try await storage.currentSchemaVersion()
        guard version >= 0 else {
            throw CommunityDaemonError.unexpectedSchemaVersion(version)
        }

        // `estateUUID` is an actor-isolated property on `Estate`; await the read
        // on the LocusKit estate actor's executor.
        let estateUUID = await locusEstate.estateUUID
        let proof = EstateReadyProof(
            estateIdentifier: estateUUID,
            schemaVersion: UInt64(version)
        )

        // 5. Cache all live objects before returning so they stay alive and
        //    subsequent openEstate() calls can use the fast-path.
        self.openEstate_ = locusEstate
        self.storage_ = storage
        self.cachedProof = proof

        log.debug("estate opened: uuid=\(proof.estateIdentifier) schema=\(proof.schemaVersion)")
        return proof
    }

    /// Stop new writes to the estate. Handover step 3 (MACD-3 scope).
    ///
    /// Production write-quiescence will be wired here when the MACD-3 migration
    /// routing mission lands. At this phase the daemon is the sole writer and
    /// `DaemonProvider.activate()` calls this before draining; no concurrent
    /// writers exist.
    public func stopWrites() async throws {
        // MACD-3: wire up write quiescence (drain the write queue, mark the estate
        // read-only) here. The production DAG: stopWrites → drain → checkpoint →
        // closeEstate — this stub satisfies the protocol so the provider compiles
        // and the handover state machine can be exercised with fakes.
    }

    /// Drain in-flight work after writes stop. Handover step 4 (MACD-3 scope).
    public func drain() async throws {
        // MACD-3: drain in-flight async work items here.
    }

    /// Checkpoint the WAL after draining. Handover step 5 (MACD-3 scope).
    public func checkpoint() async throws {
        // MACD-3: run a TRUNCATE checkpoint so the target provider can open a
        // WAL-empty estate. Use CommunitySourceEstateAccess.checkpointTruncate()
        // here once the handover path is wired.
    }

    /// Close the estate. Handover step 6.
    ///
    /// Closes the underlying SQLiteStorage (which closes the WAL connection)
    /// and clears the cached proof. After this call the host is safe to drop.
    /// Calling `openEstate()` again after `closeEstate()` will re-open the estate.
    public func closeEstate() async throws {
        guard let storage = storage_ else {
            // Nothing to close (never opened, or already closed). Idempotent.
            return
        }
        await storage.close()
        storage_ = nil
        openEstate_ = nil
        cachedProof = nil
        log.debug("estate closed: \(self.estateURL.lastPathComponent)")
    }
}
