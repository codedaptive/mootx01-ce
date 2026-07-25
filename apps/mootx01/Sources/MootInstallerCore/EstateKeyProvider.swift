// EstateKeyProvider.swift
//
// The Swift analogue of Rust's `aria_mcp::ensure_install_key`: one place that
// provisions an estate's whole-database encryption key, with Rust's fail-closed
// discipline.
//
// WHY THIS EXISTS — IT IS A SHIPPED PARITY BREAK, NOT A MISSING FEATURE
// macOS release artifacts are built with `swift build --product mootx01`, and
// before CE-1.0.35 the string `encryptionConfig` appeared ZERO times anywhere in
// apps/mootx01. Every Swift estate opener therefore took the `.plaintext`
// default. Linux and Windows ship the Rust binary, which calls
// `ensure_install_key` before opening and aborts if it cannot, so those
// platforms were encrypted at rest while macOS was not. SECURITY.md promised
// encryption on all platforms. Rust is the reference implementation; Swift
// matches it here.
//
// KEY CUSTODY DIFFERS BY PLATFORM, DELIBERATELY
// Apple platforms hold the key as a Keychain generic-password item, scoped
// per-estate by hashing the estate's standardized path into the account name.
// Rust achieves the same per-estate scoping with a `db.key` file inside the
// estate's own directory. Neither wraps the key in the Secure Enclave; see the
// SECURITY.md language in CE-1.0.35-09, which was corrected to stop implying it.
//
// FAIL CLOSED
// Every path either returns 32 key bytes or throws. There is no path that
// returns nil, and no path that falls back to plaintext. A caller that cannot
// get a key must abort rather than silently open an unencrypted estate — that
// silent fallback is the exact defect this file exists to prevent.

import Foundation

#if canImport(Security)
import Security
#endif

#if canImport(PersistenceKitSQLite)
import PersistenceKitSQLite
#endif

/// Provisions the whole-database encryption key for an estate file.
public enum EstateKeyProvider {

    /// Keychain service shared by every mootx01 surface that opens an estate:
    /// the CLI, the managed server, and Mootx01-App. Must match the value
    /// MootBridge and DbCommand already use, or the same estate would resolve
    /// two different keys.
    public static let keychainService = "com.codedaptive.mootx01"

    /// Shared Keychain access group (#94). Both the app and a separately-spawned
    /// managed server must read the SAME item for the same estate.
    public static let sharedAccessGroup = "com.codedaptive.mootx01.shared"

    /// Number of key bytes SQLCipher is configured with.
    public static let keyByteCount = 32

    // MARK: - Errors

    public enum KeyProviderError: Error, CustomStringConvertible {
        /// The Keychain refused the operation. Carries the underlying text so a
        /// command can print something actionable before aborting.
        case keychainUnavailable(String)
        /// The Keychain returned something that is not a usable key.
        case malformedKey(count: Int)
        /// This platform has no Keychain. Reached only if the Swift binary is
        /// built for a non-Apple platform; Linux and Windows ship the Rust
        /// binary, which uses the file-based key instead.
        case unsupportedPlatform

        public var description: String {
            switch self {
            case let .keychainUnavailable(detail):
                return "estate encryption key unavailable from the Keychain: \(detail)"
            case let .malformedKey(count):
                return "estate encryption key is malformed: expected \(EstateKeyProvider.keyByteCount) bytes, got \(count)"
            case .unsupportedPlatform:
                return "estate encryption key custody is not available on this platform"
            }
        }
    }

    // MARK: - Key provision

    /// Return the 32-byte whole-database key for `estateURL`, creating and
    /// storing one if none exists.
    ///
    /// Mirrors Rust's posture: THROWS on any Keychain failure and NEVER returns
    /// a nil key or falls back to plaintext. The caller aborts.
    ///
    /// Legacy access group: estates created before #94 stored their key in the
    /// DEFAULT access group rather than the shared one. This resolves an
    /// existing legacy key instead of minting a second key for the same estate,
    /// the same both-groups treatment DbCommand's delete path applies. Order
    /// matters — the shared group is checked FIRST so a migrated estate keeps
    /// using its shared item.
    public static func provideKey(for estateURL: URL) throws -> Data {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        let account = KeychainKeyStore.estateAccount(for: estateURL)

        // Read-only probes, in precedence order. These do NOT create anything,
        // which is the whole point: calling loadOrCreateKey() on the shared
        // group first would MINT a new key for a pre-#94 estate whose real key
        // sits in the default group, and the estate would then fail to open with
        // a brand-new wrong key. KeychainKeyStore.readKey() is private, so the
        // probe is done here with the same query shape KeychainKeyStore uses
        // (generic password, same service, same account). The account string
        // itself comes from KeychainKeyStore.estateAccount so the derivation is
        // never duplicated.
        for accessGroup in [sharedAccessGroup, nil] as [String?] {
            if let existing = try probeExistingKey(account: account, accessGroup: accessGroup) {
                return existing
            }
        }

        // Neither group holds a key: this is a new estate. Mint into the SHARED
        // group so the app and the managed server can both reach it.
        do {
            let key = try KeychainKeyStore(
                service: keychainService,
                estateURL: estateURL,
                accessGroup: sharedAccessGroup
            ).loadOrCreateKey()
            guard key.count == keyByteCount else {
                throw KeyProviderError.malformedKey(count: key.count)
            }
            return key
        } catch let error as KeyProviderError {
            throw error
        } catch {
            // Fail closed. Any Keychain error becomes a thrown error, never a
            // plaintext fallback.
            throw KeyProviderError.keychainUnavailable("\(error)")
        }
        #else
        throw KeyProviderError.unsupportedPlatform
        #endif
    }

    #if canImport(Security) && canImport(PersistenceKitSQLite)
    /// Read an existing key without creating one. Returns nil when the item is
    /// absent; throws when the Keychain itself fails, so a locked or broken
    /// Keychain is never mistaken for "no key yet" (which would mint a second
    /// key over a real one).
    private static func probeExistingKey(
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else {
                throw KeyProviderError.malformedKey(count: 0)
            }
            guard data.count == keyByteCount else {
                throw KeyProviderError.malformedKey(count: data.count)
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement:
            // An unsigned or wrongly-entitled build cannot see the shared access
            // group. Treat it as absent for THIS group so the default-group
            // probe and the mint path can still run; a genuinely unavailable
            // Keychain surfaces from loadOrCreateKey instead. Without this, every
            // unsigned local build would hard-fail before reaching its own key.
            return nil
        case let other:
            throw KeyProviderError.keychainUnavailable(
                "SecItemCopyMatching failed (\(other)) for access group \(accessGroup ?? "default")")
        }
    }
    #endif

    /// True when this platform can provide an estate key at all. Tests that
    /// depend on the Keychain skip rather than fail where it is unavailable, so
    /// Linux CI stays green.
    public static var isKeyCustodyAvailable: Bool {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        return true
        #else
        return false
        #endif
    }
}
