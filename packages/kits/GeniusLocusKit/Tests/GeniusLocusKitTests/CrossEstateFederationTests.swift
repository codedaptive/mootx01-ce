import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit
// @testable import LocusKit grants access to Estate.store (internal let),
// needed to inject drawers with arbitrary wings for scope-filter tests.
// CaptureFrame has no wing slot; the only way to create drawers in non-default
// wings is to write directly to DrawerStore via the internal store property.
@testable import LocusKit

/// GLK-FED-01 — grant-gated cross-estate federated read.
///
/// `federatedRecall(from:requestedBy:)` reads content from one
/// locally-open estate on behalf of another, refusing unless the source
/// estate holds an active, unexpired grant naming the requester as
/// grantee. These tests make the A-versus-C refusal
/// (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13, cookbook I-23)
/// executable: B answers A only from B-authored or B-to-A-granted
/// content; a read of C's content by A with no C-to-A grant is refused,
/// not silently empty.
///
/// All estates are local registry entries in one kit instance — this is
/// the locally-mediated federation layer, not a device-boundary crossing
/// (I-13). `now` is passed explicitly wherever grant expiry matters so
/// the assertions are deterministic and never sleep on a wall clock.
///
/// GRANT_BOUNDARY_001 — contentLevel enforcement (tests 7–9):
/// `federatedRecall` applies the content-level sensitivity gate before
/// returning drawers. A grant with `contentLevel: 0` exposes only
/// normal-sensitivity rows; higher levels progressively admit elevated,
/// restricted, and secret rows. Enforcement is at the GLK layer —
/// these tests invoke `federatedRecall` directly with no ARIA surface
/// involved, verifying GLK is the primary enforcer.
///
/// GRANT-SCOPE-P1 — scope subtree enforcement (tests 10–14):
/// `federatedRecall` applies the scope subtree filter after the
/// content-level gate. The five `GrantScope` cases are: `.wholeEstate`
/// (pass-through), `.wing`, `.room`, `.latticeSubtree`, and `.singleRow`.
/// GLK is the primary enforcer; these tests call `federatedRecall`
/// directly with no ARIA surface, verifying GLK narrows correctly for
/// each scope case.
@Suite("Cross-estate federation")
struct CrossEstateFederationTests {

    // MARK: - Harness

