// ProviderOwnershipProbe.swift
// MootInstallerCore — MACD-3B3 authenticated live-owner detection seam.
//
// Architecture: subprocess-delegated authentication (Kong K2 / MACD-3B3).
//
// The CLI process (`mootx01`) has no `com.apple.security.application-groups`
// or `keychain-access-groups` entitlements.  FileManager.containerURL(for:)
// returns nil; SecItemCopyMatching returns errSecMissingEntitlement.  All
// MAC verification of the descriptor and preference therefore MUST happen
// inside the signed bundle subprocess, which DOES carry these entitlements.
//
// This probe calls `DaemonBundle.runReadOnlyMode("owner-status", homeDirectory:)`
// and decodes the single-line JSON result.  It never performs MAC operations
// itself.  All ProviderDaemonProvider types used here are for the RETURN TYPE
// vocabulary only (ProviderKind, VersionCompatibilityVerdict) — the values
// themselves come from the subprocess output.
//
// TRUST BOUNDARY (Perkins F1 fix): delegating all MAC verification to the
// subprocess is only sound when the subprocess IS the legitimate signed binary.
// ProviderOwnershipProbe verifies the bundle executable's static code signature
// (via `BundleSignatureVerifier`) BEFORE running it.  A planted unsigned or
// wrong-identity binary is refused with .unauthenticated; it is never executed
// and its JSON output is never decoded.

import Foundation
#if canImport(Security)
import Security
#endif
import MootDaemonProvider

// MARK: - BundleSignatureVerifier

/// Verifies the static code signature of the daemon bundle executable BEFORE
/// the CLI trusts or launches it.
///
/// This type closes the Perkins F1 trust-boundary gap.  The CLI's architecture
/// delegates all MAC verification to the bundle subprocess, but that delegation
/// is only sound when the subprocess IS the legitimate signed binary.  A same-UID
/// attacker who plants an unsigned shell script at the bundle executable path
/// could otherwise cause the CLI to decode attacker-controlled JSON as an
/// authenticated coexistence verdict.
///
/// The verification is a STATIC code-signature check (no process launch) against
/// a requirement derived from the canonical constants the codebase already uses:
/// - `anchor apple generic`: the binary is signed with an Apple-trusted certificate
///   (rules out unsigned and ad-hoc signatures).
/// - `certificate leaf[subject.OU] = "G94X5T5GK7"`: the signing team must be
///   Codedaptive, LLC.  G94X5T5GK7 was MEASURED from this machine's Developer ID
///   Application and Apple Distribution identities (MACD-3B3 residual, closed by
///   seal 7CCC18C3).  Without this pin any Apple-issued developer certificate from
///   any team naming the same bundle identifier would satisfy the requirement.
/// - `identifier`: the bundle identifier must match `DaemonBundle.bundleIdentifier`
///   (the registered, unique identifier for the daemon provider bundle).
///
/// This type is injectable so functional tests can pass an always-valid fake without
/// requiring a real signed binary, while a separate RED test exercises the real
/// Security-framework path against a planted unsigned binary.
public struct BundleSignatureVerifier: Sendable {

    /// Verify the static code signature of `executableURL`.
    ///
    /// - Returns: `true` when the binary satisfies the requirement (Apple-generic
    ///   anchor AND correct bundle identifier); `false` for any failure: unsigned,
    ///   ad-hoc, wrong bundle identifier, wrong anchor, API error.  Fail-closed.
    public var verify: @Sendable (URL) -> Bool

    /// Production verifier — uses `SecStaticCodeCheckValidityWithErrors`.
    public static let production: BundleSignatureVerifier = {
        #if canImport(Security)
        return BundleSignatureVerifier(verify: SecStaticBundleVerifier.verify(executableURL:))
        #else
        // Non-Darwin: Security framework absent; the bundled provider does not
        // exist on this platform so any caller-side "absent" result is correct.
        // Returning true here is safe: if the file does not exist, the runner
        // returns -1 → .absent; if it inexplicably does exist, we cannot check
        // its signature and the subprocess will fail naturally.
        return BundleSignatureVerifier(verify: { _ in true })
        #endif
    }()

    /// Always-valid verifier for decode-logic unit tests that inject a fake
    /// subprocess runner and never write a real binary to disk.
    public static let alwaysValid = BundleSignatureVerifier(verify: { _ in true })
}

// MARK: - BundleCensusGate

