// TierAuthorizationStoreTests.swift
//
// FAB5-ST Part 1 — unit tests for TierAuthorizationStore.
//
// All tests inject a fake LAContext and an in-memory keychain so they never
// touch real biometry or the system keychain. Covers the three Part 1 verify
// conditions:
//
//   1. authorize() denied (LA returns failure) → tier remains unauthorized.
//   2. authorize() approved (LA returns success) → keychain sentinel written; tier authorized.
//   3. revoke() → keychain sentinel deleted; tier no longer authorized.

import Testing
import Foundation
import LocalAuthentication
import LocusKit
@testable import MootGateway

// MARK: - Test doubles

/// Fake LA evaluator. `canEvaluate` controls canEvaluatePolicy(); `shouldSucceed`
/// controls whether evaluatePolicy throws.
final class FakeLAContext: LAContextEvaluating, @unchecked Sendable {
    var canEvaluate: Bool
    var shouldSucceed: Bool

    init(canEvaluate: Bool = true, shouldSucceed: Bool) {
        self.canEvaluate = canEvaluate
        self.shouldSucceed = shouldSucceed
    }

    func canEvaluatePolicy(_ policy: LAPolicy) -> Bool { canEvaluate }

    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws {
        if !shouldSucceed {
            throw NSError(domain: "LAError", code: -2 /* LAError.authenticationFailed */, userInfo: nil)
        }
    }
}

/// In-memory keychain substitute. @unchecked Sendable — single-actor access in tests.
final class FakeKeychain: TierKeychainStoring, @unchecked Sendable {
    private(set) var stored: Set<String> = []

    func exists(service: String) -> Bool { stored.contains(service) }
    func write(service: String) throws { stored.insert(service) }
    func delete(service: String) { stored.remove(service) }
}

// MARK: - TierAuthorizationStore tests

@Suite("TierAuthorizationStore — LocalAuthentication-gated per-tier authorization")
struct TierAuthorizationStoreTests {

    // MARK: - Part 1 verify: enable-denied leaves tier off

    @Test("authorize() denied by LA — tier not authorized, returns false")
    func authorizeDeniedLeavesToff() async {
        let la = FakeLAContext(shouldSucceed: false)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        let result = await store.authorize(.restricted)

        #expect(result == false, "denied LA must return false")
        #expect(await store.isAuthorized(.restricted) == false, "tier must remain unauthorized after LA denial")
        #expect(kc.stored.isEmpty, "no keychain write on LA denial")
    }

    @Test("authorize() when device cannot evaluate policy — returns false immediately")
    func authorizeDeviceCannotEvaluate() async {
        let la = FakeLAContext(canEvaluate: false, shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        let result = await store.authorize(.restricted)

        #expect(result == false, "canEvaluate=false must short-circuit with false")
        #expect(kc.stored.isEmpty, "no keychain write when policy evaluation not available")
    }

    // MARK: - Part 1 verify: enable-approved persists

    @Test("authorize() approved — tier authorized, returns true, keychain written")
    func authorizeApprovedPersists() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        let result = await store.authorize(.restricted)

        #expect(result == true, "approved LA must return true")
        #expect(await store.isAuthorized(.restricted) == true, "tier must be authorized after approval")
        #expect(kc.stored.count == 1, "exactly one keychain entry written for the tier")
    }

    @Test("authorize() for secret tier — independent sentinel, does not affect restricted")
    func authorizeSecretIndependentFromRestricted() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        _ = await store.authorize(.secret)

