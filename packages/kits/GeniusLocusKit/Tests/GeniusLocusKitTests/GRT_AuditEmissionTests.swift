import Testing
import SubstrateTypes
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// FUP-C — Grant lifecycle audit emission.
///
/// GLK-03 declared the `.grantIssued` / `.grantRevoked` audit verbs but
/// GRT-01 never emitted them, leaving a dead audit seam: an estate that
/// issued and revoked grants showed no grant lifecycle in its unified
/// audit chain (AUDIT-01 Zone D / FUP-1). These tests assert the seam is
/// wired — issuing or revoking a grant writes the corresponding
/// `UnifiedAuditEntry` into `auditLogs[handle]`, carrying the grant id in
/// `rowID` and the custody-mode token in `fieldPath`, and the chain still
/// verifies after both. They are the regression guard that should have
/// caught the dead seam.
///
/// The harness mirrors `GRT01_GrantTests`: one estate opened through
/// `GeniusLocusKit`, grants issued/revoked through the unified verb
/// surface, `now` passed explicitly so emission HLCs are deterministic.
@Suite("Grant lifecycle audit emission")
struct GRT_AuditEmissionTests {

    // MARK: - Harness

    /// Fresh isolated in-memory storage for one estate.
    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    /// Open one estate through `GeniusLocusKit` over fresh storage.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fupc")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// A whole-estate mediated grant options value.
    private func options(grantee: UUID = UUID()) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent
        )
    }

    /// Issue instant chosen so the derived HLC physical time is a clean,
    /// nonzero millisecond value; revoke a second later so the two
    /// entries order monotonically.
    private let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. issueGrant emits a .grantIssued entry

    @Test
    func issueGrantEmitsGrantIssuedAuditEntry() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(), now: issuedAt)

        let log = try await kit.auditLog(for: handle)
        let issuedEntries = log.orderedEntries.filter { $0.verb == .grantIssued }
        #expect(issuedEntries.count == 1, "exactly one .grantIssued entry after a single issue")

        let entry = try #require(issuedEntries.first)
        #expect(entry.rowID == result.grant.id, "grant id is carried in the entry's rowID")
        #expect(
            entry.fieldPath == result.grant.custodyMode.signingToken,
            "custody-mode token is carried in the entry's fieldPath"
        )
    }

    // MARK: - 2. revokeGrant emits a .grantRevoked entry

    @Test
    func revokeGrantEmitsGrantRevokedAuditEntry() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(), now: issuedAt)
        try await kit.revokeGrant(handle, grantID: result.grant.id, now: issuedAt.addingTimeInterval(1))

        let log = try await kit.auditLog(for: handle)
        let revokedEntries = log.orderedEntries.filter { $0.verb == .grantRevoked }
        #expect(revokedEntries.count == 1, "exactly one .grantRevoked entry after a single revoke")

        let entry = try #require(revokedEntries.first)
        #expect(entry.rowID == result.grant.id, "grant id is carried in the revoke entry's rowID")
        #expect(
            entry.fieldPath == result.grant.custodyMode.signingToken,
            "custody-mode token is carried in the revoke entry's fieldPath"
        )
    }

    // MARK: - 3. The chain still verifies across issue and revoke

    @Test
    func auditChainValidAfterIssueAndRevoke() async throws {
        let (kit, handle) = try await openOneEstate()
        let result = try await kit.issueGrant(handle, options(), now: issuedAt)

        // Valid immediately after issue.
        let afterIssue = try await kit.verifyAuditChain(handle)
        #expect(afterIssue.valid, "chain is valid after issuing a grant")
        #expect(afterIssue.firstBrokenAt == nil, "no broken entry after issue")

        try await kit.revokeGrant(handle, grantID: result.grant.id, now: issuedAt.addingTimeInterval(1))

        // Still valid after revoke, and both lifecycle entries are present.
        let afterRevoke = try await kit.verifyAuditChain(handle)
        #expect(afterRevoke.valid, "chain is valid after revoking a grant")
        #expect(afterRevoke.firstBrokenAt == nil, "no broken entry after revoke")

        let log = try await kit.auditLog(for: handle)
        let lifecycleVerbs = log.orderedEntries.map(\.verb).filter {
            $0 == .grantIssued || $0 == .grantRevoked
        }
        #expect(
            lifecycleVerbs == [.grantIssued, .grantRevoked],
            "the chain carries the grant lifecycle in issue-then-revoke order"
        )
    }
}
