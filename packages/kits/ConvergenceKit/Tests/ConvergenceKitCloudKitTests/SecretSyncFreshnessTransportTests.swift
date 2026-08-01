import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit freshness transport")
struct SecretSyncFreshnessTransportTests {
    @Test("protected-local authority returns only the exact protected floor")
    func protectedLocalIsTheNormalFloor() async throws {
        let first = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(first.entry)
        _ = try await store.compareAndAdvance(U5PolicyFixture.precondition(first, expected: nil))
        let protected = U5ProtectedHeadProvider(commitment: try U5PolicyFixture.commitment(first))
        let transport = SecretSyncFreshnessTransport(database: database)

        let result = try await transport.normalPathCommitment(
            for: first.entry.commit.scopeID,
            authority: .protectedLocal(protected)
        )

        let expected = try U5PolicyFixture.commitment(first)
        #expect(result == expected)
    }

    @Test("protected-local authority remains usable during transport outage")
    func protectedLocalWorksOffline() async throws {
        let fixture = try U5PolicyFixture.make()
        let expected = try U5PolicyFixture.commitment(fixture)
        let database = U5ScriptedDatabase()
        await database.setFailNextFetchTransport(true)
        let transport = SecretSyncFreshnessTransport(database: database)

        let result = try await transport.normalPathCommitment(
            for: fixture.entry.commit.scopeID,
            authority: .protectedLocal(
                U5ProtectedHeadProvider(commitment: expected)
            )
        )

        #expect(result == expected)
    }

    @Test("missing or same-epoch mismatched CloudKit head blocks protected restore")
    func protectedRestoreMismatchFailsClosed() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let protected = U5ProtectedHeadProvider(commitment: try U5PolicyFixture.commitment(fixture))
        let transport = SecretSyncFreshnessTransport(database: database)

        await #expect(throws: SecretSyncFreshnessTransportError.rollbackOrRestoreMismatch) {
            _ = try await transport.normalPathCommitment(
                for: fixture.entry.commit.scopeID,
                authority: .protectedLocal(protected)
            )
        }

        try await database.replaceHead(
            SecretSyncCloudKitScopeHead(
                scopeID: fixture.entry.commit.scopeID,
                policyEpoch: 1,
                headCommitDigest: try SecretRecordDigest(bytes: Data(repeating: 0xEE, count: 32)),
                policyDigest: fixture.entry.commit.policyDigest
            )
        )
        await #expect(throws: SecretSyncFreshnessTransportError.forkDetected) {
            _ = try await transport.normalPathCommitment(
                for: fixture.entry.commit.scopeID,
                authority: .protectedLocal(protected)
            )
        }
    }

    @Test("lower CloudKit floor blocks protected restore and peer remains pending")
    func lowerEpochClassification() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let second = try U5PolicyFixture.make(
            previous: first,
            generationByte: 0x32
        )
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(first.entry)
        _ = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(first, expected: nil)
        )
        let transport = SecretSyncFreshnessTransport(database: database)
        let newer = try U5PolicyFixture.commitment(second)

        await #expect(
            throws: SecretSyncFreshnessTransportError
                .rollbackOrRestoreMismatch
        ) {
            _ = try await transport.normalPathCommitment(
                for: first.entry.commit.scopeID,
                authority: .protectedLocal(
                    U5ProtectedHeadProvider(commitment: newer)
                )
            )
        }
        await #expect(
            throws: SecretSyncFreshnessTransportError.catchUpIncomplete
        ) {
            _ = try await transport.normalPathCommitment(
                for: first.entry.commit.scopeID,
                authority: .authenticatedTrustedPeer(
                    U5PeerAnchor(commitment: newer)
                )
            )
        }
    }

    @Test("authenticated trusted-peer commitment must match CloudKit exactly")
    func trustedPeerCatchesUpExactly() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)
        _ = try await store.compareAndAdvance(U5PolicyFixture.precondition(fixture, expected: nil))
        let expected = try U5PolicyFixture.commitment(fixture)
        let transport = SecretSyncFreshnessTransport(database: database)

        let exact = try await transport.normalPathCommitment(
            for: fixture.entry.commit.scopeID,
            authority: .authenticatedTrustedPeer(U5PeerAnchor(commitment: expected))
        )
        #expect(exact == expected)

        let fork = try SecretBootstrapFreshnessCommitment(
            scopeID: expected.scopeID,
            latestPolicyEpoch: expected.latestPolicyEpoch,
            headCommitDigest: try SecretRecordDigest(bytes: Data(repeating: 0xEF, count: 32)),
            policyDigest: expected.policyDigest
        )
        await #expect(throws: SecretSyncFreshnessTransportError.forkDetected) {
            _ = try await transport.normalPathCommitment(
                for: fixture.entry.commit.scopeID,
                authority: .authenticatedTrustedPeer(U5PeerAnchor(commitment: fork))
            )
        }

        await database.removeHead(scopeID: fixture.entry.commit.scopeID)
        await #expect(throws: SecretSyncFreshnessTransportError.catchUpIncomplete) {
            _ = try await transport.normalPathCommitment(
                for: fixture.entry.commit.scopeID,
                authority: .authenticatedTrustedPeer(
                    U5PeerAnchor(commitment: expected)
                )
            )
        }
    }

    @Test("CloudKit recovery candidate is explicitly non-authoritative")
    func recoveryCandidateDoesNotAuthorize() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)
        _ = try await store.compareAndAdvance(U5PolicyFixture.precondition(fixture, expected: nil))
        let transport = SecretSyncFreshnessTransport(database: database)

        let candidate = try await transport.recoveryTransportCandidate(
            for: fixture.entry.commit.scopeID
        )

        #expect(candidate.authorizesRecovery == false)
        let expected = try U5PolicyFixture.commitment(fixture)
        #expect(candidate.commitment == expected)
    }

    @Test("normal publication never samples the recovery authority clock")
    func normalPublicationDoesNotReadRecoveryClock() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let clock = U6ClockProbe(0)
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester,
            recoveryTimeSource: { clock.read() }
        )
        try await store.appendStagedPolicy(fixture.entry)

        _ = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(fixture, expected: nil)
        )

        #expect(clock.readCount == 0)
    }

    @Test("SecretSync zone cursors never grant freshness")
    func tokensAreTransportOnly() {
        #expect(SecretSyncCloudKitTransportTokens.presenceGrantsFreshness == false)
        #expect(Set(SecretSyncCloudKitTransportTokens.zoneNames) == [
            SecretSyncCloudKitZones.controlZoneName,
            SecretSyncCloudKitZones.payloadZoneName,
        ])
    }
}

private struct U5ProtectedHeadProvider: SecretSyncProtectedHeadProviding {
    let commitment: SecretBootstrapFreshnessCommitment

    func protectedHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment {
        guard scopeID == commitment.scopeID else {
            throw SecretSyncFreshnessTransportError.rollbackOrRestoreMismatch
        }
        return commitment
    }
}

private struct U5PeerAnchor: ExternalBootstrapFreshnessAnchor {
    let commitment: SecretBootstrapFreshnessCommitment

    func latestCommitment(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment {
        guard scopeID == commitment.scopeID else {
            throw SecretSyncFreshnessTransportError.forkDetected
        }
        return commitment
    }
}
