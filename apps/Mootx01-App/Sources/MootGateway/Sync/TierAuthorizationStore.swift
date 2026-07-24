// TierAuthorizationStore.swift
//
// FAB5-ST — per-tier sync authorization backed by LocalAuthentication and Keychain.
//
// DESIGN:
// Authorization is granted per AdjectiveSensitivity tier via a biometry/passcode
// challenge (LAPolicy.deviceOwnerAuthentication). A successful challenge writes a
// sentinel value to the system keychain in the shared app group
// "com.codedaptive.mootx01"; authorization is revoked by deleting that item
// (no auth required to revoke — the user is reducing sync scope, not expanding it).
//
// Testability: LAContextEvaluating and TierKeychainStoring are internal protocols
// so test targets can inject doubles without hitting real biometry or the system
// keychain. The shared instance uses SystemLAContext + SystemTierKeychain.
//
// Thread safety: TierAuthorizationStore is an actor; all reads and writes execute
// on its serial executor. SystemTierKeychain calls SecItem* synchronously —
// acceptable since keychain operations are fast on-device and not on the main actor.

import Foundation
import LocalAuthentication
import LocusKit

// MARK: - Testability protocols

/// Abstracts LAContext so tests can inject a double without triggering biometry.
protocol LAContextEvaluating: Sendable {
    /// Returns true when the policy can be evaluated on this device.
    func canEvaluatePolicy(_ policy: LAPolicy) -> Bool
    /// Evaluates the policy, throwing an error on failure or cancellation.
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws
}

/// Abstracts Keychain access so tests can use an in-memory substitute.
protocol TierKeychainStoring: Sendable {
    /// True when a sentinel record for the service exists in the keychain.
    func exists(service: String) -> Bool
    /// Writes a sentinel record for the service. Idempotent on duplicate.
    func write(service: String) throws
    /// Deletes the sentinel record for the service. No-op when absent.
    func delete(service: String)
}

// MARK: - Production implementations

/// Production LAContext evaluator. Each call creates a fresh LAContext so
/// canEvaluatePolicy and evaluatePolicy are independent (no shared instance state).
struct SystemLAContext: LAContextEvaluating, @unchecked Sendable {
    func canEvaluatePolicy(_ policy: LAPolicy) -> Bool {
        LAContext().canEvaluatePolicy(policy, error: nil)
    }

    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws {
        // iOS 16+ / macOS 13+ async overload — safe on the iOS 27 deployment floor.
        try await LAContext().evaluatePolicy(policy, localizedReason: localizedReason)
    }
}

/// Production keychain store. Writes generic-password items keyed by service name
/// in the shared app access group. Values are a single 0x01 sentinel byte —
/// only presence (not content) is meaningful for authorization.
struct SystemTierKeychain: TierKeychainStoring, Sendable {
    private static let accessGroup = "com.codedaptive.mootx01"

    func exists(service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: Self.accessGroup,
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func write(service: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "tier-authorized",
            kSecAttrAccessGroup: Self.accessGroup,
            kSecUseDataProtectionKeychain: true,
            // ThisDeviceOnly: prevents the sentinel from migrating to a new device via
            // backup restore, which would grant remote sync scope without biometric
            // re-challenge on the new device (Perkins ADVISORY-1).
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: Data([0x01]),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TierAuthorizationError.keychainWriteFailed(status: Int(status))
        }
    }

    func delete(service: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: Self.accessGroup,
            kSecUseDataProtectionKeychain: true,
        ]
        // errSecItemNotFound is acceptable (idempotent delete).
        _ = SecItemDelete(query as CFDictionary)
    }
}

// MARK: - TierAuthorizationStore

