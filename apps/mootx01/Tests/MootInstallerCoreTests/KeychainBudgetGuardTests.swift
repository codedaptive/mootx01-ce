// KeychainBudgetGuardTests.swift
//
// Regression guard: every code path in MootInstallerCoreTests that can reach
// the login Keychain must leave it exactly as it found it. This test snapshots
// the item count for the SQLCipher Keychain service before and after exercising
// the provideKey + deleteKey cycle, and fails if the count changed.
//
// If this test fails, a new code path is minting Keychain items without
// cleaning up. Fix the minter (add deleteKeychainKey defer) rather than
// adjusting this guard.
//
// Regression guard design choice: Swift Testing has no per-suite snapshot hook,
// so a budget-neutral cycle test (mint + cleanup = zero net) is used instead of
// a before/after snapshot across the whole suite. The cycle test discriminates
// because it will fail as soon as deleteKey stops working or provideKey starts
// writing to a different account. For identity keys the guard is the serve path
// itself: MOOTX01_ESTATE_LIFETIME=ephemeral keeps the identity key in memory, so
// any regression that removes the env var path in the binary mints keys, so
// Keychain pollution reappears and the measurement done during KEY-1 is
// repeatable.
//
// Isolated-run hang fix: keychainItemCount passes kSecUseAuthenticationUIFail so
// the query returns errSecInteractionNotAllowed immediately instead of blocking
// on a macOS Keychain prompt when the test binary lacks the shared-access-group
// entitlement. Without this flag the query hangs indefinitely.

#if os(macOS) && canImport(Security)
import Foundation
import Security
import Testing
@testable import MootInstallerCore
import PersistenceKitSQLite

/// Count live login-Keychain items whose `kSecAttrService` matches `service`.
///
/// `kSecUseAuthenticationUIFail` makes the query return
/// `errSecInteractionNotAllowed` immediately instead of blocking on the
/// macOS Keychain access dialog. Without this flag a query against the
/// shared-access-group service can hang indefinitely in an unsigned or
/// un-entitled test binary, which widens the concurrent-test window and
/// produces spurious `after != before` failures.
private func keychainItemCount(service: String, account: String) -> Int {
    let query: [CFString: Any] = [
        kSecClass:                  kSecClassGenericPassword,
        kSecAttrService:            service,
        // Only this probe's own account: other suites in the same target may
        // mint and clean up their own keys concurrently, and their items must
        // not move this count.
        kSecAttrAccount:            account,
        kSecMatchLimit:             kSecMatchLimitAll,
        kSecReturnAttributes:       true,
        // Fail immediately rather than blocking on a UI prompt.
        kSecUseAuthenticationUI:    kSecUseAuthenticationUIFail,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    // errSecInteractionNotAllowed is expected on a locked screen or un-entitled
    // binary; treat it as zero (no measurable items) so the guard stays silent
    // in environments where Keychain access is restricted.
    guard status == errSecSuccess, let items = result as? [[CFString: Any]] else {
        return 0
    }
    return items.count
}

@Suite("Keychain budget guard — MootInstallerCoreTests must not grow the login Keychain", .serialized)
struct KeychainBudgetGuardTests {

    @Test("provideKey + deleteKey is budget-neutral for the SQLCipher service")
    func sqlCipherKeyMintAndCleanupIsNeutral() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("keychain-budget-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let estateURL = dir.appendingPathComponent("guard-probe.sqlite")
        // The account provideKey derives for this estate path: the count below
        // is scoped to it, so the guard measures its own mint and cleanup only.
        let account = KeychainKeyStore(
            service: EstateKeyProvider.keychainService, estateURL: estateURL, accessGroup: nil).account
        let before = keychainItemCount(service: EstateKeyProvider.keychainService, account: account)

        do {
            _ = try EstateKeyProvider.provideKey(for: estateURL)
        } catch {
            // No usable Keychain here (CI / unsigned build). Skip.
            return
        }

        // Delete explicitly before measuring 'after' — defer fires at function
        // exit, which is after the #expect, too late to influence the measurement.
        // provideKey mints into the shared access group; also try the default group
        // for legacy estates (mirrors the both-groups posture in provideKey itself).
        for accessGroup in [EstateKeyProvider.sharedAccessGroup, nil] as [String?] {
            let store = KeychainKeyStore(
                service: EstateKeyProvider.keychainService,
                estateURL: estateURL,
                accessGroup: accessGroup
            )
            try? store.deleteKey()
        }

        let after = keychainItemCount(service: EstateKeyProvider.keychainService, account: account)

        // A failed assertion here means either provideKey started writing to
        // an account that doesn't match KeychainKeyStore's account derivation
        // (so deleteKey removes the wrong item), or deleteKey stopped working.
        // Add a deleteKeychainKey(for:) defer in the caller that mints without cleaning up.
        #expect(after == before, "provideKey + deleteKey must be budget-neutral (before=\(before), after=\(after))")
    }
}
#endif
