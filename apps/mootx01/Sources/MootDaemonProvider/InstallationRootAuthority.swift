import Foundation
import AriaMCP
#if canImport(Security)
import Security
#endif

// MARK: - MACD-2c1 — K_install custody (Perkins P5)
//
// AriaMcpKit's DataProtectionKeychainRootProvider can only READ the
// installation root — its no-SecItemAdd invariant is load-bearing and stays
// intact. The MINT lives here, in the provider, and nowhere else, because
// only the provider can prove the two preconditions a mint requires:
// a positive eligibility judgment and the held exclusive provider lock.
//
// The fatal-vs-absence matrix is the heart of this file:
// errSecMissingEntitlement, corruption, a locked/unavailable Keychain, and a
// read-back disagreement are FATAL — never treated as absence. Only a genuine
// errSecItemNotFound, judged by an eligible shell holding the lock, licenses
// creating the credential. Anything else minting would be how a second,
// competing root is born.

/// The installation root with its provenance.
public struct InstallationRoot: Sendable, Equatable {

    /// How the root came to exist in this activation.
    public enum Provenance: String, Sendable, Equatable {
        /// Found in the Keychain; an ordinary activation, reinstall, or
        /// upgrade reuses it.
        case existing
        /// Freshly minted by this activation — first run on this install.
        case minted
    }

    /// Exactly `FirstPartyAuthProtocol.rootKeyByteCount` bytes.
    public let bytes: [UInt8]
    /// Whether this activation found or minted the root.
    public let provenance: Provenance

    public init(bytes: [UInt8], provenance: Provenance) {
        self.bytes = bytes
        self.provenance = provenance
    }
}

/// Reads — and, under the exact licensed conditions, mints — the installation
/// root in the MACD-2b data-protection Keychain contract.
public struct InstallationRootAuthority: Sendable {

    private let keychain: any KeychainItemAuthority
    private let eligibility: ProviderEligibility
    private let randomBytes: ProviderRandomness

    /// - Parameters:
    ///   - keychain: The injected Keychain seam. Production uses
    ///     `DataProtectionKeychainAuthority`; proofs and tests inject fakes so
    ///     no proof run can ever touch the production credential.
    ///   - eligibility: The positive judgment. Requiring the VALUE (not a
    ///     flag) means an ineligible shell cannot even construct this
    ///     authority.
    ///   - randomBytes: Injected randomness (Perkins P13).
    public init(
        keychain: any KeychainItemAuthority,
        eligibility: ProviderEligibility,
        randomBytes: @escaping ProviderRandomness
    ) {
        self.keychain = keychain
        self.eligibility = eligibility
        self.randomBytes = randomBytes
    }

    /// Read the root, applying the fatal-vs-absence matrix.
    ///
    /// - Returns: The root bytes, or `nil` for GENUINE absence
    ///   (`errSecItemNotFound`) — the only non-fatal miss.
    /// - Throws: `DaemonProviderError.keychainFatal` for every other fault.
    public func readRoot() throws -> [UInt8]? {
        let result = keychain.copyItem(
            service: FirstPartyAuthProtocol.keychainService,
            account: FirstPartyAuthProtocol.keychainAccount,
            accessGroup: eligibility.expandedKeychainGroup
        )
        switch result {
        case .found(let bytes):
            guard bytes.count == FirstPartyAuthProtocol.rootKeyByteCount else {
                throw DaemonProviderError.keychainFatal(.corrupted)
            }
            return bytes
        case .notFound:
            return nil
        case .missingEntitlement:
            throw DaemonProviderError.keychainFatal(.missingEntitlement)
        case .interactionRequired:
            throw DaemonProviderError.keychainFatal(.interactionRequired)
        case .unavailable:
            throw DaemonProviderError.keychainFatal(.unavailable)
        }
    }