    /// Open one fresh in-memory estate through `GeniusLocusKit`,
    /// returning its handle. Each call uses isolated storage, so the
    /// estates are mutually isolated with distinct estate UUIDs.
    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner)
    }

    /// Capture one tagged drawer into the estate addressed by `handle`.
    private func capture(
        into handle: EstateHandle,
        tag: String,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let estate = try await kit.estate(for: handle)
        return try await estate.capture(CaptureFrame(
            content: "content-\(tag)",
            channel: .typed,
            room: "room-\(tag)",
            latticeAnchor: .udc("004"),
            addedBy: "test",
            embeddingModelID: "model-v1"
        ))
    }

    /// A whole-estate grant naming `grantee` as grantee.
    private func grantOptions(
        to grantee: EstateHandle,
        lifetime: GrantLifetime = .permanent,
        contentLevel: Int = 0
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee.estateUUID,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: lifetime,
            contentLevel: contentLevel
        )
    }

    /// Capture a drawer with the given sensitivity tier set at creation time.
    /// Uses `LocusKit.CaptureFrame.sensitivity` directly so the stored
    /// `adjectiveBitmap` reflects the requested tier from the first write;
    /// no post-hoc mutation is needed.
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

    /// Recall with `.userConfirmed` so the default `.userConfirmed` prepend
    /// does not prune freshly-captured drawers (provenance == 0). This is
    /// the same frame the GLK-01 fan-out tests use for the same reason.
    private var unconfirmedFrame: RecallFrame {
        RecallFrame(filterChain: [.userConfirmed])
    }

    /// Recall frame that admits ALL sensitivity tiers (normal through secret)
    /// plus unconfirmed drawers. The default `BitmapEvaluator` sensitivity
    /// ceiling is `.elevated`; supplying `.sensitivityAtMost(.secret)` overrides
    /// that default so the contentLevel enforcement tests can verify GLK is
    /// the sole gating mechanism, independent of the recall-frame ceiling.
    private var allSensitivityFrame: RecallFrame {
        RecallFrame(filterChain: [.userConfirmed, .sensitivityAtMost(.secret)])
    }

    // MARK: - 1. Positive — valid grant yields the source's drawer

    @Test
    func validGrantReturnsSourceDrawerAndAuthorizingGrant() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-positive")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // B grants whole-estate read to A, then captures a drawer.
        let issued = try await kit.issueGrant(hB, grantOptions(to: hA))
        let dB = try await capture(into: hB, tag: "b", kit: kit)

        let result = try await kit.federatedRecall(
            unconfirmedFrame, from: hB, requestedBy: hA
        )

        #expect(result.drawers.map(\.id).contains(dB.id),
            "valid grant must return the source estate's captured drawer")
        #expect(result.grant.id == issued.grant.id,
            "result carries the authorizing grant as context")
        #expect(result.sourceHandle == hB)
        #expect(result.requesterHandle == hA)
    }

    // MARK: - 2. Negative — the A-versus-C refusal (I-23 §13)

    @Test
    func readOfUngrantedEstateRefusesNoActiveGrant() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-avc")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)
        let hC = try await openEstate(in: kit, owner: owner)

        // B grants to A only; C grants nothing. C captures content.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await capture(into: hC, tag: "c", kit: kit)

        // A reading C is refused — A holds no grant from C.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(unconfirmedFrame, from: hC, requestedBy: hA)
        }
        if case .crossEstateReadRefused(let source, let requester, let reason)? = thrown {
            #expect(source == hC.estateUUID)
            #expect(requester == hA.estateUUID)
            #expect(reason == .noActiveGrant,
                "no C-to-A grant exists — refusal reason is noActiveGrant")
        } else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
        }
    }

    // MARK: - 3. Expiry — refuses after expiry, succeeds before

    @Test
    func expiredGrantRefusesAfterExpirySucceedsBefore() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-expiry")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let expiry = issuedAt.addingTimeInterval(60)  // one-minute lifetime
        _ = try await kit.issueGrant(
            hB,
            grantOptions(to: hA, lifetime: .until(expiry)),
            now: issuedAt
        )
        let dB = try await capture(into: hB, tag: "b-exp", kit: kit)

        // Before expiry: the read succeeds.
        let before = try await kit.federatedRecall(
            unconfirmedFrame, from: hB, requestedBy: hA,
            now: issuedAt.addingTimeInterval(30)
        )
        #expect(before.drawers.map(\.id).contains(dB.id),
            "read before expiry returns the source's drawer")

        // After expiry: the read refuses with .grantExpired.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(
                unconfirmedFrame, from: hB, requestedBy: hA,
                now: expiry.addingTimeInterval(1)
            )
        }
        if case .crossEstateReadRefused(_, _, let reason)? = thrown {
            #expect(reason == .grantExpired,
                "a matching grant exists but its lifetime elapsed")
        } else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
        }
    }

    // MARK: - 4. Revocation — refuses after revoke

    @Test
    func revokedGrantRefusesRead() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-revoke")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        let issued = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await capture(into: hB, tag: "b-rev", kit: kit)

        // Sanity: the read works while the grant is active.
        _ = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)

        // Revoke, then the read refuses. A revoked grant is dropped from
        // GrantStore.active(), so the gate sees no active grant.
        try await kit.revokeGrant(hB, grantID: issued.grant.id)
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        }
        if case .crossEstateReadRefused(_, _, let reason)? = thrown {
            #expect(reason == .noActiveGrant,
                "revocation removes the grant from active() — refusal is noActiveGrant")
        } else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
        }
    }

    // MARK: - 5. Isolation — only the source's rows, never the requester's

    @Test
    func federatedReadReturnsOnlySourceRows() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-isolation")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // A captures its own drawer; B grants to A and captures its own.
        let dA = try await capture(into: hA, tag: "a-own", kit: kit)
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))
        let dB = try await capture(into: hB, tag: "b-own", kit: kit)

        let result = try await kit.federatedRecall(
            unconfirmedFrame, from: hB, requestedBy: hA
        )
        let ids = result.drawers.map(\.id)
        #expect(ids.contains(dB.id),
            "result contains the source estate's row")
        #expect(!ids.contains(dA.id),
            "result must never contain the requester's own row (storage isolation)")
    }

    // MARK: - 6. Stale handle — fail-closed on a closed estate

    @Test
    func staleSourceHandleThrowsEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-stale")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)
        try await kit.close(hB)  // hB is now stale

        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        }
        if case .estateNotOpen(let uuid)? = thrown {
            #expect(uuid == hB.estateUUID)
        } else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }

    // MARK: - Scope helpers

    /// Grant options with an explicit scope. Unlike `grantOptions(to:lifetime:contentLevel:)`,
    /// which hardcodes `.wholeEstate`, this helper accepts any GrantScope so the scope
    /// enforcement tests can issue narrowed grants without reusing the whole-estate helper.
    private func scopedGrantOptions(
        to grantee: EstateHandle,
        scope: GrantScope
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee.estateUUID,
            scope: scope,
            custodyMode: .mediated,
            lifetime: .permanent,
            contentLevel: 0
        )
    }

    /// Inject a drawer with arbitrary wing, room, and udcCode into the estate
    /// addressed by `handle`, bypassing `Estate.capture` (which always writes to
    /// `defaultWing()`). Requires `@testable import LocusKit` for `Estate.store`
    /// access. The drawer is stamped with `Confirmation.userConfirmed` (bits 18-23
    /// of provenance) so that recall with `[.userConfirmed]` can surface it — a
    /// direct `store.addDrawer` call bypasses the `Estate.capture` path that stamps
    /// this automatically.
    private func captureWithAttributes(
        into handle: EstateHandle,
        wing: String,
        room: String,
        udcCode: String,
        tag: String,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let locusEstate = try await kit.estate(for: handle)
        let store = await locusEstate.store
        let now = Date()
        // Stamp Confirmation.userConfirmed (raw 1) at bits 18-23 of provenance.
        // Drawers inserted via store.addDrawer bypass Estate.capture (which stamps
        // this automatically), so we set it explicitly so that recall with
        // [.userConfirmed] can surface these rows.
        let confirmedProvenance: Int64 = 1 << 18  // Confirmation.userConfirmed shifted to bits 18-23
        let drawer = Drawer(
            content: "content-\(tag)",
            wing: wing,
            room: room,
            addedBy: "test",
            filedAt: now,
            embeddingModelID: "model-v1",
            provenance: confirmedProvenance,
            udcCode: udcCode
        )
        try await store.addDrawer(drawer, now: now)
        return drawer
    }

    // MARK: - 7. contentLevel=0 excludes elevated-sensitivity drawers (GRANT_BOUNDARY_001)

    /// A grant with `contentLevel: 0` (default) exposes only normal-sensitivity
    /// drawers. Elevated drawers captured in the source estate are excluded from
    /// the federated result. This test verifies GLK is the primary enforcer —
    /// ARIA is not involved; `federatedRecall` is called directly.
    @Test
    func contentLevelZeroExcludesElevatedSensitivityDrawers() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-cl-zero")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // contentLevel: 0 (default) — only normal-sensitivity rows should pass.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, contentLevel: 0))

        // Capture one normal drawer and one elevated drawer in source estate B.
        // Sensitivity is set at capture time via CaptureFrame.sensitivity so
        // the stored adjectiveBitmap reflects the tier from the first write.
        let dNormal   = try await captureWithSensitivity(into: hB, tag: "cl-normal",   sensitivity: .normal,   kit: kit)
        let dElevated = try await captureWithSensitivity(into: hB, tag: "cl-elevated", sensitivity: .elevated, kit: kit)

        // allSensitivityFrame overrides BitmapEvaluator's default
        // `.sensitivityAtMost(.elevated)` ceiling so the GLK contentLevel
        // gate is the sole filter under test. Without this override, the
        // recall itself would exclude restricted drawers before GLK can act.
        let result = try await kit.federatedRecall(allSensitivityFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dNormal.id),
            "contentLevel=0 must include normal-sensitivity rows (rawValue=0 ≤ 0)")
        #expect(!ids.contains(dElevated.id),
            "contentLevel=0 must exclude elevated-sensitivity rows (rawValue=16 > 0)")
    }

    // MARK: - 8. contentLevel=16 admits elevated, excludes restricted (GRANT_BOUNDARY_001)

    /// A grant with `contentLevel: 16` admits normal and elevated drawers but
    /// excludes restricted and secret rows. This verifies the filter is
    /// threshold-based, not binary.
    @Test
    func contentLevelSixteenAdmitsElevatedExcludesRestricted() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-cl-sixteen")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // contentLevel: 16 — normal (0) and elevated (16) pass; restricted (32) blocked.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, contentLevel: 16))

        let dNormal   = try await captureWithSensitivity(into: hB, tag: "cl16-normal",     sensitivity: .normal,     kit: kit)
        let dElevated = try await captureWithSensitivity(into: hB, tag: "cl16-elevated",   sensitivity: .elevated,   kit: kit)
        let dRestrict = try await captureWithSensitivity(into: hB, tag: "cl16-restricted", sensitivity: .restricted, kit: kit)

        let result = try await kit.federatedRecall(allSensitivityFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dNormal.id),
            "contentLevel=16 must include normal rows (rawValue=0 ≤ 16)")
        #expect(ids.contains(dElevated.id),
            "contentLevel=16 must include elevated rows (rawValue=16 ≤ 16)")
        #expect(!ids.contains(dRestrict.id),
            "contentLevel=16 must exclude restricted rows (rawValue=32 > 16)")
    }

    // MARK: - GRANT-SCOPE-P1 — scope subtree enforcement (tests 10–14)

    // MARK: - 9. Unrestricted grant (contentLevel=48) admits all sensitivities (GRANT_BOUNDARY_001)

    /// A grant with `contentLevel: 48` (secret tier, the maximum) admits drawers
    /// at all four sensitivity tiers. This verifies that the filter does not
    /// over-exclude when the grant explicitly unlocks all content.
    @Test
    func contentLevelFortyEightAdmitsAllSensitivities() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-cl-max")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // contentLevel: 48 — all four tiers pass (AdjectiveSensitivity.secret.rawValue == 48).
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, contentLevel: 48))

        let dNormal   = try await captureWithSensitivity(into: hB, tag: "clmax-normal",     sensitivity: .normal,     kit: kit)
        let dElevated = try await captureWithSensitivity(into: hB, tag: "clmax-elevated",   sensitivity: .elevated,   kit: kit)
        let dRestrict = try await captureWithSensitivity(into: hB, tag: "clmax-restricted", sensitivity: .restricted, kit: kit)
        let dSecret   = try await captureWithSensitivity(into: hB, tag: "clmax-secret",     sensitivity: .secret,     kit: kit)

        let result = try await kit.federatedRecall(allSensitivityFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dNormal.id),
            "contentLevel=48 must include normal rows (rawValue=0 ≤ 48)")
        #expect(ids.contains(dElevated.id),
            "contentLevel=48 must include elevated rows (rawValue=16 ≤ 48)")
        #expect(ids.contains(dRestrict.id),
            "contentLevel=48 must include restricted rows (rawValue=32 ≤ 48)")
        #expect(ids.contains(dSecret.id),
            "contentLevel=48 must include secret rows (rawValue=48 ≤ 48)")
    }

    // MARK: - 10. .wing scope narrows to the granted wing (GRANT-SCOPE-P1)

    /// A grant with `.wing("wing_scope-wing")` returns only drawers whose
    /// `wing` matches the granted name. A drawer injected into a different
    /// wing via `captureWithAttributes` is excluded. Tests that the wing
    /// filter is both inclusive (matching drawers pass) and exclusive
    /// (non-matching drawers are dropped).
    @Test
    func scopeWingNarrowsToGrantedWing() async throws {
        let kit = GeniusLocusKit()
        // Owner identifier "scope-wing" → defaultWing() = "wing_scope-wing".
        let srcOwner = OwnerCredentials(ownerIdentifier: "scope-wing")
        let reqOwner = OwnerCredentials(ownerIdentifier: "scope-wing-req")
        let hB = try await openEstate(in: kit, owner: srcOwner)
        let hA = try await openEstate(in: kit, owner: reqOwner)

        // Drawer in the granted wing (via normal capture → defaultWing).
        let dInWing = try await capture(into: hB, tag: "scope-wing-in", kit: kit)
        // Drawer injected directly into a different wing.
        let dOutWing = try await captureWithAttributes(
            into: hB, wing: "other-wing", room: "r", udcCode: "004",
            tag: "scope-wing-out", kit: kit)

        _ = try await kit.issueGrant(hB, scopedGrantOptions(to: hA, scope: .wing("wing_scope-wing")))

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dInWing.id),
            "wing scope must include drawers in the granted wing")
        #expect(!ids.contains(dOutWing.id),
            "wing scope must exclude drawers in other wings")
    }

    // MARK: - 11. .room scope narrows to the granted room (GRANT-SCOPE-P1)

    /// A grant with `.room("room-r1")` returns only drawers whose `room`
    /// field equals the granted room name. The capture helper sets
    /// `room: "room-\(tag)"`, so two captures with different tags land in
    /// different rooms — no DrawerStore injection required for this case.
    @Test
    func scopeRoomNarrowsToGrantedRoom() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scope-room")
        let hB = try await openEstate(in: kit, owner: owner)
        let hA = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "scope-room-req"))

        // Two drawers in different rooms ("room-r1" and "room-r2").
        let dInRoom  = try await capture(into: hB, tag: "r1", kit: kit)
        let dOutRoom = try await capture(into: hB, tag: "r2", kit: kit)

        _ = try await kit.issueGrant(hB, scopedGrantOptions(to: hA, scope: .room("room-r1")))

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dInRoom.id),
            "room scope must include the drawer in the granted room")
        #expect(!ids.contains(dOutRoom.id),
            "room scope must exclude drawers in other rooms")
    }

    // MARK: - 12. .latticeSubtree scope narrows by udcCode prefix (GRANT-SCOPE-P1)

    /// A grant with `.latticeSubtree(udcCode: "500")` returns drawers whose
    /// `udcCode` equals "500" or starts with "500." and excludes those outside
    /// the subtree. The four drawers cover the exact root ("500"), two
    /// subtree members ("500.1", "500.2"), and two outside the subtree ("600",
    /// "5001"). The "5001" case is the dot-boundary guard: a bare hasPrefix
    /// would incorrectly admit it because "5001" starts with "500".
    @Test
    func scopeLatticeSubtreeNarrowsByPrefix() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scope-lattice")
        let hB = try await openEstate(in: kit, owner: owner)
        let hA = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "scope-lattice-req"))

        let d500    = try await captureWithAttributes(
            into: hB, wing: "w", room: "r", udcCode: "500",   tag: "500",   kit: kit)
        let d500_1  = try await captureWithAttributes(
            into: hB, wing: "w", room: "r", udcCode: "500.1", tag: "500-1", kit: kit)
        let d500_2  = try await captureWithAttributes(
            into: hB, wing: "w", room: "r", udcCode: "500.2", tag: "500-2", kit: kit)
        let d600    = try await captureWithAttributes(
            into: hB, wing: "w", room: "r", udcCode: "600",   tag: "600",   kit: kit)
        // "5001" starts with "500" but is NOT in the "500" subtree.
        // The dot-boundary guard must exclude it.
        let d5001   = try await captureWithAttributes(
            into: hB, wing: "w", room: "r", udcCode: "5001",  tag: "5001",  kit: kit)

        _ = try await kit.issueGrant(
            hB, scopedGrantOptions(to: hA, scope: .latticeSubtree(udcCode: "500")))

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(d500.id),
            "latticeSubtree scope must include the exact root code '500'")
        #expect(ids.contains(d500_1.id),
            "latticeSubtree scope must include '500.1' (child via dot boundary)")
        #expect(ids.contains(d500_2.id),
            "latticeSubtree scope must include '500.2' (child via dot boundary)")
        #expect(!ids.contains(d600.id),
            "latticeSubtree scope must exclude '600' (different subtree)")
        #expect(!ids.contains(d5001.id),
            "latticeSubtree scope must exclude '5001' (adjacent code, not a dot-child of '500')")
    }

    // MARK: - 13. .singleRow scope narrows to exactly one drawer (GRANT-SCOPE-P1)

    /// A grant with `.singleRow(uuid)` returns only the one drawer whose
    /// `id` (a UUID string) matches `uuid.uuidString`. All other drawers
    /// in the source estate are excluded.
    @Test
    func scopeSingleRowNarrowsToOneRow() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scope-single")
        let hB = try await openEstate(in: kit, owner: owner)
        let hA = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "scope-single-req"))

        // Two drawers; IDs are UUID strings by default.
        let dTarget = try await capture(into: hB, tag: "single-target", kit: kit)
        let dOther  = try await capture(into: hB, tag: "single-other",  kit: kit)

        // Parse the target drawer's String id back to UUID for the grant.
        let targetUUID = try #require(
            UUID(uuidString: dTarget.id),
            "drawer id must be a valid UUID string")

        _ = try await kit.issueGrant(
            hB, scopedGrantOptions(to: hA, scope: .singleRow(targetUUID)))

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dTarget.id),
            "singleRow scope must include the drawer whose id matches the granted UUID")
        #expect(!ids.contains(dOther.id),
            "singleRow scope must exclude all other drawers")
        #expect(ids.count == 1,
            "singleRow scope must return exactly one drawer")
    }

    // MARK: - 14. .wholeEstate scope passes all drawers (GRANT-SCOPE-P1)

    /// A grant with `.wholeEstate` scope is a pass-through: the scope filter
    /// applies no narrowing and all content-level-permitted drawers are
    /// returned. This is the regression guard for the pass-through branch.
    @Test
    func scopeWholeEstatePassesAll() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scope-whole")
        let hB = try await openEstate(in: kit, owner: owner)
        let hA = try await openEstate(in: kit, owner: OwnerCredentials(ownerIdentifier: "scope-whole-req"))

        let dA = try await capture(into: hB, tag: "whole-a", kit: kit)
        let dB = try await capture(into: hB, tag: "whole-b", kit: kit)

        // grantOptions defaults to .wholeEstate — pass-through scope.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        let ids = result.drawers.map(\.id)

        #expect(ids.contains(dA.id),
            "wholeEstate scope must return all drawers — regression guard for pass-through")
        #expect(ids.contains(dB.id),
            "wholeEstate scope must return all drawers — regression guard for pass-through")
    }

    // MARK: - CustodyMode enforcement (P0 Beta Blocker)

    // MARK: - 15. Mode 1 (mediated) — vault holds key, read succeeds

    /// A mode-1 (mediated) grant reads successfully when the vault holds
    /// the scope key. The vault is populated by `issueGrant`; the key is
    /// retained in memory for the duration of the estate's session.
    /// This test verifies that the custody gate passes for mode-1 when
    /// everything is in order (positive case).
    @Test
    func mediatedGrantVaultHoldsKeyAllowsRead() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-custody-mediated")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // Mode-1 (mediated) grant: the scope key is retained in the vault.
        _ = try await kit.issueGrant(hB, GrantOptions(
            granteeEstateID: hA.estateUUID,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent,
            contentLevel: 0
        ))
        let dB = try await capture(into: hB, tag: "mediated-key", kit: kit)

        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        #expect(result.drawers.map(\.id).contains(dB.id),
            "mode-1 (mediated) grant with vault key must allow federated read")
    }

    // MARK: - 16. Mode 2 (handedOver) — offline read succeeds within window

    /// A mode-2 (handedOver) grant allows reads within the grant window
    /// without a vault check. The key was handed to the recipient at issue;
    /// the source imposes no vault check. The expiry check (step 4) covers
    /// the grant window.
    @Test
    func handedOverGrantAllowsReadWithinWindow() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-custody-handedover")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let expiry = issuedAt.addingTimeInterval(3600)  // 1 hour window
        _ = try await kit.issueGrant(hB, GrantOptions(
            granteeEstateID: hA.estateUUID,
            scope: .wholeEstate,
            custodyMode: .handedOver,
            lifetime: .until(expiry),
            contentLevel: 0
        ), now: issuedAt)
        let dB = try await capture(into: hB, tag: "handedover-key", kit: kit)

        // Read within the window: no vault check required for mode 2.
        let result = try await kit.federatedRecall(
            unconfirmedFrame, from: hB, requestedBy: hA,
            now: issuedAt.addingTimeInterval(1800)
        )
        #expect(result.drawers.map(\.id).contains(dB.id),
            "mode-2 (handedOver) grant must allow read within the grant window")
    }

    // MARK: - InferenceRemainingBudget enforcement (P0 Beta Blocker)

    // MARK: - 18. Budget debits per read and persists across grant store queries

    /// Each `federatedRecall` call debits the authorizing grant's
    /// `inferenceRemainingBudget` by `GeniusLocusKit.budgetDebitPerRead` (0.01).
    /// The debit is persisted to the grants table so subsequent reads see the
    /// reduced budget. This test verifies both the debit amount and persistence.
    @Test
    func budgetDebitsPerReadAndPersists() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-budget-debit")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        let issued = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await capture(into: hB, tag: "budget-debit", kit: kit)

        // Read the budget before the first federated recall.
        let (storeBefore, _) = try await kit.ensureGrantSurface(for: hB)
        let budgetBefore = try await storeBefore.get(id: issued.grant.id)?
            .grant.inferenceRemainingBudget ?? 0.0
        #expect(budgetBefore == 1.0, "fresh grant must have budget 1.0")

        // Perform one federated recall.
        _ = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)

        // Re-read the stored budget; it must have decreased by budgetDebitPerRead.
        let (storeAfter, _) = try await kit.ensureGrantSurface(for: hB)
        let budgetAfter = try await storeAfter.get(id: issued.grant.id)?
            .grant.inferenceRemainingBudget ?? 0.0
        #expect(
            abs(budgetAfter - (1.0 - GeniusLocusKit.budgetDebitPerRead)) < 0.0001,
            "budget after one read must equal 1.0 - budgetDebitPerRead (\(GeniusLocusKit.budgetDebitPerRead)); got \(budgetAfter)"
        )
    }

    // MARK: - 19. Exhausted budget refuses with no content leak

    /// A grant whose `inferenceRemainingBudget` has reached zero refuses all
    /// further reads with `.budgetExhausted`. No drawer content is returned.
    /// This verifies the exhausted budget gate fires before the read executes.
    @Test
    func exhaustedBudgetRefusesWithNoContentLeak() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-budget-exhausted")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // Issue a grant and then manually set budget to 0.0 via the store
        // to simulate an exhausted grant without running 100 reads.
        let issued = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await capture(into: hB, tag: "budget-exhausted", kit: kit)

        let (store, _) = try await kit.ensureGrantSurface(for: hB)
        // Debit the full budget (1.0) to exhaust it.
        try await store.debitBudget(id: issued.grant.id, amount: 1.0)

        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        }
        if case .crossEstateReadRefused(_, _, let reason)? = thrown {
            #expect(reason == .budgetExhausted,
                "exhausted budget must refuse with .budgetExhausted")
        } else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
        }
    }

    // MARK: - 20. Budget debit is bounded: cannot go below zero

    /// Successive reads debit the budget by `budgetDebitPerRead` each time.
    /// The persisted budget never goes below 0.0 (the `max(0.0, …)` clamp in
    /// `GrantStore.debitBudget`). This test verifies the lower bound.
    @Test
    func budgetDebitClampsAtZero() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-budget-clamp")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        let issued = try await kit.issueGrant(hB, grantOptions(to: hA))

        // Debit more than the full budget (1.0) in one call.
        let (store, _) = try await kit.ensureGrantSurface(for: hB)
        try await store.debitBudget(id: issued.grant.id, amount: 5.0)

        let budgetAfter = try await store.get(id: issued.grant.id)?
            .grant.inferenceRemainingBudget ?? -999.0
        #expect(budgetAfter >= 0.0,
            "budget must not go below 0.0 after an over-debit; got \(budgetAfter)")
        #expect(budgetAfter == 0.0,
            "budget clamped at 0.0 after over-debit; got \(budgetAfter)")
    }
}
