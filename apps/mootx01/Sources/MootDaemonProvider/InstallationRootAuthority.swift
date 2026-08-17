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
        throw DaemonProviderError.unimplemented("InstallationRootAuthority.readRoot")
    }

    /// Read the root, minting it if — and only if — it is genuinely absent.
    ///
    /// Requires the lock proof: the mint license is eligibility AND lock AND
    /// genuine absence, all three (Perkins P5). After a mint the item is read
    /// back and compared; disagreement is fatal. An add that reports
    /// `duplicate` re-reads and compares — losing an add race to an item with
    /// the same bytes is fine, to different bytes is `disagreement`.
    ///
    /// - Returns: The root and its provenance.
    /// - Throws: `DaemonProviderError.keychainFatal`.
    public func ensureRoot(lockProof: ProviderLockProof) throws -> InstallationRoot {
        throw DaemonProviderError.unimplemented("InstallationRootAuthority.ensureRoot")
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
public struct DataProtectionKeychainAuthority: KeychainItemAuthority {

    public init() {}

    /// `SecItemCopyMatching` with the exact contract query.
    public func copyItem(
        service: String, account: String, accessGroup: String
    ) -> KeychainReadResult {
        .unavailable // RED placeholder; real classification lands with GREEN.
    }

    /// `SecItemAdd` with the exact contract attributes.
    public func addItem(
        service: String, account: String, accessGroup: String, data: [UInt8]
    ) -> KeychainWriteStatus {
        .unavailable // RED placeholder; real classification lands with GREEN.
    }
}
#endif
