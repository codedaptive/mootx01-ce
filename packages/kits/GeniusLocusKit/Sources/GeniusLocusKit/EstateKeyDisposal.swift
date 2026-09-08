import Foundation
import MootProductIdentity
import OSLog
import LocusKit
import PersistenceKit

// EstateKeyDisposal.swift — Explicit teardown for estate key material.
//
// This file owns the two-step key-disposal path that was the MISSING HALF of
// the production incident (estate-key-lifetime, 2026-07-29):
//
//   Step 1: Delete the estate's Ed25519 identity key from the Keychain
//           (com.mootx01.estate.identity service, keyed by estate UUID string).
//           Corresponds to the `EstateIdentityKeyStore.deletePrivateKey` path.
//
//   Step 2: Delete the whole-file SQLCipher database key from the Keychain
//           through `EstateOpenPosture.disposeKey` (the estate key service,
//           keyed by estate file path hash; both the shared access group and
//           the default group). Only applies when the backing storage is a
//           SQLite file; in-memory and PostgreSQL estates never write a db
//           key to the Keychain.
//
// Both steps are IDEMPOTENT — a missing Keychain item is not an error. The
// method is safe to call on an estate that never had Keychain items (e.g. an
// in-memory estate that used InMemoryEstateIdentityKeyStore, or an estate whose
// keys were already disposed by a prior call or by DbDeleteCommand).
//
// CALL SITE CONTRACT
// ------------------
// `GeniusLocusKit.destroy()` calls `disposeEstateKeys` AFTER sub-store teardown
// (corpus + vector store) and BEFORE `close()`. This ordering ensures:
//   - The estate's manifest UUID is still readable from `handle.estateUUID` and
//     the storage is still open for the db-key URL derivation.
//   - `close()` releases the storage connection after the keys are disposed.
//
// Callers that permanently retire a durable estate outside of `destroy()` (e.g.
// `DbDeleteCommand`) call `EstateOpenPosture.disposeKey(databaseURL:)` for the
// db key and `KeychainEstateIdentityKeyStore.deletePrivateKey()` for the
// identity key, the same two steps this method performs.

#if canImport(PersistenceKitSQLite)
import PersistenceKitSQLite
#endif

public extension GeniusLocusKit {

    private static var disposalLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit.KeyDisposal")
    }

    /// Dispose the Keychain key material for a durable estate that is being
    /// permanently retired.
    ///
    /// This is the EXPLICIT TEARDOWN API that was the missing half of the
    /// production incident (2026-07-29): `destroy()` closed estates without
    /// cleaning up their Keychain items, so test loops that provisioned and
    /// destroyed thousands of estates left one orphaned Keychain item per estate.
    ///
    /// Two items are disposed:
    ///
    /// 1. **Identity key** — the estate's Ed25519 private signing key in the
    ///    `com.mootx01.estate.identity` service, keyed by the estate UUID string.
    ///    Deleted via `KeychainEstateIdentityKeyStore.deletePrivateKey`.
    ///
    /// 2. **Database key** — the whole-file SQLCipher key under
    ///    `MootProductIdentity.Keychain.estateKeyService`, keyed by the estate
    ///    file path hash. Deleted from both the shared access group and the
    ///    default group through `EstateOpenPosture.disposeKey`.
    ///    Only attempted when the backing storage is a `.sqlite(url:)` backend;
    ///    in-memory and PostgreSQL backends never write a db key to the Keychain.
    ///
    /// ## Idempotency
    ///
    /// Missing Keychain items are not errors. This method is safe to call:
    ///   - on an estate that used `InMemoryEstateIdentityKeyStore` (ephemeral
    ///     lifetime) — the identity delete is a no-op on the Keychain because
    ///     the key was never written there.
    ///   - multiple times on the same estate UUID.
    ///   - after the estate file has already been deleted from disk.
    ///
    /// ## Failure posture
    ///
    /// A Keychain error on the identity-key delete is thrown (the caller should
    /// log and continue). Db-key delete errors are logged as warnings and swallowed
    /// (same best-effort posture as `DbDeleteCommand`) because the data is already
    /// gone by the time `destroy()` calls this, and a Keychain error must not
    /// prevent `close()` from releasing the storage connection.
    ///
    /// - Parameters:
    ///   - handle: The estate handle whose keys should be disposed. The
    ///     `estateUUID` on the handle identifies the identity-key Keychain account.
    ///   - storage: The backing storage for the estate. Used to derive the
    ///     db-key Keychain account when the backend is `.sqlite(url:)`.
    func disposeEstateKeys(
        for handle: EstateHandle,
        storage: any Storage
    ) async throws {
        // Step 1: Delete the identity key from the Keychain.
        // The Keychain item is scoped to the estate UUID, so we do not need any
        // information about the backing file — only the UUID from the handle.
        #if canImport(Security)
        do {
            let identityStore = KeychainEstateIdentityKeyStore()
            try identityStore.deletePrivateKey(forEstateID: handle.estateUUID)
            Self.disposalLog.info(
                "disposeEstateKeys: identity key deleted for \(handle.estateUUID, privacy: .public)"
            )
        } catch {
            // Rethrow: if the Keychain itself is unavailable, the caller needs to
            // know. A missing item is NOT an error here (deletePrivateKey is
            // idempotent), so this only fires for a genuine Keychain failure.
            Self.disposalLog.error(
                "disposeEstateKeys: identity key deletion failed for \(handle.estateUUID, privacy: .public): \(error, privacy: .public)"
            )
            throw error
        }

        // Step 2: Delete the whole-file database key from the Keychain.
        // Only meaningful for SQLite-backed estates — an inMemory or PostgreSQL
        // estate never wrote a Keychain item for the db key, so we skip both
        // to avoid generating spurious Keychain queries on non-SQLite paths.
        if case .sqlite(let estateURL, _) = storage.configuration.backend {
            // Best effort: the data is already gone or being destroyed, so a
            // db-key Keychain error is a warning that must not prevent close()
            // from releasing the storage connection.
            let failures = EstateOpenPosture.disposeKey(databaseURL: estateURL)
            if failures.isEmpty {
                Self.disposalLog.info(
                    "disposeEstateKeys: db key deleted for \(handle.estateUUID, privacy: .public)")
            }
            for error in failures {
                Self.disposalLog.warning(
                    "disposeEstateKeys: db key deletion warning for \(handle.estateUUID, privacy: .public): \(error, privacy: .public)")
            }
        }
        #endif // canImport(Security)
    }
}