/// Actor that guards per-tier sync authorization via LocalAuthentication and the system Keychain.
///
/// ## Authorization model
///
/// Each tier (`.restricted`, `.secret`) requires a separate authorization. A successful
/// `authorize(_:)` call triggers biometry-or-passcode and, on success, writes a sentinel
/// to the keychain. `revoke(_:)` deletes the sentinel without any authentication challenge
/// (reducing sync scope is always permitted without friction).
///
/// `effectiveCeiling` derives the tightest allowed ceiling from the authorized-tier set:
/// `.secret` authorized → `.secret` ceiling (all tiers sync);
/// `.restricted` authorized → `.restricted` ceiling (restricted + below sync);
/// otherwise → `.elevated` ceiling (the default restricted posture).
///
/// ## Testability
///
/// The initialiser accepts `LAContextEvaluating` and `TierKeychainStoring` so test
/// targets can inject doubles. Use `TierAuthorizationStore.shared` in production.
public actor TierAuthorizationStore {

    /// Shared production instance (real LocalAuthentication + system keychain).
    public static let shared = TierAuthorizationStore()

    private let auth: any LAContextEvaluating
    private let keychain: any TierKeychainStoring

    /// Initialise with injected dependencies.
    ///
    /// - Parameters:
    ///   - auth: LA evaluator (default: `SystemLAContext()`).
    ///   - keychain: Keychain store (default: `SystemTierKeychain()`).
    init(
        auth: any LAContextEvaluating = SystemLAContext(),
        keychain: any TierKeychainStoring = SystemTierKeychain()
    ) {
        self.auth = auth
        self.keychain = keychain
    }

    // MARK: - Authorization state

    /// Returns true when the keychain sentinel for `tier` is present.
    ///
    /// Synchronous read inside the actor — fast path, no async I/O.
    public func isAuthorized(_ tier: AdjectiveSensitivity) -> Bool {
        keychain.exists(service: keychainService(for: tier))
    }

    /// Attempts to authorize `tier` by evaluating biometry or passcode, then
    /// writing a keychain sentinel on success.
    ///
    /// Returns `false` when:
    /// - The device does not support the auth policy.
    /// - The user cancels or fails authentication.
    /// - The keychain write fails.
    ///
    /// Calling when the tier is already authorized is a no-op that returns `true`
    /// (the sentinel already exists; the keychain write is idempotent).
    public func authorize(_ tier: AdjectiveSensitivity) async -> Bool {
        guard auth.canEvaluatePolicy(.deviceOwnerAuthentication) else { return false }
        do {
            try await auth.evaluatePolicy(.deviceOwnerAuthentication,
                                          localizedReason: authReason(for: tier))
        } catch {
            return false
        }
        do {
            try keychain.write(service: keychainService(for: tier))
            return true
        } catch {
            return false
        }
    }

    /// Revokes authorization for `tier` by deleting its keychain sentinel.
    ///
    /// No authentication challenge is required — reducing sync scope is frictionless.
    /// Idempotent: a no-op when the tier was not authorized.
    public func revoke(_ tier: AdjectiveSensitivity) {
        keychain.delete(service: keychainService(for: tier))
    }

    // MARK: - Effective ceiling

    /// Derives the highest-sensitivity tier the device is authorized to sync.
    ///
    /// - `.secret` authorized → returns `.secret` (all four tiers sync).
    /// - `.restricted` authorized (but not `.secret`) → returns `.restricted`.
    /// - Neither authorized → returns `.elevated` (default restricted posture).
    ///
    /// The sync engine uses this as its sensitivity ceiling: rows whose tier
    /// exceeds the ceiling are suppressed outbound and rejected inbound.
    public var effectiveCeiling: AdjectiveSensitivity {
        if isAuthorized(.secret) { return .secret }
        if isAuthorized(.restricted) { return .restricted }
        return .elevated
    }

    // MARK: - Private helpers

    private func keychainService(for tier: AdjectiveSensitivity) -> String {
        "com.codedaptive.mootx01.sync-tier.\(tier.rawValue)"
    }

    private func authReason(for tier: AdjectiveSensitivity) -> String {
        switch tier {
        case .restricted:
            return String(localized: "tierauth.restricted.reason",
                          defaultValue: "Allow Restricted memories to sync to this device.")
        case .secret:
            return String(localized: "tierauth.secret.reason",
                          defaultValue: "Allow Secret memories to sync to this device.")
        default:
            return String(localized: "tierauth.generic.reason",
                          defaultValue: "Authorize sync for this tier.")
        }
    }
}

// MARK: - Error

enum TierAuthorizationError: Error {
    case keychainWriteFailed(status: Int)
}
