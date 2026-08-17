import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - MACD-2c1 — signed-eligibility judgment (Perkins P1)
//
// Eligibility is judged from the shell's OWN signed entitlements, read back
// through the Security framework, before ANY side effect: before the lock,
// before the Keychain, before the estate, before the bind, before the
// descriptor. An unsigned, ad-hoc, wrong-team, or wrong-group shell exits
// here. This is the Kong decision-2 rule that a raw or self-built executable
// can never claim the team Keychain group or become an eligible first-party
// provider.

/// The signing facts of the running process, as read back from its own code
/// signature. This is an OBSERVATION record; judgment happens in
/// `ProviderEligibilityJudge`.
public struct SignedProcessIdentity: Sendable, Equatable {

    /// The distribution channel of the process's signature.
    public enum SigningClass: String, Sendable, Equatable, CaseIterable {
        /// Developer ID Application — direct distribution.
        case developerID = "developer-id"
        /// Apple Development — local development signing.
        case appleDevelopment = "apple-development"
        /// Apple Distribution — App Store channel.
        case appleDistribution = "apple-distribution"
        /// A signature with no team behind it.
        case adHoc = "ad-hoc"
        /// No signature at all.
        case unsigned
    }

    /// The signature's channel classification.
    public let signingClass: SigningClass
    /// The signing team, `nil` for ad-hoc and unsigned processes.
    public let teamIdentifier: String?
    /// `com.apple.security.application-groups` from the SIGNED entitlements.
    public let applicationGroups: [String]
    /// `keychain-access-groups` from the SIGNED entitlements — the runtime-
    /// EXPANDED values (team prefix already substituted), never literals.
    public let keychainAccessGroups: [String]
    /// The bundle identifier, when one is present.
    public let bundleIdentifier: String?

    public init(
        signingClass: SigningClass,
        teamIdentifier: String?,
        applicationGroups: [String],
        keychainAccessGroups: [String],
        bundleIdentifier: String?
    ) {
        self.signingClass = signingClass
        self.teamIdentifier = teamIdentifier
        self.applicationGroups = applicationGroups
        self.keychainAccessGroups = keychainAccessGroups
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Reads the running process's signed identity. Injected so tests can present
/// all four ineligible classes without forging signatures (Perkins P1).
public protocol EntitlementReadback: Sendable {
    /// The process's signing facts.
    func processIdentity() throws -> SignedProcessIdentity
}

/// The canonical identity a lease binds a provider shell to: enough to name
/// WHICH signed artifact held a role, never enough to impersonate it.
public struct SigningIdentityDescriptor: Sendable, Equatable {
    /// The signing team.
    public let teamIdentifier: String
    /// The bundle identifier (empty string for a bare executable).
    public let bundleIdentifier: String
    /// The channel classification.
    public let signingClass: SignedProcessIdentity.SigningClass

    public init(
        teamIdentifier: String,
        bundleIdentifier: String,
        signingClass: SignedProcessIdentity.SigningClass
    ) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.signingClass = signingClass
    }
}

/// A POSITIVE eligibility judgment: the only value that unlocks the rest of
/// the provider pipeline. Constructible solely by `ProviderEligibilityJudge`,
/// so holding one IS the proof that judgment ran.
public struct ProviderEligibility: Sendable, Equatable {
    /// The judged identity.
    public let identity: SignedProcessIdentity
    /// The matched, fully expanded team Keychain group
    /// (`<TEAMID>.com.codedaptive.mootx01.shared`).
    public let expandedKeychainGroup: String
    /// The matched App Group identifier.
    public let appGroupIdentifier: String
    /// The lease-binding identity of this shell.
    public let signingIdentity: SigningIdentityDescriptor

    // Internal on purpose: only the judge constructs eligibility.
    internal init(
        identity: SignedProcessIdentity,
        expandedKeychainGroup: String,
        appGroupIdentifier: String,
        signingIdentity: SigningIdentityDescriptor
    ) {
        self.identity = identity
        self.expandedKeychainGroup = expandedKeychainGroup
        self.appGroupIdentifier = appGroupIdentifier
        self.signingIdentity = signingIdentity
    }
}

/// Judges a `SignedProcessIdentity` against the provider contract.
public enum ProviderEligibilityJudge {

    /// The canonical App Group (MACD-2a live signed/runtime correction; also
    /// the group every shipping target's entitlements declare). Not an AriaMCP
    /// constant because the App Group is a provider/packaging concern, not a
    /// wire concern — the wire contract deliberately carries no container
    /// identity.
    public static let requiredAppGroup = "group.com.codedaptive.mootx01"

    /// The team Keychain group SUFFIX. The full group is always the runtime-
    /// expanded `<TEAMID>.` + this suffix read from the shell's own signed
    /// entitlements — never a compiled-in literal with a team prefix
    /// (Kong decision 2: literal/unexpanded group use is a hard stop).
    public static let requiredKeychainGroupSuffix = "com.codedaptive.mootx01.shared"

    /// Judge eligibility. Refuses the four ineligible classes (Perkins P1):
    /// unsigned, ad-hoc, wrong-team, wrong-group.
    ///
    /// - Returns: The positive judgment.
    /// - Throws: `DaemonProviderError.ineligible` naming the refused class.
    public static func judge(_ identity: SignedProcessIdentity) throws -> ProviderEligibility {
        throw DaemonProviderError.unimplemented("ProviderEligibilityJudge.judge")
    }
}

#if canImport(Security)
/// Reads the process's own signed identity via `SecCodeCopySelf`.
///
/// The entitlements come from the SIGNED code object — the values the kernel
/// and `securityd` will actually enforce — not from an Info.plist or an
/// environment claim.
public struct SecCodeEntitlementReadback: EntitlementReadback {

    public init() {}

    /// Read back this process's signing class, team, and entitlements.
    public func processIdentity() throws -> SignedProcessIdentity {
        throw DaemonProviderError.unimplemented("SecCodeEntitlementReadback.processIdentity")
    }
}
#endif
