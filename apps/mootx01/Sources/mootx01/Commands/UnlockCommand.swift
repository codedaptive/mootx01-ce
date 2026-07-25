// UnlockCommand.swift — `mootx01 unlock private|secret` and `mootx01 lock`
//
// the out-of-band approval mechanism for sensitivity tiers.
//
//   mootx01 unlock private   — authenticate with LocalAuthentication and
//                              issue a restricted-tier grant to the daemon.
//                              Grant resets at local midnight.
//   mootx01 unlock secret    — authenticate and issue a 30-min secret-tier
//                              grant.
//   mootx01 lock             — immediately clear all grants (no auth needed;
//                              locking is always permitted).
//
// User-facing tier names:
//   private → SensitivityTier.restricted  (the "show private" grant)
//   secret  → SensitivityTier.secret      (the 30-min grant)
//
// The command calls `LocalAuthenticationAuthority.requestApproval(tier:reason:)`
// to obtain Touch ID / Apple Watch / macOS account-password attestation via the
// OS, then POSTs to the daemon's REST endpoint `/api/control/unlock` (not an
// MCP tool; unlock is deliberately available only through the authenticated
// control endpoint.
//
// macOS-only — the `#if os(macOS)` guard covers both LocalAuthentication and
// the URLSession-based HTTP call (URLSession is available on macOS 10.15+, but
// keeping the guard unified avoids conditional-availability confusion on Linux).

#if os(macOS)
import ArgumentParser
import Foundation
import MootInstallerCore
import AriaMCP   // SensitivityTier

// MARK: - mootx01 unlock <tier>

/// Authenticate and issue a sensitivity-tier grant to the resident daemon.
///
/// Authentication uses `LocalAuthenticationAuthority` (Touch ID / Apple Watch /
/// macOS account password). On success, a grant is issued to the daemon via the
/// `/api/control/unlock` REST endpoint; future recall calls from any MCP client
/// on this session will include the now-unlocked tier until the grant expires.
struct UnlockCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Authenticate and issue a sensitivity-tier grant (private → midnight; secret → 30 min).",
        discussion: """
        Authenticate with Touch ID, Apple Watch, or your macOS password, then
        grant the resident daemon access to restricted ("private") or secret content
        for the current session.

          mootx01 unlock private   — grant access until local midnight
          mootx01 unlock secret    — grant access for 30 minutes

        Use `mootx01 lock` to revoke all grants immediately.
        """
    )

    /// User-facing tier name: "private" (→ restricted) or "secret".
    @Argument(help: "Tier to unlock: 'private' or 'secret'.")
    var tier: String

    /// Optional named estate. When provided, the command resolves the daemon port
    /// from that estate's data directory. Default: the active estate.
    @Option(name: .long, help: "Named estate. Default: active estate.")
    var db: String?

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        // Map user-facing name to internal SensitivityTier.
        let sensitivityTier: SensitivityTier
        let tierLabel: String  // human-readable for the approval dialog
        switch tier.lowercased() {
        case "private", "restricted":
            sensitivityTier = .restricted
            tierLabel = "private (restricted)"
        case "secret":
            sensitivityTier = .secret
            tierLabel = "secret"
        default:
            fputs("mootx01 unlock: unknown tier '\(tier)'. Use 'private' or 'secret'.\n", stderr)
            throw ExitCode(64) // EX_USAGE
        }

        // Step 1 — Authenticate via LocalAuthentication.
        let authority = LocalAuthenticationAuthority()
        let reason = "Unlock \(tierLabel) sensitivity tier for mootx01 ARIA recall."
        let approved: Bool
        do {
            approved = try await authority.requestApproval(tier: sensitivityTier, reason: reason)
        } catch let err as UnlockAuthorityError {
            fputs("mootx01 unlock: \(err.localizedDescription ?? err.errorDescription ?? "authentication error")\n", stderr)
            throw ExitCode.failure
        }

        guard approved else {
            fputs("mootx01 unlock: authentication cancelled.\n", stderr)
            throw ExitCode.failure
        }

        // Step 2 — POST to the daemon's /api/control/unlock REST endpoint.
        //
        // Body: {"tier": "restricted"|"secret", "proof": {"ts": <epoch_ms>}}
        // The daemon verifies the timestamp freshness (±10 s) and issues the
        // in-RAM grant — no MCP tool is involved.
        let resolvedPort = MootPaths.resolvedResidentPort(dataDir: dataDir)
        let tierValue = sensitivityTier == .restricted ? "restricted" : "secret"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyDict: [String: Any] = [
            "tier": tierValue,
            "proof": ["ts": nowMs]
        ]

        guard let url = URL(string: "http://127.0.0.1:\(resolvedPort)/api/control/unlock"),
              let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            fputs("mootx01 unlock: cannot construct unlock request.\n", stderr)
            throw ExitCode.failure
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            fputs("mootx01 unlock: unexpected response type from daemon.\n", stderr)
            throw ExitCode.failure
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            fputs("mootx01 unlock: daemon returned HTTP \(http.statusCode): \(body)\n", stderr)
            throw ExitCode.failure
        }

        // Parse and display the grant expiry.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expiresAt = obj["expiresAt"] as? String {
            print("mootx01 unlock: \(tierLabel) tier granted, expires \(expiresAt).")
        } else {
            print("mootx01 unlock: \(tierLabel) tier granted.")
        }
    }
}

// MARK: - mootx01 lock

/// Revoke all active sensitivity grants immediately.
///
/// No authentication is required — locking reduces the user's own access and
/// is always permitted. Calls the daemon's `/api/control/lock`
/// endpoint.
struct LockCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Revoke all sensitivity grants immediately (no authentication required)."
    )

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)
        let resolvedPort = MootPaths.resolvedResidentPort(dataDir: dataDir)

        guard let url = URL(string: "http://127.0.0.1:\(resolvedPort)/api/control/lock"),
              let bodyData = "{}".data(using: .utf8) else {
            fputs("mootx01 lock: cannot construct lock request.\n", stderr)
            throw ExitCode.failure
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            fputs("mootx01 lock: daemon returned error: \(body)\n", stderr)
            throw ExitCode.failure
        }

        print("mootx01 lock: all sensitivity grants revoked.")
    }
}

#endif // os(macOS)
