import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

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
final class CrossEstateFederationTests: XCTestCase {

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
        lifetime: GrantLifetime = .permanent
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee.estateUUID,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: lifetime
        )
    }

    /// Recall with `.unconfirmed` so the default `.userConfirmed` prepend
    /// does not prune freshly-captured drawers (provenance == 0). This is
    /// the same frame the GLK-01 fan-out tests use for the same reason.
    private var unconfirmedFrame: RecallFrame {
        RecallFrame(filterChain: [.unconfirmed])
    }

    // MARK: - 1. Positive — valid grant yields the source's drawer

    func testValidGrantReturnsSourceDrawerAndAuthorizingGrant() async throws {
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

        XCTAssertTrue(result.drawers.map(\.id).contains(dB.id),
            "valid grant must return the source estate's captured drawer")
        XCTAssertEqual(result.grant.id, issued.grant.id,
            "result carries the authorizing grant as context")
        XCTAssertEqual(result.sourceHandle, hB)
        XCTAssertEqual(result.requesterHandle, hA)
    }

    // MARK: - 2. Negative — the A-versus-C refusal (I-23 §13)

    func testReadOfUngrantedEstateRefusesNoActiveGrant() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-avc")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)
        let hC = try await openEstate(in: kit, owner: owner)

        // B grants to A only; C grants nothing. C captures content.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await capture(into: hC, tag: "c", kit: kit)

        // A reading C is refused — A holds no grant from C.
        await XCTAssertThrowsErrorAsync(
            try await kit.federatedRecall(unconfirmedFrame, from: hC, requestedBy: hA)
        ) { error in
            guard case let GeniusLocusKitError.crossEstateReadRefused(source, requester, reason) = error else {
                return XCTFail("expected .crossEstateReadRefused, got \(error)")
            }
            XCTAssertEqual(source, hC.estateUUID)
            XCTAssertEqual(requester, hA.estateUUID)
            XCTAssertEqual(reason, .noActiveGrant,
                "no C-to-A grant exists — refusal reason is noActiveGrant")
        }
    }

    // MARK: - 3. Expiry — refuses after expiry, succeeds before

    func testExpiredGrantRefusesAfterExpirySucceedsBefore() async throws {
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
        XCTAssertTrue(before.drawers.map(\.id).contains(dB.id),
            "read before expiry returns the source's drawer")

        // After expiry: the read refuses with .grantExpired.
        await XCTAssertThrowsErrorAsync(
            try await kit.federatedRecall(
                unconfirmedFrame, from: hB, requestedBy: hA,
                now: expiry.addingTimeInterval(1)
            )
        ) { error in
            guard case let GeniusLocusKitError.crossEstateReadRefused(_, _, reason) = error else {
                return XCTFail("expected .crossEstateReadRefused, got \(error)")
            }
            XCTAssertEqual(reason, .grantExpired,
                "a matching grant exists but its lifetime elapsed")
        }
    }

    // MARK: - 4. Revocation — refuses after revoke

    func testRevokedGrantRefusesRead() async throws {
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
        await XCTAssertThrowsErrorAsync(
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        ) { error in
            guard case let GeniusLocusKitError.crossEstateReadRefused(_, _, reason) = error else {
                return XCTFail("expected .crossEstateReadRefused, got \(error)")
            }
            XCTAssertEqual(reason, .noActiveGrant,
                "revocation removes the grant from active() — refusal is noActiveGrant")
        }
    }

    // MARK: - 5. Isolation — only the source's rows, never the requester's

    func testFederatedReadReturnsOnlySourceRows() async throws {
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
        XCTAssertTrue(ids.contains(dB.id),
            "result contains the source estate's row")
        XCTAssertFalse(ids.contains(dA.id),
            "result must never contain the requester's own row (storage isolation)")
    }

    // MARK: - 6. Stale handle — fail-closed on a closed estate

    func testStaleSourceHandleThrowsEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fed-stale")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)
        try await kit.close(hB)  // hB is now stale

        await XCTAssertThrowsErrorAsync(
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        ) { error in
            guard case let GeniusLocusKitError.estateNotOpen(uuid) = error else {
                return XCTFail("expected .estateNotOpen, got \(error)")
            }
            XCTAssertEqual(uuid, hB.estateUUID)
        }
    }
}