    /// Read the root, minting it if — and only if — it is genuinely absent.
    ///
    /// Requires the lock proof: the mint license is eligibility AND lock AND
    /// genuine absence, all three (Perkins P5) — and, since MACD-2c2, the
    /// lock's LAYOUT (Perkins P-c2-1): a PRODUCTION Keychain authority is
    /// refused outright under a proof-layout (or unspecified) lock proof,
    /// before even the read, so a proof-directory lock can never probe or
    /// mint the production credential. After a mint the item is read back and
    /// compared; disagreement is fatal. An add that reports `duplicate`
    /// re-reads and compares — losing an add race to an item with the same
    /// bytes is fine, to different bytes is `disagreement`.
    ///
    /// - Returns: The root and its provenance.
    /// - Throws: `DaemonProviderError.keychainFatal`.
    public func ensureRoot(lockProof: ProviderLockProof) throws -> InstallationRoot {
        // The proof must be LIVE: a stale proof (its handle already released)
        // must never license a mint.
        try lockProof.validate()
        // P-c2-1: the mint license is bound to WHICH layout produced the
        // lock. The production credential authority (marker protocol) may
        // only ever be exercised under the production layout's lock — a
        // proof-context lock satisfying the P5 conditions against the REAL
        // data-protection Keychain was the c1 carry-forward hole this closes.
        if keychain is ProductionCredentialAuthority,
           lockProof.layoutContext != .production {
            throw DaemonProviderError.keychainFatal(.proofContextRefused)
        }
        if let existing = try readRoot() {
            return InstallationRoot(bytes: existing, provenance: .existing)
        }
        // GENUINE absence, judged by an eligible holder of the exclusive
        // lock — the one licensed mint path in the entire product.
        let minted = randomBytes(FirstPartyAuthProtocol.rootKeyByteCount)
        guard minted.count == FirstPartyAuthProtocol.rootKeyByteCount else {
            // Injected randomness that cannot produce 32 bytes is a broken
            // security primitive, not an absence.
            throw DaemonProviderError.keychainFatal(.unavailable)
        }
        let status = keychain.addItem(
            service: FirstPartyAuthProtocol.keychainService,
            account: FirstPartyAuthProtocol.keychainAccount,
            accessGroup: eligibility.expandedKeychainGroup,
            data: minted
        )
        switch status {
        case .added:
            // Read back and compare: a Keychain that stores different bytes
            // than it was handed is lying to someone.
            guard let readBack = try readRoot(),
                  FirstPartyAuthProtocol.constantTimeEquals(readBack, minted) else {
                throw DaemonProviderError.keychainFatal(.disagreement)
            }
            return InstallationRoot(bytes: minted, provenance: .minted)
        case .duplicate:
            // Lost an add race. Under the exclusive lock this should be
            // impossible; judge the survivor rather than assume.
            guard let readBack = try readRoot() else {
                throw DaemonProviderError.keychainFatal(.disagreement)
            }
            if FirstPartyAuthProtocol.constantTimeEquals(readBack, minted) {
                return InstallationRoot(bytes: readBack, provenance: .existing)
            }
            throw DaemonProviderError.keychainFatal(.disagreement)
        case .missingEntitlement:
            throw DaemonProviderError.keychainFatal(.missingEntitlement)
        case .unavailable:
            throw DaemonProviderError.keychainFatal(.unavailable)
        }
    }
}

#if canImport(Security)
/// The production Keychain seam: the exact MACD-2b query shape against the
/// data-protection Keychain.
///
/// Service and account are PROTOCOL CONSTANTS from `FirstPartyAuthProtocol`
/// (never caller input); the access group is the runtime-expanded value from
/// the shell's own signed entitlements. Adds pin
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and non-synchronizable
/// — the root is device-bound (Kong decision 1).
///
/// Conforms to `ProductionCredentialAuthority` (P-c2-1): pairing this type
/// with a proof-layout lock or a non-nil proof context fails closed before
/// any `SecItem*` call is reachable.
public struct DataProtectionKeychainAuthority: KeychainItemAuthority, ProductionCredentialAuthority {

    public init() {}

    /// `SecItemCopyMatching` with the exact contract query:
    /// `kSecUseDataProtectionKeychain: true` (without it the access group is
    /// advisory on macOS), non-synchronizable (device-bound root), and the
    /// caller's runtime-expanded group.
    public func copyItem(
        service: String, account: String, accessGroup: String
    ) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable }
            return .found(Array(data))
        case errSecItemNotFound:
            return .notFound
        case errSecMissingEntitlement:
            return .missingEntitlement
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            return .unavailable
        }
    }

    /// `SecItemAdd` with the exact contract attributes, pinning
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (Kong decision 1).
    public func addItem(
        service: String, account: String, accessGroup: String, data: [UInt8]
    ) -> KeychainWriteStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(data),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .added
        case errSecDuplicateItem:
            return .duplicate
        case errSecMissingEntitlement:
            return .missingEntitlement
        default:
            return .unavailable
        }
    }
}
#endif
