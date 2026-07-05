// UnlockAuthority.swift — ADR-025 sensitivity unlock: identity-verification
// seam for the `mootx01 unlock` CLI command (macOS only).
//
// Two roles:
//   1. PROTOCOL (`UnlockAuthority`) — hides the per-platform mechanism so
//      `UnlockCommand` can be tested without a real biometric prompt. Any
//      conforming type receives a SensitivityTier and a localised reason
//      string and returns `true` if the user was verified.
//
//   2. PRODUCTION BACKEND (`LocalAuthenticationAuthority`) — calls
//      `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` to obtain
//      Touch ID / Apple Watch / account-password attestation from the OS.
//
//      Policy choice: `.deviceOwnerAuthentication` (not
//      `.deviceOwnerAuthenticationWithBiometrics`) degrades gracefully to the
//      macOS account password when biometrics are unavailable or the device
//      lacks a sensor, keeping the CLI usable from any Terminal session.
//
//      We NEVER prompt the user for a mootx01-specific password on macOS —
//      the OS attests user presence through the system credential store
//      (ADR-025 §2: "Swift/macOS uses LocalAuthentication; no stored password
//      of ours exists on that platform").
//
// On Rust/Linux/Windows the approval mechanism is password-based
// (PBKDF2-HMAC-SHA256); that path lives in the Rust vertical's
// `core::unlock_authority` module.

#if os(macOS)
import Foundation
import LocalAuthentication
import AriaMCP   // SensitivityTier

// MARK: - Protocol

/// The identity-verification seam for ADR-025 sensitivity unlock.
///
/// `UnlockCommand` calls `requestApproval(tier:reason:)` before sending a
/// grant request to the daemon's `/api/control/unlock` REST endpoint.
///
/// Separating authentication from the HTTP call lets unit tests substitute an
/// always-allow or always-deny stub without requiring a real biometric sensor
/// or a live daemon.
protocol UnlockAuthority: Sendable {
    /// Request the user's approval to unlock `tier`.
    ///
    /// - Parameters:
    ///   - tier: The sensitivity tier being unlocked.
    ///   - reason: A user-visible string describing why access is needed.
    ///             Shown by LocalAuthentication in the system prompt dialog.
    /// - Returns: `true` if the user was verified; `false` if they cancelled
    ///            or the policy was not available.
    /// - Throws: `UnlockAuthorityError` if LocalAuthentication is unavailable
    ///           or returns an error beyond a user-cancel.
    func requestApproval(tier: SensitivityTier, reason: String) async throws -> Bool
}

// MARK: - Production backend

/// `LocalAuthentication`-backed implementation — the primary macOS backend.
///
/// Evaluates `.deviceOwnerAuthentication`, which allows Touch ID, Apple Watch,
/// or the macOS account password as a fallback, per system security policy.
///
/// The `LAContext` is created fresh on each call so there is no credential
/// reuse across unlock operations — each call requires the user to present
/// their credential again. This matches the expectation that each
/// `mootx01 unlock` invocation is an independent authentication event.
struct LocalAuthenticationAuthority: UnlockAuthority {

    func requestApproval(tier: SensitivityTier, reason: String) async throws -> Bool {
        let context = LAContext()
        var authError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            throw UnlockAuthorityError.unavailable(
                authError?.localizedDescription ?? "LocalAuthentication unavailable on this device"
            )
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                // User dismissed the prompt or the system cancelled it —
                // return false so the caller can print a friendly message
                // rather than an error.
                return false
            case .userFallback:
                // User tapped the fallback button and then cancelled the
                // fallback password dialog.
                return false
            default:
                throw UnlockAuthorityError.evaluationFailed(laError.localizedDescription)
            }
        }
    }
}

// MARK: - Error type

/// Errors raised by `UnlockAuthority` implementations.
enum UnlockAuthorityError: Error, LocalizedError {
    /// LocalAuthentication could not be evaluated on this device or OS version.
    case unavailable(String)
    /// The evaluation completed but returned an error other than a user-cancel.
    case evaluationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Authentication unavailable: \(reason)"
        case .evaluationFailed(let reason):
            return "Authentication failed: \(reason)"
        }
    }
}

#endif // os(macOS)
