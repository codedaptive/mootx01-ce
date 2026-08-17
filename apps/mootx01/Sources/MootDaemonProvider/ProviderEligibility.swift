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

    /// The canonical App Group PORTAL record. Not an AriaMCP constant because
    /// the App Group is a provider/packaging concern, not a wire concern —
    /// the wire contract deliberately carries no container identity.
    ///
    /// MACD-2a live signed/runtime correction: on macOS the SIGNED and
    /// RUNTIME identifier may be the team-prefixed form
    /// `<TEAMID>.group.com.codedaptive.mootx01` (Apple's emitted profile
    /// wildcard covers only that form), while entitlements files authored
    /// against the portal record carry this bare spelling. The judge accepts
    /// both and propagates WHICHEVER the shell's own signature declares,
    /// because `containerURL(forSecurityApplicationGroupIdentifier:)` must be
    /// handed the signed spelling.
    public static let requiredAppGroup = "group.com.codedaptive.mootx01"

    /// The team Keychain group SUFFIX. The full group is always the runtime-
    /// expanded `<TEAMID>.` + this suffix read from the shell's own signed
    /// entitlements — never a compiled-in literal with a team prefix
    /// (Kong decision 2: literal/unexpanded group use is a hard stop).
    public static let requiredKeychainGroupSuffix = "com.codedaptive.mootx01.shared"

    /// Judge eligibility. Refuses the four ineligible classes (Perkins P1):
    /// unsigned, ad-hoc, wrong-team, wrong-group.
    ///
    /// Order of judgment: signature class first (an unsigned or ad-hoc claim
    /// is worthless regardless of what it claims), then the App Group and the
    /// Keychain-group suffix (wrong-group), then the team prefix of the
    /// matched group (wrong-team). Every branch fails closed.
    ///
    /// - Returns: The positive judgment.
    /// - Throws: `DaemonProviderError.ineligible` naming the refused class.
    public static func judge(_ identity: SignedProcessIdentity) throws -> ProviderEligibility {
        switch identity.signingClass {
        case .unsigned:
            throw DaemonProviderError.ineligible(.unsigned)
        case .adHoc:
            // Ad-hoc entitlement CLAIMS are unenforced by any authority, so
            // the claims are not even examined.
            throw DaemonProviderError.ineligible(.adHocSigned)
        case .developerID, .appleDevelopment, .appleDistribution:
            break
        }
        // A signed process without a team cannot own a team Keychain group;
        // whatever group it claims, no team backs the claim.
        guard let team = identity.teamIdentifier, !team.isEmpty else {
            throw DaemonProviderError.ineligible(.wrongTeam)
        }
        // Accept the portal record or the team-prefixed runtime spelling
        // (MACD-2a correction), and remember which one the SIGNATURE says —
        // that exact string is what the container resolver must be handed.
        let runtimeAppGroup = team + "." + Self.requiredAppGroup
        guard let matchedAppGroup = identity.applicationGroups.first(where: {
            $0 == Self.requiredAppGroup || $0 == runtimeAppGroup
        }) else {
            throw DaemonProviderError.ineligible(.wrongGroup)
        }
        let suffix = "." + Self.requiredKeychainGroupSuffix
        let candidates = identity.keychainAccessGroups.filter { $0.hasSuffix(suffix) }
        guard !candidates.isEmpty else {
            throw DaemonProviderError.ineligible(.wrongGroup)
        }
        // The matched group's prefix must be the SIGNING team — a group
        // expanded under someone else's prefix is someone else's group.
        guard let matched = candidates.first(where: { String($0.dropLast(suffix.count)) == team }) else {
            throw DaemonProviderError.ineligible(.wrongTeam)
        }
        return ProviderEligibility(
            identity: identity,
            expandedKeychainGroup: matched,
            appGroupIdentifier: matchedAppGroup,
            signingIdentity: SigningIdentityDescriptor(
                teamIdentifier: team,
                bundleIdentifier: identity.bundleIdentifier ?? "",
                signingClass: identity.signingClass
            )
        )
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
    ///
    /// Classification is by the leaf certificate's subject summary — the
    /// same strings Apple's signing identities carry ("Developer ID
    /// Application", "Apple Development", "Apple Distribution" /
    /// "3rd Party Mac Developer Application"). Anything signed that matches
    /// none of them is classified AD-HOC: an unprovable channel earns no
    /// channel, which fails closed at the eligibility judge.
    public func processIdentity() throws -> SignedProcessIdentity {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
            return Self.unsignedIdentity
        }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let staticCode = staticRef else {
            return Self.unsignedIdentity
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return Self.unsignedIdentity
        }
        // An unsigned binary yields signing information with no identifier.
        guard info[kSecCodeInfoIdentifier as String] is String else {
            return Self.unsignedIdentity
        }

        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let appGroups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        let keychainGroups = entitlements["keychain-access-groups"] as? [String] ?? []
        let bundle = Bundle.main.bundleIdentifier

        // kSecCodeSignatureAdhoc (0x2) in the signature flags marks an
        // ad-hoc signature regardless of what else the dictionary carries.
        let signatureFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if signatureFlags & 0x2 != 0 {
            return SignedProcessIdentity(
                signingClass: .adHoc, teamIdentifier: nil,
                applicationGroups: appGroups, keychainAccessGroups: keychainGroups,
                bundleIdentifier: bundle
            )
        }

        var signingClass = SignedProcessIdentity.SigningClass.adHoc
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            if summary.contains("Developer ID Application") {
                signingClass = .developerID
            } else if summary.contains("Apple Development") || summary.contains("Mac Developer") {
                signingClass = .appleDevelopment
            } else if summary.contains("Apple Distribution")
                        || summary.contains("3rd Party Mac Developer Application") {
                signingClass = .appleDistribution
            }
        }

        return SignedProcessIdentity(
            signingClass: signingClass,
            teamIdentifier: team,
            applicationGroups: appGroups,
            keychainAccessGroups: keychainGroups,
            bundleIdentifier: bundle
        )
    }

    /// The classification of a process with no usable signature.
    private static var unsignedIdentity: SignedProcessIdentity {
        SignedProcessIdentity(
            signingClass: .unsigned, teamIdentifier: nil,
            applicationGroups: [], keychainAccessGroups: [],
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}
#endif
