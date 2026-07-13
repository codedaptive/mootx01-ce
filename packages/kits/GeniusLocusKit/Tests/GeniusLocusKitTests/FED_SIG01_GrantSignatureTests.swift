import Testing
import Foundation
import CryptoKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit
@testable import LocusKit

/// FED-SIG-01 — Grant signature verification at the `federatedRecall` boundary.
///
/// D9 hardening (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Delta 6):
/// `federatedRecall` verifies each candidate grant's Ed25519 signature
/// against the GRANTER's registered identity public key before any recall
/// is performed. Trust derives from the estate registry (the key loaded at
/// `Estate.open`), not from any field in the grant blob — the same
/// registered-key trust anchor as the F-3 `pull()` hardening in
/// ConvergenceKit `FederationSyncEngine`.
///
/// Three coverage points:
///
///   (a) A grant carrying a forged (non-empty, invalid) signature is
///       rejected with `.crossEstateReadRefused(reason: .invalidGrantSignature)`.
///
///   (b) A grant issued through the normal `issueGrant` path (signed by the
///       granter's identity key) recalls successfully — the positive path.
///
///   (c) A grant carrying an empty signature (legacy pre-signing behaviour)
///       is allowed on the local in-process path (I-13 invariant — no
///       network crossing, both estates open in the same kit instance) with
///       a logged warning. This is the D9 migration posture.
///
/// All estates are fresh in-memory instances in one kit. `now` is passed
/// explicitly where it matters so the tests are deterministic.
@Suite("FED-SIG-01 grant signature verification")
struct FED_SIG01_GrantSignatureTests {

    // MARK: - Harness

    /// Open a fresh isolated in-memory estate through `GeniusLocusKit`.
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

    /// Recall frame that admits unconfirmed drawers (avoids the default
    /// `.userConfirmed` prepend pruning freshly-captured rows).
    private var unconfirmedFrame: RecallFrame {
        RecallFrame(filterChain: [.unconfirmed])
    }

    /// Build a grant with the given signature bytes for direct insertion
    /// into the grant store, bypassing the signing path. Uses `.handedOver`
    /// custody mode (mode 2) so the recall path does not require a scope-key
    /// vault entry — isolation lets the signature check be the only gate.
    private func directGrant(
        granteeEstateID: UUID,
        signature: Data
    ) -> Grant {
        Grant(
            id: UUID(),
            granteeEstateID: granteeEstateID,
            scope: .wholeEstate,
            contentLevel: 0,
            lifetime: .permanent,
            custodyMode: .handedOver,
            reSharePermission: .none,
            inferenceRemainingBudget: 1.0,
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            signature: signature
        )
    }

    // MARK: - (a) Forged signature → invalidGrantSignature

    @Test
    func forgedSignatureIsRejectedAtFederatedRecallBoundary() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sig-forged")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // Initialize the grant surface (store + vault) for hB.
        // ensureGrantSurface is the internal lazy-init path; calling it directly
        // avoids the need to issue a real grant just to seed the store.
        let (store, _) = try await kit.ensureGrantSurface(for: hB)

        // Insert a grant with a forged 64-byte signature (non-empty but not a
        // valid Ed25519 signature over hB's canonical payload). 64 zero bytes
        // are an invalid Ed25519 signature over any payload.
        let forgedSig = Data(repeating: 0x00, count: 64)
        let tampered = directGrant(granteeEstateID: hA.estateUUID, signature: forgedSig)
        try await store.insert(tampered)

        // federatedRecall must reject the grant at step 4.5 — the signature
        // fails verification against hB's registered identity key.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        }
        guard case .crossEstateReadRefused(let source, let requester, let reason)? = thrown else {
            Issue.record("expected .crossEstateReadRefused, got \(String(describing: thrown))")
            return
        }
        #expect(source == hB.estateUUID,
            "refusal must name the source estate (the granter)")
        #expect(requester == hA.estateUUID,
            "refusal must name the requester estate (the grantee)")
        #expect(reason == .invalidGrantSignature,
            "a non-empty signature that fails Ed25519 verification is refused as .invalidGrantSignature")
    }

    // MARK: - (b) Correctly-signed grant → success

    @Test
    func correctlySignedGrantRecallsSuccessfully() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sig-valid")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // Issue through the normal path: VerbSurface.issueGrant signs the
        // grant with hB's identity key. This is the positive D9 path.
        _ = try await kit.issueGrant(hB, GrantOptions(
            granteeEstateID: hA.estateUUID,
            scope: .wholeEstate,
            custodyMode: .handedOver,
            lifetime: .permanent,
            contentLevel: 0
        ))

        // federatedRecall must succeed — the grant's signature verifies
        // against hB's registered identity public key.
        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        #expect(result.sourceHandle == hB,
            "successful recall names the correct source estate")
        #expect(result.requesterHandle == hA,
            "successful recall names the correct requester estate")
        // Result carries the authorizing grant, which must have a non-empty
        // signature (issueGrant always signs).
        #expect(!result.grant.signature.isEmpty,
            "the authorizing grant carries the granter's Ed25519 signature")
    }

    // MARK: - (c) Empty (legacy) signature → allowed with warning on local path

    @Test
    func emptySignatureAllowedOnLocalInProcessPath() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sig-legacy")
        let hA = try await openEstate(in: kit, owner: owner)
        let hB = try await openEstate(in: kit, owner: owner)

        // Initialize the grant surface (store + vault) for hB, then insert
        // a grant with an empty signature — the legacy posture for grants issued
        // before the Ed25519 signing scheme was introduced. D9 migration posture:
        // allowed on the local I-13 path with a logged warning (no cross-estate
        // exposure on a purely local read).
        let (store, _) = try await kit.ensureGrantSurface(for: hB)
        let unsignedGrant = directGrant(
            granteeEstateID: hA.estateUUID,
            signature: Data()   // empty — pre-signing legacy grant
        )
        try await store.insert(unsignedGrant)

        // federatedRecall must succeed — empty signature is the legacy posture,
        // allowed with a logged warning on the local in-process path (I-13).
        // No error should be thrown.
        let result = try await kit.federatedRecall(unconfirmedFrame, from: hB, requestedBy: hA)
        #expect(result.sourceHandle == hB,
            "legacy unsigned grant: recall must succeed on local I-13 path")
        #expect(result.requesterHandle == hA,
            "legacy unsigned grant: requester handle is correct")
        #expect(result.grant.signature.isEmpty,
            "legacy unsigned grant: the authorizing grant carries no signature")
    }
}