/// The result of verifying the daemon bundle executable before a census exec
/// or a disabled-plist staging operation.
///
/// Both `InstallCommand` and `UpgradeCommand` call `BundleSignatureVerifier.gate(homeDirectory:)`
/// so the census and plist-write security boundary has ONE verification authority —
/// never two independent copies that could drift (Perkins F1 census-site fix).
public enum BundleCensusGate: Sendable, Equatable {

    /// The bundle executable is absent or not executable at the expected path.
    ///
    /// This is the ordinary case when the release payload does not yet include
    /// the daemon provider bundle.  Callers should skip silently.
    case absent

    /// Bundle is present and its static code signature was verified.
    ///
    /// Census may proceed and the disabled plist may be staged.
    case verified

    /// Bundle is present but its static code signature could not be verified.
    ///
    /// Causes: unsigned, ad-hoc, wrong bundle identifier, or a Security-framework
    /// API error.  `userMessage` is a complete, printable warning line for CLI output.
    ///
    /// Census MUST NOT execute.  The disabled plist MUST NOT be staged — a
    /// disabled plist names the executable path in ProgramArguments and could be
    /// enabled by the same attacker who planted the impostor binary.
    case unverified(userMessage: String)
}

// MARK: - BundleSignatureVerifier.gate

extension BundleSignatureVerifier {

    /// Evaluate whether the daemon bundle executable is present and has a valid
    /// static code signature.
    ///
    /// This is the single verification authority for census exec sites and the
    /// disabled-plist staging operation in both `InstallCommand` and `UpgradeCommand`
    /// (Perkins F1 — three exec sites, one gate).  Call this BEFORE writing any
    /// LaunchAgent plist or running `DaemonBundle.runReadOnlyMode("census", ...)`.
    ///
    /// - Parameter homeDirectory: The user's home directory, used to locate the
    ///   bundle executable via `DaemonBundle.bundleExecutableURL(homeDirectory:)`.
    /// - Returns: `.absent` when no executable file is found, `.verified` when the
    ///   signature satisfies the requirement, `.unverified(userMessage:)` when the
    ///   binary is present but fails signature verification.  Never throws.
    public func gate(homeDirectory: URL) -> BundleCensusGate {
        let executable = DaemonBundle.bundleExecutableURL(homeDirectory: homeDirectory)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .absent
        }
        guard verify(executable) else {
            // A binary is present but cannot be verified: refuse both the census
            // exec and the plist staging.  Surface an actionable message to the user
            // so the situation is not silently swallowed.
            return .unverified(
                userMessage: "\u{26A0} Provider bundle present but its signature could " +
                    "not be verified; skipping provider census. No provider process was started."
            )
        }
        return .verified
    }
}

// MARK: - SecStaticBundleVerifier

#if canImport(Security)
/// Real Security-framework implementation of the static bundle signature check.
///
/// Called by `BundleSignatureVerifier.production`.  Public so the RED exploit
/// test in `ProviderOwnershipProbeTests` can inject it directly against a
/// planted unsigned binary.
public enum SecStaticBundleVerifier {

    /// Verify the static code signature of the bundle executable at `executableURL`.
    ///
    /// Requirement string source:
    /// - `anchor apple generic`: cited from the Apple Developer documentation for
    ///   Developer-ID / App Store distribution; rules out unsigned and ad-hoc.
    /// - `certificate leaf[subject.OU] = "G94X5T5GK7"`: pins the signing team to
    ///   Codedaptive, LLC.  G94X5T5GK7 MEASURED from Developer ID Application and
    ///   Apple Distribution identities on this machine (MACD-3B3 residual, seal
    ///   7CCC18C3).  Closes the gap where any Apple-issued cert naming the same
    ///   bundle identifier would satisfy the requirement without the OU pin.
    /// - `identifier "..."`: pinned to `DaemonBundle.bundleIdentifier`, the
    ///   registered, unique identifier defined in `Paths.swift`.
    ///
    /// - Returns: `true` when the binary satisfies the requirement; `false` for any
    ///   failure.  Never throws — all errors map to `false` (fail-closed).
    public static func verify(executableURL: URL) -> Bool {
        var staticCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef else {
            // Cannot create a static code object: path may be unreadable, the bundle
            // structure may be malformed, or an unexpected Security error occurred.
            return false
        }
        // Requirement: Apple-generic anchor (not unsigned, not ad-hoc) AND the signing
        // team is G94X5T5GK7 (Codedaptive, LLC — MEASURED from Developer ID Application
        // and Apple Distribution identities on this machine; closes MACD-3B3 blocking
        // residual, seal 7CCC18C3) AND the binary's bundle identifier matches the
        // canonical DaemonBundle.bundleIdentifier.  The OU pin is the critical addition:
        // without it any Apple-issued developer certificate naming the same bundle
        // identifier from any team would satisfy the anchor+identifier requirement.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"G94X5T5GK7\" and identifier \"\(DaemonBundle.bundleIdentifier)\""
        var reqRef: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &reqRef) == errSecSuccess,
              let req = reqRef else {
            // Requirement string parse failure: unexpected — the string is a
            // compile-time constant derived from DaemonBundle.bundleIdentifier and
            // the literal team-ID G94X5T5GK7; a parse failure is unexpected.
            return false
        }
        return SecStaticCodeCheckValidityWithErrors(staticCode, [], req, nil) == errSecSuccess
    }
}
#endif

