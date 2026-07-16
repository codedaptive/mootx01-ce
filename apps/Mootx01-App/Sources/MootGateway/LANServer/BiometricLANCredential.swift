import Foundation
import Security
import MootIntentKit

// MARK: - Owner-presence credential  (Bob's ruling 2026-07-11)
//
// The LAN credential must validate against the phone's unlock system, not
// just compare strings in-app. Implementation: the bearer token lives in a
// Keychain item protected by SecAccessControl(.userPresence) — reading it
// triggers Face ID / Touch ID / device passcode (the same credential that
// unlocks iCloud on this device). Starting the LAN server therefore IS an
// owner-presence validation; a thief with the phone unlocked-but-not-owner
// still faces the biometric when they try to serve the estate.
//
// The provider seam keeps MootLANServer testable: the real store prompts;
// tests inject a mock. The plaintext app-group LANCredentialStore remains
// only as the explicit fallback for environments with no Keychain UI
// (headless tests); production resolution goes through the biometric store.
//
// Why not PersistenceKit.KeychainKeyStore (validated 2026-07-11): that store
// (MootBridge uses it for the SQLCipher estate key) has access-group support
// and is the right generic keychain wrapper, but it — and every keychain
// store in the tree, incl. LocusKit.EstateIdentityKeyStore — is SILENT
// after-first-unlock. Bob's ruling requires the `.userPresence` gate that no
// kit store provides, so this biometric variant is genuinely new, not a
// reinvention of KeychainKeyStore.

/// Resolves the LAN credential, performing whatever owner validation the
/// implementation requires. Throwing means the owner did not authenticate.
public protocol LANCredentialProviding: Sendable {
    func resolve() async throws -> LANCredential
}

public enum LANCredentialError: Error, CustomStringConvertible {
    case ownerAuthenticationFailed(String)
    case keychainFailure(OSStatus)

    public var description: String {
        switch self {
        case .ownerAuthenticationFailed(let why):
            return "Owner authentication failed: \(why)"
        case .keychainFailure(let status):
            return "Keychain error \(status) while resolving the LAN credential."
        }
    }
}

/// The production credential store: token behind .userPresence access
/// control, device-only (never synced or backed up onto another device —
/// the credential names THIS host).
public struct BiometricLANCredentialStore: LANCredentialProviding {

    static let service = "com.codedaptive.mootx01.lan-credential"
    static let account = "lan-bearer"

    public init() {}

    /// Read the token (triggers the system unlock prompt); mint and store a
    /// fresh one on first use. Minting does not prompt — only reads do.
    public func resolve() async throws -> LANCredential {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String:
                String(localized: "server.auth.prompt",
                       defaultValue: "Authenticate to serve your MOOT estate on the local network."),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw LANCredentialError.keychainFailure(errSecDecode)
            }
            return LANCredential(token: token)
        case errSecItemNotFound:
            return try mint()
        case errSecUserCanceled, errSecAuthFailed:
            throw LANCredentialError.ownerAuthenticationFailed("unlock canceled or failed")
        default:
            // Interaction disallowed, entitlement missing, etc. — name it.
            query.removeValue(forKey: kSecUseOperationPrompt as String)
            throw LANCredentialError.keychainFailure(status)
        }
    }

    /// Replace the credential (invalidates every existing client). Deletes
    /// then re-mints; the next resolve() prompts as usual.
    @discardableResult
    public func regenerate() throws -> LANCredential {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return try mint()
    }

    private func mint() throws -> LANCredential {
        let credential = LANCredential.generate()
        var error: Unmanaged<CFError>?
        // .userPresence = biometric with passcode fallback — the device
        // unlock system, exactly the validation Bob asked for.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw LANCredentialError.keychainFailure(errSecParam)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(credential.token.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LANCredentialError.keychainFailure(status)
        }
        return credential
    }
}

/// The headless fallback: the file-based store as a provider. Used by tests
/// and by environments with no Keychain UI. Production uses the biometric
/// store; choosing this in the app would bypass Bob's owner-presence rule.
extension LANCredentialStore: LANCredentialProviding {
    public func resolve() async throws -> LANCredential {
        loadOrCreate()
    }
}
