import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit
@testable import LocusKit

/// GRT-04 — mode-4 time-aging custody.
///
/// Mode 4 (`CustodyMode.timeAging`) restores the Appendix B mode-4 slot as a
/// deterministic software decay policy (the SRAM/TARDIS physical-decay model is
/// unavailable in beta, so the shipped policy attenuates the grant's *effective
/// content level* over time instead). A grant's effective level halves every
/// `halfLifeSeconds` of elapsed time since `startedAt`, floored at `floor`,
/// computed against an injected `now` so every assertion is deterministic.
///
/// Coverage (per the restoration gate):
///  - issuance with and without explicit decay fields,
///  - persisted decode/read-back, including the legacy `physicalDecay` token,
///  - federation enforcement (decayed-below-floor refuses; mid-decay attenuates),
///  - budget interaction (debit composes with decay),
///  - aging behavior over injected time,
///  - the `DecayPolicy.effectiveLevel` math the parity fixtures pin.
@Suite("GRT-04 time-aging custody")
struct GRT04_TimeAgingCustodyTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> (EstateHandle, InMemoryStorage) {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (handle, storage)
    }

    /// The reference date is the decay-clock origin for these tests. Apple
    /// reference seconds make the elapsed-time math obvious: t0 + halfLife is
    /// exactly one half-life of decay.
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func timeAgingOptions(
        to grantee: UUID,
        halfLifeSeconds: Int,
        startedAt: Date,
        floor: Int,
        contentLevel: Int
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee,
            scope: .wholeEstate,
            custodyMode: .timeAging(DecayPolicy(
                halfLifeSeconds: halfLifeSeconds, startedAt: startedAt, floor: floor
            )),
            lifetime: .permanent,
            contentLevel: contentLevel
        )
    }

    private func captureWithSensitivity(
        into handle: EstateHandle,
        tag: String,
        sensitivity: AdjectiveSensitivity,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let estate = try await kit.estate(for: handle)
        return try await estate.capture(CaptureFrame(
            content: "content-\(tag)",
            channel: .typed,
            room: "room-\(tag)",
            latticeAnchor: .udc("004"),
            addedBy: "test",
            embeddingModelID: "model-v1",
            sensitivity: sensitivity
        ))
    }

    private var allSensitivityFrame: RecallFrame {
        RecallFrame(filterChain: [.unconfirmed, .sensitivityAtMost(.secret)])
    }

    // MARK: - 1. Issuance — explicit decay fields round-trip into the store

    @Test
    func issueWithExplicitDecayFieldsPersistsPolicy() async throws {
        let kit = GeniusLocusKit()
        let (handle, _) = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "owner-ta-issue"))
        let grantee = UUID()

        let result = try await kit.issueGrant(
            handle,
            timeAgingOptions(to: grantee, halfLifeSeconds: 3600, startedAt: t0, floor: 1, contentLevel: 48),
            now: t0
        )
        // Mode 4 derives a handed-over key (vault retains nothing).
        #expect(result.scopeKey != nil, "mode 4 hands the scope key to the recipient")
        let vault = try #require(await kit.scopeVault(for: handle))
        let holds = await vault.holdsScopeKey(for: result.grant.id)
        #expect(!holds, "mode 4 vault retains no key")

        // The persisted grant decodes back with the same policy.
        let store = try #require(await kit.grantStore(for: handle))
        let stored = try #require(try await store.get(id: result.grant.id))
        guard case .timeAging(let policy) = stored.grant.custodyMode else {
            Issue.record("decoded custody mode is not .timeAging")
            return
        }
        #expect(policy.halfLifeSeconds == 3600)
        #expect(policy.floor == 1)
        #expect(policy.startedAt == t0, "decay clock round-trips through the dedicated column")
    }

    // MARK: - 2. Decode/read-back — legacy physicalDecay token migrates

    @Test
    func legacyPhysicalDecayTokenDecodesIntoTimeAgingWithDefaults() async throws {
        let kit = GeniusLocusKit()
        let (handle, _) = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "owner-ta-legacy"))
        // Materialize the grant store: it is created lazily on first issue.
        _ = try await kit.issueGrant(handle, timeAgingOptions(
            to: UUID(), halfLifeSeconds: 100, startedAt: t0, floor: 0, contentLevel: 0
        ), now: t0)
        let store = try #require(await kit.grantStore(for: handle))

        // Write a row with the legacy mode-4 token and NO decay columns,
        // exactly as a pre-decay-schema install would have left it.
        let id = UUID()
        let issuedAt = t0
        // Encode scope/lifetime exactly as the store does, so only the custody
        // token (the legacy alias) differs from a normal row.
        let encoder = JSONEncoder()
        let scopeJSON = String(decoding: try encoder.encode(GrantScope.wholeEstate), as: UTF8.self)
        let lifetimeJSON = String(decoding: try encoder.encode(GrantLifetime.permanent), as: UTF8.self)
        try await store.rawUpsert([
            "id": .text(id.uuidString),
            "grantee_id": .text(UUID().uuidString),
            "scope_json": .text(scopeJSON),
            "content_level": .int(32),
            "custody_mode": .text("physicalDecay"),
            "lifetime_json": .text(lifetimeJSON),
            "reshare": .text("none"),
            "inference_budget": .float(1.0),
            "issued_at": .timestamp(issuedAt),
            "signature": .blob(Data())
        ])

        let stored = try #require(try await store.get(id: id),
            "legacy physicalDecay row must decode, never fault as corruptRow")
        guard case .timeAging(let policy) = stored.grant.custodyMode else {
            Issue.record("legacy physicalDecay token did not decode into .timeAging")
            return
        }
        // Documented defaults: 30-day half-life, decay clock = issued_at, floor 0.
        #expect(policy.halfLifeSeconds == DecayPolicy.defaultHalfLifeSeconds)
        #expect(policy.floor == 0)
        #expect(policy.startedAt == issuedAt,
            "legacy row with no decay_started_at defaults the decay clock to issued_at")
    }

    // MARK: - 3. effectiveLevel math — the parity-pinned values

    @Test
    func effectiveLevelHalvesEachHalfLifeAndFloors() {
        // base 48, half-life 100s, floor 4.
        let policy = DecayPolicy(halfLifeSeconds: 100, startedAt: t0, floor: 4)
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0) == 48, "t0: undecayed")
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0.addingTimeInterval(100)) == 24, "one half-life: 24")
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0.addingTimeInterval(200)) == 12, "two half-lives: 12")
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0.addingTimeInterval(300)) == 6, "three half-lives: 6")
        // Four half-lives → 3, below the floor of 4 → clamped to 4.
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0.addingTimeInterval(400)) == 4, "floor clamps the residual")
        // A `now` before startedAt yields the undecayed base.
        #expect(policy.effectiveLevel(baseLevel: 48, now: t0.addingTimeInterval(-50)) == 48, "pre-start is undecayed")
    }

    // MARK: - 4. Federation — decayed-below-floor (floor 0) refuses

    @Test
    func decayedToZeroFloorZeroRefusesCustody() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-ta-refuse")
        let (hA, _) = try await openEstate(in: kit, owner: owner)
        let (hB, _) = try await openEstate(in: kit, owner: owner)

        // B grants A a level-32 grant that halves every 100s, floor 0.
        _ = try await kit.issueGrant(
            hB,
            timeAgingOptions(to: hA.estateUUID, halfLifeSeconds: 100, startedAt: t0, floor: 0, contentLevel: 32),
            now: t0
        )
        _ = try await captureWithSensitivity(into: hB, tag: "b", sensitivity: .normal, kit: kit)

        // Far past 32 → 0: at t0 + 1000s (ten half-lives) the level is 0, refused.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(
                allSensitivityFrame, from: hB, requestedBy: hA, now: t0.addingTimeInterval(1000)
            )
        }
        if case .crossEstateReadRefused(_, _, let reason)? = thrown {
            #expect(reason == .custodyRefused, "decayed-to-zero grant refuses with custodyRefused")
        } else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
        }
    }

    // MARK: - 5. Federation — mid-decay attenuates the content-level gate

    @Test
    func midDecayAttenuatesContentLevelGate() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-ta-attenuate")
        let (hA, _) = try await openEstate(in: kit, owner: owner)
        let (hB, _) = try await openEstate(in: kit, owner: owner)

        // Grant exposes contentLevel 48 (admits secret=48). Half-life 100s, floor 0.
        _ = try await kit.issueGrant(
            hB,
            timeAgingOptions(to: hA.estateUUID, halfLifeSeconds: 100, startedAt: t0, floor: 0, contentLevel: 48),
            now: t0
        )
        // B holds one normal (0) and one restricted (32) drawer.
        let normal = try await captureWithSensitivity(into: hB, tag: "n", sensitivity: .normal, kit: kit)
        let restricted = try await captureWithSensitivity(into: hB, tag: "r", sensitivity: .restricted, kit: kit)

        // At t0 + 100 (one half-life) effective level is 24: admits normal (0)
        // but excludes restricted (32). Budget is 1.0 so the read proceeds.
        let result = try await kit.federatedRecall(
            allSensitivityFrame, from: hB, requestedBy: hA, now: t0.addingTimeInterval(100)
        )
        let ids = Set(result.drawers.map(\.id))
        #expect(ids.contains(normal.id), "normal drawer survives the attenuated gate")
        #expect(!ids.contains(restricted.id), "restricted drawer excluded once level decays to 24")
    }

    // MARK: - 6. Budget interaction — debit composes with decay

    @Test
    func budgetDebitsWhileDecayAttenuates() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-ta-budget")
        let (hA, _) = try await openEstate(in: kit, owner: owner)
        let (hB, _) = try await openEstate(in: kit, owner: owner)

        let issued = try await kit.issueGrant(
            hB,
            timeAgingOptions(to: hA.estateUUID, halfLifeSeconds: 100, startedAt: t0, floor: 1, contentLevel: 48),
            now: t0
        )
        _ = try await captureWithSensitivity(into: hB, tag: "b", sensitivity: .normal, kit: kit)
        let store = try #require(await kit.grantStore(for: hB))

        // Two reads mid-decay (floor 1 keeps the grant usable). Each debits 0.01.
        _ = try await kit.federatedRecall(allSensitivityFrame, from: hB, requestedBy: hA, now: t0.addingTimeInterval(100))
        _ = try await kit.federatedRecall(allSensitivityFrame, from: hB, requestedBy: hA, now: t0.addingTimeInterval(200))

        let after = try #require(try await store.get(id: issued.grant.id))
        #expect(abs(after.grant.inferenceRemainingBudget - 0.98) < 1e-9,
            "two reads debit the budget by 0.02 regardless of decay state")
    }
}