// MARK: - OwnershipProbeOutcome

/// The result of the authenticated live-owner detection probe.
///
/// Returned by `ProviderOwnershipProbe.detect(homeDirectory:)`.  The probe is
/// fail-closed: any subprocess failure, JSON parse error, or unknown outcome
/// maps to `.absent` or `.unauthenticated`, never to a false `.healthy`.
public enum OwnershipProbeOutcome: Sendable, Equatable {

    /// An authenticated, schema-3 MAC-verified, version-compatible bundled
    /// owner was detected.  `kind` is the running provider artifact kind;
    /// `preferredKind` is the durable preference (nil when no preference record
    /// has been written yet).
    case healthy(kind: ProviderKind, preferredKind: ProviderKind?)

    /// No authenticated owner is detectable.  Causes:
    /// - Bundle executable is absent (binary not installed)
    /// - Shell mode unrecognised (old bundle without owner-status support) —
    ///   explicitly "mode absent", NOT "authentication failed"
    /// - K_install was never minted (provider never activated)
    /// - Descriptor file does not exist
    ///
    /// Normal install / upgrade proceeds when this is returned.
    case absent

    /// An authenticated owner exists but is version-incompatible with this CLI.
    /// `verdict` is the verbatim `VersionCompatibilityVerdict` (C4 mandate) —
    /// surface it to the user unchanged for directed update messaging.
    /// This case NEVER authorises starting a second provider.
    case incompatible(verdict: VersionCompatibilityVerdict)

    /// A descriptor or process is present but cannot be authenticated.
    /// Causes:
    /// - The bundle executable is present but fails static code-signature
    ///   verification (unsigned, ad-hoc, or wrong bundle identifier) — this
    ///   is the F1 trust-boundary guard: a planted impostor binary is refused
    ///   here before it is ever launched.
    /// - Wrong MAC, schema-2 legacy descriptor, or Keychain fatal error (as
    ///   reported by the subprocess after successful signature verification).
    ///
    /// NEVER kills or replaces the running process — only blocks automated
    /// client-only install (C2/C3 mandate).
    case unauthenticated
}

// MARK: - OwnershipProbeOutcome decision helpers

extension OwnershipProbeOutcome {

    /// `true` when an authenticated healthy bundled owner is running and
    /// client-only install is required (C2 mandate).
    ///
    /// This is the single gate for skipping legacy daemon registration and
    /// bundle plist registration.  A `.direct` owner does NOT trigger this
    /// gate — a direct-install (standalone) provider uses a different
    /// registration channel.
    public var requiresClientOnlyInstall: Bool {
        if case .healthy(let kind, _) = self, kind == .bundled { return true }
        return false
    }

    /// `true` when a version mismatch blocks install entirely (C4 mandate).
    ///
    /// The `verdict` field carries the verbatim update direction from the
    /// `VersionVectorEvaluator` and MUST be surfaced to the user unchanged.
    /// This case NEVER authorises starting a second provider.
    public var blocksInstallByVersionMismatch: Bool {
        if case .incompatible = self { return true }
        return false
    }

    /// `true` when normal (full) install should proceed.
    ///
    /// Both `.absent` (no owner on disk) and `.unauthenticated` (owner
    /// present but signature verification failed, MAC verification failed,
    /// or schema-2 legacy) permit normal install.  For `.unauthenticated`,
    /// the running process is NOT killed or replaced — normal install runs
    /// independently (C3).
    public var normalInstallProceeds: Bool {
        switch self {
        case .absent, .unauthenticated: return true
        case .healthy, .incompatible:   return false
        }
    }
}

