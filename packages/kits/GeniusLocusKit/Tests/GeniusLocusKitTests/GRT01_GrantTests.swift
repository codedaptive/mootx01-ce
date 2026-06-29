import Testing
import Foundation
import CryptoKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// GRT-01 — Grant object and custody modes 1–2 surface.
///
/// Eight tests against the federation grant surface per
/// DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §6 and Appendix B.1/B.2.
/// Custody modes 1 (mediated) and 2 (handed-over) are production at
/// v1.0; mode 3 (decay-derived) is gated behind IP clearance; mode 4
/// (time-aging) is a shippable software decay policy enforced on the
/// recall path. Mode-4 coverage lives in `GRT04_TimeAgingCustodyTests`.
///
/// Each test opens one estate through `GeniusLocusKit`, issues or
/// revokes grants through the unified verb surface, and asserts on the
/// observed `GrantStore` / `ScopeKeyVault` state. `now` is passed
/// explicitly wherever lifetime math matters so the assertions are
/// deterministic and never sleep on a wall clock.
@Suite("GRT-01 grant surface")
struct GRT01_GrantTests {

    // MARK: - Harness

    /// Fresh isolated in-memory storage for one estate.
    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    /// Open one estate through `GeniusLocusKit` over a fresh storage,
    /// returning the kit, the handle, and the storage (so a test can
    /// re-open the same storage to check manifest stability).
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle, InMemoryStorage) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-grt01")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle, storage)
    }

    /// A whole-estate grant options value for the named custody mode.
    private func options(
        _ custody: CustodyMode,
        grantee: UUID = UUID(),
        lifetime: GrantLifetime = .permanent
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee,
            scope: .wholeEstate,
            custodyMode: custody,
            lifetime: lifetime
        )
    }

    // MARK: - 1. issueGrant mode 1 (mediated)

    @Test
    func issueGrantMode1HoldsKeyInVault() async throws {
        let (kit, handle, _) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(.mediated))

        let storeOpt = await kit.grantStore(for: handle)
        let store = try #require(storeOpt)
        let active = try await store.active()
        #expect(active.count == 1, "one grant row after a single mediated issue")

        // Mode 1: the scope key never leaves custody, so it is not
        // returned to the caller and the vault retains it.
        #expect(result.scopeKey == nil, "mode 1 must not return the scope key to the caller")
        let vaultOpt = await kit.scopeVault(for: handle)
        let vault = try #require(vaultOpt)
        let holds = await vault.holdsScopeKey(for: result.grant.id)
        #expect(holds, "mode 1 vault retains the scope key internally")
    }

    // MARK: - 2. issueGrant mode 2 (handed-over)

    @Test
    func issueGrantMode2ReturnsKeyNotRetained() async throws {
        let (kit, handle, _) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(.handedOver))

        // Mode 2: the scope key is derived once and handed to the
        // recipient at issue; the vault keeps no copy.
        #expect(result.scopeKey != nil, "mode 2 returns the derived scope key at issue")
        let vaultOpt = await kit.scopeVault(for: handle)
        let vault = try #require(vaultOpt)
        let holds = await vault.holdsScopeKey(for: result.grant.id)
        #expect(!holds, "mode 2 vault must not retain a copy of the handed-over key")
    }

    // MARK: - 3. Grant is signed by the issuing estate's Ed25519 key

    @Test
    func grantSignatureVerifiesAgainstEstatePublicKey() async throws {
        let (kit, handle, storage) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(.mediated))

        let estate = try await LocusKit.Estate.open(storage: storage, owner: OwnerCredentials(ownerIdentifier: "owner-grt01"))
        let manifest = try await estate.manifest
        let pubKeyData = try #require(manifest.ed25519PublicKey)
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)

        #expect(
            pubKey.isValidSignature(result.grant.signature, for: result.grant.signingPayload),
            "issued grant signature must verify against the estate's Ed25519 public key"
        )
    }

    // MARK: - 4. revokeGrant mode 1 cryptographic clawback

    @Test
    func revokeMode1RemovesKeyAndBlocksAccess() async throws {
        let (kit, handle, _) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(.mediated))
        let vaultOpt = await kit.scopeVault(for: handle)
        let vault = try #require(vaultOpt)

        try await kit.revokeGrant(handle, grantID: result.grant.id)

        let holds = await vault.holdsScopeKey(for: result.grant.id)
        #expect(!holds, "mode 1 clawback removes the scope key from the vault")

        do {
            _ = try await vault.access(grant: result.grant, now: Date())
            Issue.record("access after revocation must throw")
        } catch let error as GrantError {
            guard case .grantRevoked = error else {
                Issue.record("expected grantRevoked, got \(error)")
                return
            }
        }
    }

    // MARK: - 5. revokeGrant mode 2 best-effort

    @Test
    func revokeMode2WritesRecordWithoutFaulting() async throws {
        let (kit, handle, _) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(.handedOver))

        // Mode 2 clawback is best-effort: it records the revocation and
        // does not fault on a (here, absent) offline recipient.
        try await kit.revokeGrant(handle, grantID: result.grant.id)

        let storeOpt = await kit.grantStore(for: handle)
        let store = try #require(storeOpt)
        let row = try await store.get(id: result.grant.id)
        #expect(row?.revokedAt != nil, "mode 2 revocation writes a revocation record")
    }

    // MARK: - 6. Custody mode 3 gates at issue without clearance

    @Test
    func decayDerivedGatesUnlessClearanceConfirmed() async throws {
        let (kit, handle, _) = try await openOneEstate()

        let mode3 = CustodyMode.decayDerived(
            threshold: 2, totalShares: 3, driftRatePerDay: .slow,
            experimentalIPClearanceConfirmed: false
        )
        do {
            _ = try await kit.issueGrant(handle, options(mode3))
            Issue.record("mode 3 without clearance must throw")
        } catch let error as GrantError {
            guard case .experimentalModeNotActivated = error else {
                Issue.record("expected experimentalModeNotActivated, got \(error)")
                return
            }
        }
    }

    // MARK: - 7. Lifetime enforced

    @Test
    func lifetimeExpiryBlocksMode1Access() async throws {
        let (kit, handle, _) = try await openOneEstate()
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let expiry = issuedAt.addingTimeInterval(1)  // one-second lifetime
        let result = try await kit.issueGrant(
            handle,
            options(.mediated, lifetime: .until(expiry)),
            now: issuedAt
        )
        let vaultOpt = await kit.scopeVault(for: handle)
        let vault = try #require(vaultOpt)

        // Before expiry: access succeeds.
        _ = try await vault.access(grant: result.grant, now: issuedAt)

        // After expiry: access raises grantExpired.
        do {
            _ = try await vault.access(grant: result.grant, now: expiry.addingTimeInterval(1))
            Issue.record("access after lifetime expiry must throw")
        } catch let error as GrantError {
            guard case .grantExpired = error else {
                Issue.record("expected grantExpired, got \(error)")
                return
            }
        }
    }

    // MARK: - Degenerate mode-3 custody parameters (Finding #2 regression)

    /// Mode 3 with `threshold = 0` must be rejected even when IP clearance is
    /// confirmed.  A zero threshold causes Lagrange reconstruction to interpolate
    /// an empty share set → `DecayFieldElement.zero` — a constant anyone can
    /// precompute, breaking the custody model (planned security hardening — B1
    /// finding #2).
    @Test("Mode-3 grant with threshold=0 is rejected (degenerate key guard)")
    func decayDerivedRejectsZeroThreshold() async throws {
        let (kit, handle, _) = try await openOneEstate()

        let mode3 = CustodyMode.decayDerived(
            threshold: 0, totalShares: 3, driftRatePerDay: .slow,
            experimentalIPClearanceConfirmed: true
        )
        do {
            _ = try await kit.issueGrant(handle, options(mode3))
            Issue.record("threshold=0 must throw invalidCustodyParameters")
        } catch let error as GrantError {
            guard case .invalidCustodyParameters = error else {
                Issue.record("expected invalidCustodyParameters, got \(error)")
                return
            }
        }
    }

    /// Mode 3 where `totalShares < threshold` must be rejected — you cannot
    /// reconstruct a secret from fewer shares than the threshold requires.
    @Test("Mode-3 grant with totalShares < threshold is rejected (degenerate key guard)")
    func decayDerivedRejectsTotalSharesBelowThreshold() async throws {
        let (kit, handle, _) = try await openOneEstate()

        let mode3 = CustodyMode.decayDerived(
            threshold: 5, totalShares: 3, driftRatePerDay: .slow,
            experimentalIPClearanceConfirmed: true
        )
        do {
            _ = try await kit.issueGrant(handle, options(mode3))
            Issue.record("totalShares < threshold must throw invalidCustodyParameters")
        } catch let error as GrantError {
            guard case .invalidCustodyParameters = error else {
                Issue.record("expected invalidCustodyParameters, got \(error)")
                return
            }
        }
    }

    /// Mode 3 where `totalShares > 255` must be rejected — the implementation
    /// cap (`maxDecayShares = 255`) guards against pathological share counts
    /// that would stress Lagrange interpolation.
    @Test("Mode-3 grant with totalShares > 255 is rejected (degenerate key guard)")
    func decayDerivedRejectsTotalSharesAboveCap() async throws {
        let (kit, handle, _) = try await openOneEstate()

        let mode3 = CustodyMode.decayDerived(
            threshold: 2, totalShares: 256, driftRatePerDay: .slow,
            experimentalIPClearanceConfirmed: true
        )
        do {
            _ = try await kit.issueGrant(handle, options(mode3))
            Issue.record("totalShares > 255 must throw invalidCustodyParameters")
        } catch let error as GrantError {
            guard case .invalidCustodyParameters = error else {
                Issue.record("expected invalidCustodyParameters, got \(error)")
                return
            }
        }
    }

    /// Valid mode-3 parameters (threshold > 0, totalShares ≥ threshold, ≤ 255,
    /// clearance confirmed) must succeed.  This verifies the guard is not a
    /// spurious barrier on the happy path.
    @Test("Mode-3 grant with valid parameters is accepted (gate not a spurious barrier)")
    func decayDerivedAcceptsValidParameters() async throws {
        let (kit, handle, _) = try await openOneEstate()

        let mode3 = CustodyMode.decayDerived(
            threshold: 2, totalShares: 3, driftRatePerDay: .slow,
            experimentalIPClearanceConfirmed: true
        )
        // Must not throw.
        _ = try await kit.issueGrant(handle, options(mode3))
    }

    // MARK: - 8. Manifest Ed25519 keypair present and stable

    @Test
    func manifestKeypairPresentAndStableAcrossReopen() async throws {
        let storage = makeStorage()
        let owner = OwnerCredentials(ownerIdentifier: "owner-grt01")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let first = try await LocusKit.Estate.open(storage: storage, owner: owner)
        let firstKey = try await first.manifest.ed25519PublicKey
        #expect(firstKey != nil, "estate open generates an Ed25519 public key")

        let second = try await LocusKit.Estate.open(storage: storage, owner: owner)
        let secondKey = try await second.manifest.ed25519PublicKey
        #expect(firstKey == secondKey, "keypair is stable across re-open from the same storage")
    }
}
