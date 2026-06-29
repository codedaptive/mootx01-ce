import Foundation
import Security

/// Protocol for persisting the estate's Ed25519 private signing key outside the
/// manifest table. The production implementation writes to and reads from the
/// Keychain (kSecClassGenericPassword, device-bound). Tests inject
/// `InMemoryEstateIdentityKeyStore` to avoid Keychain entitlement requirements
/// and cross-test Keychain pollution.
///
/// All conforming types must be `Sendable` because `Estate` (a Swift actor)
/// stores a key-store instance and accesses it from the actor's isolation domain.
///
/// Keychain item attributes used by `KeychainEstateIdentityKeyStore`:
///   - `kSecClass`: kSecClassGenericPassword
///   - `kSecAttrService`: "com.mootx01.estate.identity"
///   - `kSecAttrAccount`: the estate UUID string (stable across process restarts)
///   - `kSecAttrAccessible`: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
///
/// This ensures the signing key is device-bound, never leaves the device in a
/// backup or iCloud Keychain sync, and is available as soon as the device has
/// been unlocked once after a restart — matching the accessibility posture of
/// the estate itself (which cannot be opened from SQLite without device access).
public protocol EstateIdentityKeyStore: Sendable {

    /// Load the raw 32-byte Curve25519 private signing key bytes for the given
    /// estate UUID, or nil if no key has been stored yet (e.g. after a Keychain
    /// wipe, or on first open of an estate that pre-dates the Keychain migration).
    func loadPrivateKey(forEstateID estateID: UUID) throws -> Data?

    /// Persist the raw 32-byte Curve25519 private signing key bytes for the given
    /// estate UUID. A second call for the same UUID overwrites the previous value.
    func storePrivateKey(_ keyData: Data, forEstateID estateID: UUID) throws
}

// MARK: - Keychain implementation (production)

/// Keychain-backed identity key store.
///
/// Each estate's Ed25519 private signing key is stored as a
/// `kSecClassGenericPassword` item keyed by the estate UUID string.
/// Items are accessible after the first device unlock (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
/// so the key survives device restarts without requiring an interactive
/// unlock on every access — while still being device-bound and absent from
/// iCloud Keychain sync.
///
/// Both `loadPrivateKey` and `storePrivateKey` are synchronous; the Security
/// framework's `SecItem*` family does not dispatch asynchronously on macOS/iOS.
public struct KeychainEstateIdentityKeyStore: EstateIdentityKeyStore {

    // The Keychain service name that scopes all estate identity keys.
    // kSecAttrAccount (the estate UUID string) distinguishes individual estates
    // within this service. Matching the service name used in ADR-007.
    private static let service = "com.mootx01.estate.identity"

    public init() {}

    public func loadPrivateKey(forEstateID estateID: UUID) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: estateID.uuidString,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // errSecItemNotFound means the key was never stored — not an error.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw EstateError.keychainError(status: Int32(status))
        }
        guard let data = item as? Data else {
            // The Keychain returned something that isn't a Data blob — treat
            // as a decode failure rather than silently returning wrong bytes.
            throw EstateError.keychainError(status: Int32(errSecDecode))
        }
        return data
    }

    public func storePrivateKey(_ keyData: Data, forEstateID estateID: UUID) throws {
        let attributes: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: estateID.uuidString,
            // Device-bound; never synced to iCloud Keychain; available after
            // first unlock post-restart. This matches the estate's own security
            // posture: the SQLite file is encrypted and device-bound, so the
            // signing key's accessibility should be the same.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String:   keyData,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Key already present — update in place. This handles the case where
            // the same estate UUID is opened on two different InMemoryStorage
            // instances in tests, or where the migration path encounters an estate
            // that already has a Keychain entry (idempotent open).
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: estateID.uuidString,
            ]
            let update: [String: Any] = [kSecValueData as String: keyData]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EstateError.keychainError(status: Int32(updateStatus))
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw EstateError.keychainError(status: Int32(addStatus))
        }
    }
}

// MARK: - In-memory implementation (tests)

/// In-memory identity key store for use in tests.
///
/// Avoids Keychain entitlement requirements and cross-test Keychain pollution.
/// Each test that needs to inspect the stored key passes its own
/// `InMemoryEstateIdentityKeyStore` instance to `Estate.open`, then calls
/// `_storedPrivateKey(forEstateID:)` after the estate is closed to assert
/// the key was persisted to the store rather than the manifest table.
///
/// `@unchecked Sendable`: an `NSLock` serialises all dictionary mutations;
/// the `Dictionary<UUID, Data>` is never accessed concurrently without the
/// lock held. `NSLock` is safe to use from Swift concurrency (non-isolated
/// usage, never held across suspension points).
public final class InMemoryEstateIdentityKeyStore: EstateIdentityKeyStore, @unchecked Sendable {

    private var store: [UUID: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func loadPrivateKey(forEstateID estateID: UUID) throws -> Data? {
        lock.withLock { store[estateID] }
    }

    public func storePrivateKey(_ keyData: Data, forEstateID estateID: UUID) throws {
        lock.withLock { store[estateID] = keyData }
    }

    /// TEST-ONLY — read back the stored private key bytes for inspection.
    /// Only call from test code. Never call from production paths.
    public func _storedPrivateKey(forEstateID estateID: UUID) -> Data? {
        lock.withLock { store[estateID] }
    }
}
