import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// ENC-02 — Custody mode 3 (decay-derived key) conformance.
///
/// Seven tests against the decay-derived custody mode per
/// DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Appendix B.3 (the
/// mechanism), B.7 (the negative conformance tests), and B.8 (the
/// clean-room statement). Mode 3 reconstructs a scope key by Lagrange
/// interpolation at x=0 over K-of-N shares in GF(p); once the xi shares
/// drift past threshold K reconstruction throws `GrantError.keyDecayed`.
///
/// The grant-surface tests mirror the `GRT01_GrantTests` harness: one
/// estate opened through `GeniusLocusKit`, grants issued through the
/// unified verb surface, `now` passed explicitly so issuance and the
/// decay schedule are deterministic and never sleep on a wall clock.
@Suite("ENC-02 decay-derived key custody")
struct ENC02_DecayDerivedKeyTests {

    // MARK: - Harness

    /// Fresh isolated in-memory storage for one estate.
    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    /// Open one estate through `GeniusLocusKit` over fresh storage.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-enc02")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
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

    /// A clearance-confirmed mode-3 custody value.
    private func decayMode(
        threshold: Int = 3,
        totalShares: Int = 6,
        drift: DriftRate = .slow,
        confirmed: Bool = true
    ) -> CustodyMode {
        .decayDerived(
            threshold: threshold,
            totalShares: totalShares,
            driftRatePerDay: drift,
            experimentalIPClearanceConfirmed: confirmed
        )
    }

    /// A fixed issue instant so the decay schedule is deterministic.
    private let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. Clean-room reconstruction round-trip

    @Test
    func reconstructionRoundTripFromAnyKSubset() throws {
        // Build a reference provider: K=3 of N=6. At creation every share
        // is valid, so the polynomial is fully recoverable.
        let provider = ReferenceDecayShareProvider(
            threshold: 3,
            totalShares: 6,
            driftRate: .slow,
            createdAt: issuedAt,
            seed: Data("enc02-roundtrip-seed".utf8)
        )
        let points = provider.sharePoints()
        #expect(points.count == 6, "provider yields N=6 share points")

        // Several distinct 3-subsets must all interpolate to the same
        // constant term — the planted secret. If the GF(p) math were
        // wrong, different subsets would disagree.
        let subsets: [[Int]] = [[0, 1, 2], [3, 4, 5], [0, 2, 4], [1, 3, 5]]
        for indices in subsets {
            let subset = indices.map { points[$0] }
            let recovered = LagrangeDecayKey.interpolateConstantTerm(points: subset)
            #expect(
                recovered == provider.secret,
                "any K=3 subset \(indices) reconstructs the planted secret"
            )
        }

        // The reconstructed key equals the secret hashed to a 32-byte scope key
        // (feeds ENC-01 RowCrypto's AES-GCM-256 unchanged; no longer SymmetricKey,
        // now [UInt8] after the CryptoKit→in-repo migration).
        let key = try LagrangeDecayKey.reconstruct(
            threshold: 3, provider: provider, now: issuedAt
        )
        let expected = LagrangeDecayKey.key(fromSecret: provider.secret)
        #expect(
            key == expected,
            "reconstructed key equals SHA-256 of the secret field element"
        )
        #expect(key.count == 32, "reconstructed scope key is 32 bytes")
    }

    // MARK: - 2. Below threshold decays

    @Test
    func belowThresholdThrowsKeyDecayed() {
        // Fast drift: after one day far more than (N-K) shares have
        // corrupted, so fewer than K=2 of N=3 remain valid.
        let provider = ReferenceDecayShareProvider(
            threshold: 2,
            totalShares: 3,
            driftRate: .fast,
            createdAt: issuedAt,
            seed: Data("enc02-decay-seed".utf8)
        )
        let decayedNow = issuedAt.addingTimeInterval(86_400)  // +1 day
        #expect(
            provider.validShareCount(now: decayedNow) < 2,
            "fast drift leaves fewer than K valid shares after a day"
        )

        do {
            _ = try LagrangeDecayKey.reconstruct(
                threshold: 2, provider: provider, now: decayedNow
            )
            Issue.record("reconstruction below threshold must throw")
        } catch let error as GrantError {
            // Appendix B.7: returns keyDecayed rather than partial recovery.
            guard case .keyDecayed = error else {
                Issue.record("expected keyDecayed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected GrantError.keyDecayed, got \(error)")
        }
    }

    // MARK: - 3. Gate — clearance false rejected (Appendix B.7)

    @Test
    func clearanceFalseRejectedAtIssue() async throws {
        let (kit, handle) = try await openOneEstate()
        do {
            _ = try await kit.issueGrant(
                handle, options(decayMode(confirmed: false)), now: issuedAt
            )
            Issue.record("mode 3 without clearance must throw at issue")
        } catch let error as GrantError {
            guard case .experimentalModeNotActivated = error else {
                Issue.record("expected experimentalModeNotActivated, got \(error)")
                return
            }
        }
    }

    // MARK: - 4. Gate — clearance true issues

    @Test
    func clearanceTrueIssuesAndReturnsScopeKey() async throws {
        let (kit, handle) = try await openOneEstate()
        // Clearance confirmed: issuance proceeds without error.
        let result = try await kit.issueGrant(
            handle, options(decayMode()), now: issuedAt
        )
        let scopeKey = try #require(
            result.scopeKey, "mode 3 returns the reconstructed scope key at issue"
        )
        #expect(scopeKey.count == 32, "mode-3 scope key is a 32-byte AES key")
    }

    // MARK: - 5. No vault retention (no-durable-opener posture)

    @Test
    func noVaultRetentionAfterMode3Issue() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(
            handle, options(decayMode()), now: issuedAt
        )
        let vaultOpt = await kit.scopeVault(for: handle)
        let vault = try #require(vaultOpt)
        let holds = await vault.holdsScopeKey(for: result.grant.id)
        #expect(
            !holds, "mode 3 retains nothing in the vault (Appendix B.3 no-vault)"
        )
    }

    // MARK: - 6. Audit assertion recorded (Appendix B.7)

    @Test
    func auditEntryCarriesDecayDerivedToken() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(
            handle, options(decayMode()), now: issuedAt
        )
        let log = try await kit.auditLog(for: handle)
        let issued = log.orderedEntries.filter { $0.verb == .grantIssued }
        #expect(issued.count == 1, "one .grantIssued entry after a mode-3 issue")
        let entry = try #require(issued.first)
        #expect(entry.rowID == result.grant.id, "grant id carried in rowID")
        #expect(
            entry.fieldPath == "decayDerived",
            "the mode-3 grant's audit entry carries the decayDerived custody token"
        )
    }

    // MARK: - 7. Persistence round-trip

    @Test
    func persistedMode3GrantDecodesWithoutCorruptRow() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(
            handle, options(decayMode()), now: issuedAt
        )
        let storeOpt = await kit.grantStore(for: handle)
        let store = try #require(storeOpt)

        // The new custodyMode(from:) decodeDerived arm must round-trip the
        // discriminant without throwing corruptRow.
        let stored = try await store.get(id: result.grant.id)
        let grant = try #require(stored?.grant, "mode-3 grant decodes from storage")
        #expect(
            grant.custodyMode.signingToken == "decayDerived",
            "persisted custody-mode discriminant round-trips as decayDerived"
        )
    }
}