// MARK: - ProviderOwnershipProbe

/// The single authenticated live-owner detection seam.
///
/// Shared by `InstallCommand`, `UpgradeCommand`, and `StatusCommand` so the
/// three commands cannot independently drift in their coexistence logic
/// ("parallel copies fail").
///
/// Calls `DaemonBundle.runReadOnlyMode("owner-status", homeDirectory:)` and
/// decodes its JSON result into an `OwnershipProbeOutcome`.  Never elects a
/// winner, never kills a process, never starts a second provider.
///
/// **Trust boundary (Perkins F1):** The subprocess-delegation model is only
/// sound when the subprocess IS the legitimate signed binary.  Before invoking
/// the runner, `detect()` verifies the bundle executable's static code signature
/// via the injected `BundleSignatureVerifier`.  A planted unsigned or wrong-
/// identity binary is refused with `.unauthenticated` — never `.absent` (which
/// would permit a normal install over an unknown tampered state) — before it is
/// ever executed or its JSON decoded.
public struct ProviderOwnershipProbe: Sendable {

    /// The bundle signature verifier seam.
    ///
    /// Called with the bundle executable URL when the file exists on disk, BEFORE
    /// the subprocess is launched.  Failure maps to `.unauthenticated` (not
    /// `.absent`): returning `.absent` for a failed verification would permit a
    /// normal install over an unknown tampered state — an attacker could plant an
    /// unsigned binary that reports absence, triggering install that overwrites a
    /// legitimate owner.
    ///
    /// Production: `BundleSignatureVerifier.production` (SecStaticCode check).
    /// Test injection: `BundleSignatureVerifier.alwaysValid` for decode-logic tests
    /// that never write a real binary to disk; the real verifier for RED exploit tests.
    private let signatureVerifier: BundleSignatureVerifier

    /// The subprocess runner seam.
    ///
    /// Production: `DaemonBundle.runReadOnlyMode(_:homeDirectory:)`.
    /// Test injection: deterministic fake that returns crafted JSON, so the
    /// probe's decode logic is verified without requiring a real bundle binary.
    private let runner: @Sendable (String, URL) -> (code: Int32, output: String?)

    /// Production initialiser — delegates to the real daemon bundle subprocess
    /// with the real Security-framework signature verifier.
    public init() {
        self.signatureVerifier = .production
        self.runner = { mode, home in
            DaemonBundle.runReadOnlyMode(mode, homeDirectory: home)
        }
    }

    /// Testable initialiser.
    ///
    /// - Parameters:
    ///   - runner: A subprocess runner fake so the probe's JSON decoding logic is
    ///     verified without requiring a real signed bundle binary or Keychain.
    ///   - verifier: A signature verifier.  Defaults to `BundleSignatureVerifier.alwaysValid`
    ///     so decode-logic tests that inject a fake runner need no additional seam.
    ///     Pass `BundleSignatureVerifier(verify: SecStaticBundleVerifier.verify(executableURL:))`
    ///     for RED exploit tests that exercise the real Security-framework path.
    internal init(
        runner: @Sendable @escaping (String, URL) -> (code: Int32, output: String?),
        verifier: BundleSignatureVerifier = .alwaysValid
    ) {
        self.runner = runner
        self.signatureVerifier = verifier
    }

    // MARK: - Public API

    /// Run the authenticated owner-status probe against the bundle subprocess.
    ///
    /// Fail-closed on signature verification failure, subprocess failure, and
    /// JSON parse error.
    ///
    /// **Signature verification:** when the bundle executable file exists on disk,
    /// its static code signature is verified BEFORE launching it.  Verification
    /// failure returns `.unauthenticated` immediately — the subprocess is never
    /// run and no JSON is decoded.  Non-existence is NOT a verification failure;
    /// the runner handles the absent-binary case (exit code -1 → `.absent`).
    ///
    /// - Parameter homeDirectory: The user's home directory, passed to
    ///   `DaemonBundle.runReadOnlyMode` to locate the bundle executable.
    /// - Returns: The `OwnershipProbeOutcome` decoded from the subprocess.
    public func detect(homeDirectory: URL) -> OwnershipProbeOutcome {
        let executable = DaemonBundle.bundleExecutableURL(homeDirectory: homeDirectory)
        // Only verify when the file exists: non-existence is correctly handled
        // by the runner (returns -1 → .absent).  Verifying a non-existent path
        // would fail SecStaticCodeCreateWithPath and return .unauthenticated,
        // shadowing the correct .absent result.
        if FileManager.default.fileExists(atPath: executable.path) {
            // Verify BEFORE exec.  Failure is .unauthenticated, not .absent:
            // returning .absent for an impostor binary would permit a normal
            // install over an unknown/tampered state (Perkins F1).
            guard signatureVerifier.verify(executable) else {
                return .unauthenticated
            }
        }
        let result = runner("owner-status", homeDirectory)
        return decode(result)
    }