        #expect(await store.isAuthorized(.secret) == true, "secret tier authorized")
        #expect(await store.isAuthorized(.restricted) == false, "restricted tier not affected")
    }

    @Test("authorize() called twice is idempotent — one keychain entry, still authorized")
    func authorizeIdempotent() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        _ = await store.authorize(.restricted)
        let result = await store.authorize(.restricted)  // second call

        #expect(result == true, "idempotent authorize must return true")
        #expect(await store.isAuthorized(.restricted) == true)
        #expect(kc.stored.count == 1, "single keychain entry despite two calls")
    }

    // MARK: - Part 1 verify: disable clears

    @Test("revoke() after authorize — tier no longer authorized, keychain entry removed")
    func revokeClears() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        _ = await store.authorize(.restricted)
        #expect(await store.isAuthorized(.restricted) == true, "pre-condition: authorized")

        await store.revoke(.restricted)

        #expect(await store.isAuthorized(.restricted) == false, "tier must not be authorized after revoke")
        #expect(kc.stored.isEmpty, "keychain entry must be removed on revoke")
    }

    @Test("revoke() when not authorized — no-op, no crash")
    func revokeWhenNotAuthorizedIsNoop() async {
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: FakeLAContext(shouldSucceed: true), keychain: kc)

        // Should not throw or crash.
        await store.revoke(.restricted)

        #expect(await store.isAuthorized(.restricted) == false)
    }

    @Test("revoke() restricted does not affect secret")
    func revokeRestrictedDoesNotClearSecret() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)

        _ = await store.authorize(.restricted)
        _ = await store.authorize(.secret)
        await store.revoke(.restricted)

        #expect(await store.isAuthorized(.restricted) == false, "restricted revoked")
        #expect(await store.isAuthorized(.secret) == true, "secret unaffected by restricted revoke")
    }

    // MARK: - effectiveCeiling

    @Test("effectiveCeiling — no tiers authorized → .elevated")
    func effectiveCeilingDefault() async {
        let store = TierAuthorizationStore(auth: FakeLAContext(shouldSucceed: false), keychain: FakeKeychain())
        let ceiling = await store.effectiveCeiling
        #expect(ceiling == .elevated)
    }

    @Test("effectiveCeiling — restricted authorized → .restricted")
    func effectiveCeilingRestricted() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        let ceiling = await store.effectiveCeiling
        #expect(ceiling == .restricted)
    }

    @Test("effectiveCeiling — secret authorized → .secret (regardless of restricted)")
    func effectiveCeilingSecret() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.secret)
        let ceiling = await store.effectiveCeiling
        #expect(ceiling == .secret)
    }

    @Test("effectiveCeiling — both tiers authorized → .secret (highest wins)")
    func effectiveCeilingBothAuthorized() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        _ = await store.authorize(.secret)
        let ceiling = await store.effectiveCeiling
        #expect(ceiling == .secret, "secret authorization takes precedence")
    }

    @Test("effectiveCeiling — restricted then revoked → returns to .elevated")
    func effectiveCeilingReverted() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        await store.revoke(.restricted)
        let ceiling = await store.effectiveCeiling
        #expect(ceiling == .elevated, "ceiling reverts to .elevated after revoke")
    }

    // MARK: - SyncPolicy.authorizedTiers (FAB5-ST Part 3)

    @Test("authorizedTiers — no tiers authorized → normal + elevated only")
    func authorizedTiersDefaultSet() async {
        let store = TierAuthorizationStore(auth: FakeLAContext(shouldSucceed: false), keychain: FakeKeychain())
        let tiers = await SyncPolicy.authorizedTiers(store: store)
        #expect(tiers == [.normal, .elevated], "base tiers always present")
    }

    @Test("authorizedTiers — restricted authorized → includes restricted")
    func authorizedTiersWithRestricted() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        let tiers = await SyncPolicy.authorizedTiers(store: store)
        #expect(tiers.contains(.restricted), "restricted must be in authorized set")
        #expect(tiers.contains(.normal), "normal always present")
        #expect(tiers.contains(.elevated), "elevated always present")
        #expect(!tiers.contains(.secret), "secret not authorized")
    }

    @Test("authorizedTiers — both tiers authorized → all four tiers")
    func authorizedTiersBothAuthorized() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        _ = await store.authorize(.secret)
        let tiers = await SyncPolicy.authorizedTiers(store: store)
        #expect(tiers == [.normal, .elevated, .restricted, .secret], "all four tiers authorized")
    }

    @Test("authorizedTiers — restricted then revoked → back to base set")
    func authorizedTiersAfterRevoke() async {
        let la = FakeLAContext(shouldSucceed: true)
        let kc = FakeKeychain()
        let store = TierAuthorizationStore(auth: la, keychain: kc)
        _ = await store.authorize(.restricted)
        await store.revoke(.restricted)
        let tiers = await SyncPolicy.authorizedTiers(store: store)
        #expect(tiers == [.normal, .elevated], "restricted removed after revoke")
    }
}
