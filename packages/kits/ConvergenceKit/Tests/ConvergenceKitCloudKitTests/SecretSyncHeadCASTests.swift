import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit scope-head CAS")
struct SecretSyncHeadCASTests {
    @Test("only a validator-produced precondition advances the head")
    func validatedPreconditionAdvances() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)

        let result = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(fixture, expected: nil)
        )

        #expect(result == .advanced(try #require(await store.policyHead(for: fixture.entry.commit.scopeID))))
        #expect(await database.savedHeadCount == 1)
        #expect(await database.headCASAttemptCount == 1)
    }

    @Test("head never advances when the staged graph is incomplete")
    func incompleteCandidateCannotAdvance() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)
        await database.removeRecord(
            digest: fixture.entry.records.sealedPayload.recordDigest,
            type: .sealedPayload
        )

        await #expect(throws: SecretSyncCloudKitPolicyStoreError.self) {
            try await store.compareAndAdvance(
                U5PolicyFixture.precondition(fixture, expected: nil)
            )
        }
        #expect(await database.savedHeadCount == 0)
        #expect(await database.headCASAttemptCount == 0)
    }

    @Test("stale change-tag conflict refetches reconstructs and retries once")
    func staleTagRetriesAfterExactReconstruction() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let second = try U5PolicyFixture.make(previous: first, generationByte: 0x32)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(first.entry)
        _ = try await store.compareAndAdvance(U5PolicyFixture.precondition(first, expected: nil))
        try await store.appendStagedPolicy(second.entry)
        await database.setFailNextHeadCAS(true)

        let result = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(second, expected: first)
        )

        #expect(result == .advanced(try #require(await store.policyHead(for: first.entry.commit.scopeID))))
        let attemptCount = await database.headCASAttemptCount
        #expect(attemptCount == 3)
        #expect(await database.observedDetachedHeadCandidate)
        #expect(await database.observedPreservedHeadChangeTag)
    }

    @Test("policy store cannot split graph reads and head writes across databases")
    func storeOwnsOneDatabaseBoundary() async throws {
        let fixture = try U5PolicyFixture.make()
        let graphDatabase = U5ScriptedDatabase()
        let unrelatedDatabase = U5ScriptedDatabase()
        let unrelatedHead = try SecretSyncCloudKitScopeHead(
            scopeID: fixture.entry.commit.scopeID,
            policyEpoch: 1,
            headCommitDigest: try SecretRecordDigest(
                bytes: Data(repeating: 0xE1, count: 32)
            ),
            policyDigest: try SecretRecordDigest(
                bytes: Data(repeating: 0xE2, count: 32)
            )
        )
        try await unrelatedDatabase.replaceHead(unrelatedHead)
        let store = SecretSyncCloudKitPolicyStore(
            database: graphDatabase,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)

        _ = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(fixture, expected: nil)
        )

        #expect(
            try await store.policyHead(for: fixture.entry.commit.scopeID)
                == U5PolicyFixture.precondition(fixture, expected: nil)
                    .candidateHead
        )
        let unrelated = try await SecretSyncHeadCAS(
            database: unrelatedDatabase,
            digester: U5PolicyFixture.digester
        ).currentHead(for: fixture.entry.commit.scopeID)
        #expect(unrelated?.commitDigest == unrelatedHead.headCommitDigest)
    }

    @Test("concurrent epoch children produce one winner and one fork")
    func concurrentChildrenDoNotMerge() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let childA = try U5PolicyFixture.make(previous: first, generationByte: 0x32)
        let childB = try U5PolicyFixture.make(previous: first, generationByte: 0x33)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        for fixture in [first, childA, childB] {
            try await store.appendStagedPolicy(fixture.entry)
        }
        _ = try await store.compareAndAdvance(U5PolicyFixture.precondition(first, expected: nil))

        async let resultA = store.compareAndAdvance(
            U5PolicyFixture.precondition(childA, expected: first)
        )
        async let resultB = store.compareAndAdvance(
            U5PolicyFixture.precondition(childB, expected: first)
        )
        let results = try await [resultA, resultB]

        #expect(results.filter { if case .advanced = $0 { true } else { false } }.count == 1)
        #expect(results.filter { if case .forkDetected = $0 { true } else { false } }.count == 1)
        #expect(await database.savedHeadCount == 1)
    }

    @Test("restart reconstructs committed policy from the authoritative head")
    func restartUsesHeadNotCache() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        var store: SecretSyncCloudKitPolicyStore? = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store?.appendStagedPolicy(fixture.entry)
        _ = try await store?.compareAndAdvance(U5PolicyFixture.precondition(fixture, expected: nil))
        store = nil

        let restarted = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        let committed = try await restarted.committedPolicy(
            for: fixture.entry.commit.scopeID,
            epoch: 1
        )

        let reconstructed = try #require(committed)
        #expect(reconstructed.commit == fixture.entry.commit)
        #expect(reconstructed.records.state == .committed)
        #expect(reconstructed.records.signedPolicy == fixture.entry.records.signedPolicy)
        #expect(reconstructed.records.sealedPayload == fixture.entry.records.sealedPayload)
        #expect(reconstructed.records.recipientEnvelopes == fixture.entry.records.recipientEnvelopes)
        #expect(reconstructed.records.recoveryEnvelope == fixture.entry.records.recoveryEnvelope)
        #expect(reconstructed.trustRecords == fixture.entry.trustRecords)
    }

    @Test("committed chain rejects invalid predecessor authority bindings")
    func predecessorAuthorityBindingsReject() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let second = try U5PolicyFixture.make(
            previous: first,
            generationByte: 0x32
        )
        let invalidEntries = try [
            U5PolicyFixture.entryWithWrongPredecessorPolicy(second),
            U5PolicyFixture.entryReusingGeneration(
                second,
                predecessor: first
            ),
            U5PolicyFixture.entryWithExtraPurgeTarget(
                second,
                predecessor: first
            ),
        ]
        for invalid in invalidEntries {
            let database = U5ScriptedDatabase()
            let store = SecretSyncCloudKitPolicyStore(
                database: database,
                digester: U5PolicyFixture.digester
            )
            try await store.appendStagedPolicy(first.entry)
            try await store.appendStagedPolicy(invalid)
            try await database.replaceHead(
                SecretSyncCloudKitScopeHead(
                    scopeID: invalid.commit.scopeID,
                    policyEpoch: invalid.commit.policyEpoch,
                    headCommitDigest: invalid.commit.recordDigest,
                    policyDigest: invalid.commit.policyDigest
                )
            )

            await #expect(
                throws: SecretSyncCloudKitPolicyStoreError.referenceMismatch
            ) {
                _ = try await store.committedPolicy(
                    for: invalid.commit.scopeID,
                    epoch: invalid.commit.policyEpoch
                )
            }
        }
    }

    @Test("malformed maximum predecessor epoch rejects without trapping")
    func maximumPredecessorEpochRejects() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let second = try U5PolicyFixture.make(
            previous: first,
            generationByte: 0x32
        )
        let chain = try U5PolicyFixture.overflowPredecessorChain(second)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(chain.predecessor)
        try await store.appendStagedPolicy(chain.child)
        try await database.replaceHead(
            SecretSyncCloudKitScopeHead(
                scopeID: chain.child.commit.scopeID,
                policyEpoch: chain.child.commit.policyEpoch,
                headCommitDigest: chain.child.commit.recordDigest,
                policyDigest: chain.child.commit.policyDigest
            )
        )

        await #expect(
            throws: SecretSyncCloudKitPolicyStoreError.referenceMismatch
        ) {
            _ = try await store.committedPolicy(
                for: chain.child.commit.scopeID,
                epoch: chain.child.commit.policyEpoch
            )
        }
    }

    @Test("genesis rejects purge evidence without a superseded generation")
    func genesisPurgeRejects() async throws {
        let fixture = try U5PolicyFixture.make()
        let invalid = try U5PolicyFixture.entryWithExtraPurgeTarget(
            fixture,
            predecessor: fixture
        )
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(invalid)
        try await database.replaceHead(
            SecretSyncCloudKitScopeHead(
                scopeID: invalid.commit.scopeID,
                policyEpoch: 1,
                headCommitDigest: invalid.commit.recordDigest,
                policyDigest: invalid.commit.policyDigest
            )
        )

        await #expect(
            throws: SecretSyncCloudKitPolicyStoreError.referenceMismatch
        ) {
            _ = try await store.committedPolicy(
                for: invalid.commit.scopeID,
                epoch: 1
            )
        }
    }
}