    // MARK: - JSON decode

    /// Decode the raw subprocess result into an `OwnershipProbeOutcome`.
    ///
    /// **Exit-code semantics (fail-closed):**
    /// - `-1` : bundle binary absent → `.absent`.
    ///          The bundle executable does not exist at the expected path; there
    ///          can be no authenticated bundled owner.
    /// - `64` : shell mode unrecognised → `.absent`.
    ///          An older bundle that predates the `owner-status` mode returns exit
    ///          64 (the default case in `DaemonShellMain.runCollecting`).  This is
    ///          "mode absent", explicitly distinguished from "authentication failed"
    ///          (`.unauthenticated`): a bundle that cannot run the mode has no
    ///          authenticated owner to protect.
    /// - `0`  : success; decode the JSON outcome.
    /// - any other code: fail-closed → `.unauthenticated`.
    ///
    /// **JSON `outcome` field:**
    /// - `"absent"`:          no authenticated owner on disk → `.absent`.
    /// - `"healthy"`:         MAC-verified, schema-3, compatible owner → `.healthy`.
    /// - `"unauthenticated"`: MAC fails, schema-2 legacy, or Keychain error → `.unauthenticated`.
    ///                        Note: the subprocess emits a `verdict` field alongside
    ///                        `"unauthenticated"` for schema-2 legacy descriptors, but
    ///                        `OwnershipProbeOutcome.unauthenticated` carries no associated
    ///                        value — the field is intentionally dropped.  Both legacy-schema-2
    ///                        and MAC-failed correctly yield `normalInstallProceeds = true`;
    ///                        callers do not need the sub-reason.
    /// - `"incompatible"`:    authenticated owner, version mismatch → `.incompatible(verdict:)`.
    /// - unknown string:      fail-closed → `.unauthenticated`.
    internal func decode(_ result: (code: Int32, output: String?)) -> OwnershipProbeOutcome {
        switch result.code {
        case -1:
            // Bundle binary absent: no bundled owner can exist.
            return .absent
        case 64:
            // Shell mode unrecognised: the installed bundle is too old to run
            // owner-status.  Treat as absent — not authentication failure.
            // An old bundle with no owner-status support has no authenticated
            // owner state to protect; normal install proceeds.
            return .absent
        case 0:
            break
        default:
            // Any other non-zero exit: fail-closed — something went wrong.
            return .unauthenticated
        }

        // Parse the JSON outcome.
        guard let jsonString = result.output,
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcomeRaw = object["outcome"] as? String else {
            // JSON parse failure: fail-closed.
            return .unauthenticated
        }

        switch outcomeRaw {
        case "absent":
            return .absent

        case "healthy":
            // `kind` is required for a healthy report; malformed → fail-closed.
            guard let kindRaw = object["kind"] as? String,
                  let kind = ProviderKind(rawValue: kindRaw) else {
                return .unauthenticated
            }
            // `preferredKind` is optional — nil when no preference has been written.
            let preferredKind = (object["preferredKind"] as? String)
                .flatMap { ProviderKind(rawValue: $0) }
            return .healthy(kind: kind, preferredKind: preferredKind)

        case "unauthenticated":
            // The `verdict` field is emitted by the subprocess for legacy-schema-2
            // descriptors but is NOT surfaced here: OwnershipProbeOutcome.unauthenticated
            // carries no associated value.  Both legacy-schema-2 and MAC-failed yield
            // normalInstallProceeds = true; callers do not need the sub-reason.
            return .unauthenticated

        case "incompatible":
            // `verdict` is required for an incompatible report (C4 mandate).
            // Malformed verdict → fail-closed as unauthenticated (the running
            // provider's status is unclear; do not proceed with install).
            guard let verdictRaw = object["verdict"] as? String,
                  let verdict = VersionCompatibilityVerdict(rawValue: verdictRaw) else {
                return .unauthenticated
            }
            return .incompatible(verdict: verdict)

        default:
            // Unknown outcome string: fail-closed.
            return .unauthenticated
        }
    }
}
