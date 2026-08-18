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

import Foundation
import MootDaemonProvider

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
    /// Causes: wrong MAC, schema-2 legacy descriptor, Keychain fatal error.
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
    /// present but MAC verification failed or schema-2 legacy) permit
    /// normal install.  For `.unauthenticated`, the running process is
    /// NOT killed or replaced — normal install runs independently (C3).
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
public struct ProviderOwnershipProbe: Sendable {

    /// The subprocess runner seam.
    ///
    /// Production: `DaemonBundle.runReadOnlyMode(_:homeDirectory:)`.
    /// Test injection: deterministic fake that returns crafted JSON, so the
    /// probe's decode logic is verified without requiring a real bundle binary.
    private let runner: @Sendable (String, URL) -> (code: Int32, output: String?)

    /// Production initialiser — delegates to the real daemon bundle subprocess.
    public init() {
        self.runner = { mode, home in
            DaemonBundle.runReadOnlyMode(mode, homeDirectory: home)
        }
    }

    /// Testable initialiser.
    ///
    /// Injects a subprocess runner fake so the probe's JSON decoding logic is
    /// verified without requiring a real signed bundle binary or Keychain.
    internal init(runner: @Sendable @escaping (String, URL) -> (code: Int32, output: String?)) {
        self.runner = runner
    }

    // MARK: - Public API

    /// Run the authenticated owner-status probe against the bundle subprocess.
    ///
    /// Fail-closed on every subprocess failure or JSON parse error.
    ///
    /// - Parameter homeDirectory: The user's home directory, passed to
    ///   `DaemonBundle.runReadOnlyMode` to locate the bundle executable.
    /// - Returns: The `OwnershipProbeOutcome` decoded from the subprocess.
    public func detect(homeDirectory: URL) -> OwnershipProbeOutcome {
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
