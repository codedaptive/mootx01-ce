import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit scope-head CAS")
struct SecretSyncHeadCASTests {
    @Test("recovery at the exact signed expiry issues no head write")
    func recoveryExactExpiryRejectsBeforeCAS() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 2_000)

        await #expect(
            throws: SecretSyncHeadCASError.recoveryAuthorizationExpired
        ) {
            _ = try await harness.store.compareAndAdvance(
                harness.fixture.precondition
            )
        }

        #expect(
            await harness.database.headCASAttemptCount
                == harness.attemptsBeforeRecovery
        )
        #expect(
            try await harness.store.policyHead(
                for: harness.fixture.entry.commit.scopeID
            ) == harness.fixture.precondition.expectedHead
        )

        let later = try await U6RecoveryCASHarness.make(now: 2_001)
        await #expect(
            throws: SecretSyncHeadCASError.recoveryAuthorizationExpired
        ) {
            _ = try await later.store.compareAndAdvance(
                later.fixture.precondition
            )
        }
        #expect(
            await later.database.headCASAttemptCount
                == later.attemptsBeforeRecovery
        )
    }

    @Test("recovery accepts issuedAt and rejects authority time before it")
    func recoveryHalfOpenLowerBoundIsExact() async throws {
        let valid = try await U6RecoveryCASHarness.make(now: 1_000)
        #expect(
            try await valid.store.compareAndAdvance(
                valid.fixture.precondition
            ) == .advanced(valid.fixture.precondition.candidateHead)
        )
        #expect(
            await valid.database.headCASAttemptCount
                == valid.attemptsBeforeRecovery + 1
        )

        let early = try await U6RecoveryCASHarness.make(now: 999)
        await #expect(
            throws: SecretSyncHeadCASError.recoveryAuthorizationNotYetValid
        ) {
            _ = try await early.store.compareAndAdvance(
                early.fixture.precondition
            )
        }
        #expect(
            await early.database.headCASAttemptCount
                == early.attemptsBeforeRecovery
        )
    }

    @Test("recovery capability binds the exact authorization and candidate")
    func recoveryCapabilityBindsSignedWindowAndCandidate() throws {
        let fixture = try U6RecoveryPolicyFixture.make()
        let capability = try #require(
            fixture.precondition.recoveryPublicationCapability
        )
        let authorization = try #require(
            fixture.entry.records.recoveryAuthorization
        )

        #expect(capability.recoveryAuthorizationDigest == authorization.recordDigest)
        #expect(capability.scopeID == fixture.precondition.candidateHead.scopeID)
        #expect(
            capability.candidateCommitDigest
                == fixture.precondition.candidateHead.commitDigest
        )
        #expect(capability.requestID == authorization.intent.challenge.requestID)
        #expect(capability.sessionID == authorization.intent.challenge.sessionID)
        #expect(capability.issuedAtMilliseconds == 1_000)
        #expect(capability.expiresAtMilliseconds == 2_000)
        #expect(
            capability.matches(
                authorization: authorization,
                candidateHead: fixture.precondition.candidateHead
            )
        )
    }

    @Test("cancellation during the awaited head fetch prevents issuance")
    func cancellationBeforeFinalBoundaryPreventsCAS() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 1_500)
        await harness.database.suspendNextHeadFetch(
            scopeID: harness.fixture.entry.commit.scopeID
        )

        let publication = Task {
            try await harness.store.compareAndAdvance(
                harness.fixture.precondition
            )
        }
        await harness.database.waitForHeadFetchSuspension()
        #expect(
            await harness.store.cancelRecoveryAdvance(
                harness.fixture.precondition
            ) == .cancelled
        )
        await harness.database.resumeHeadFetch()

        await #expect(
            throws: SecretSyncHeadCASError.recoveryPublicationCancelled
        ) {
            _ = try await publication.value
        }
        #expect(
            await harness.database.headCASAttemptCount
                == harness.attemptsBeforeRecovery
        )
    }

    @Test("cancellation after issuance reports too late")
    func cancellationAfterIssuanceIsTruthful() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 1_500)
        await harness.database.setSuspendNextHeadCAS(true)

        async let publication = harness.store.compareAndAdvance(
            harness.fixture.precondition
        )
        await harness.database.waitForHeadCASSuspension()
        #expect(
            await harness.store.cancelRecoveryAdvance(
                harness.fixture.precondition
            ) == .tooLate
        )
        await harness.database.resumeHeadCAS()

        #expect(
            try await publication
                == .advanced(harness.fixture.precondition.candidateHead)
        )
        #expect(
            await harness.database.headCASAttemptCount
                == harness.attemptsBeforeRecovery + 1
        )
    }

    @Test("copied capability cannot issue a second in-flight CAS")
    func copiedCapabilityIsOneShot() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 1_500)
        await harness.database.setSuspendNextHeadCAS(true)

        async let first = harness.store.compareAndAdvance(
            harness.fixture.precondition
        )
        await harness.database.waitForHeadCASSuspension()
        await #expect(
            throws: SecretSyncHeadCASError.recoveryCapabilityConsumed
        ) {
            _ = try await harness.store.compareAndAdvance(
                harness.fixture.precondition
            )
        }
        await harness.database.resumeHeadCAS()

        #expect(
            try await first
                == .advanced(harness.fixture.precondition.candidateHead)
        )
        #expect(
            await harness.database.headCASAttemptCount
                == harness.attemptsBeforeRecovery + 1
        )
    }

    @Test("recovery conflict terminates without a second CAS")
    func recoveryConflictDoesNotRetry() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 1_500)
        await harness.database.setFailNextHeadCAS(true)

        await #expect(
            throws: SecretSyncCloudKitPolicyStoreError
                .conditionalWriteConflict
        ) {
            _ = try await harness.store.compareAndAdvance(
                harness.fixture.precondition
            )
        }

        #expect(
            await harness.database.headCASAttemptCount
                == harness.attemptsBeforeRecovery + 1
        )
    }

    @Test("transport ambiguity succeeds only for the exact candidate head")
    func recoveryAmbiguityClassifiesExactCandidateOnly() async throws {
        let accepted = try await U6RecoveryCASHarness.make(now: 1_500)
        await accepted.database.setFailNextHeadCASAmbiguouslyAfterSave(true)
        #expect(
            try await accepted.store.compareAndAdvance(
                accepted.fixture.precondition
            ) == .advanced(accepted.fixture.precondition.candidateHead)
        )
        #expect(
            await accepted.database.headCASAttemptCount
                == accepted.attemptsBeforeRecovery + 1
        )

        let rejected = try await U6RecoveryCASHarness.make(now: 1_500)
        await rejected.database.setFailNextHeadCASTransportBeforeSave(true)
        await #expect(throws: SecretSyncHeadCASError.transportFailure) {
            _ = try await rejected.store.compareAndAdvance(
                rejected.fixture.precondition
            )
        }
        await #expect(
            throws: SecretSyncHeadCASError.recoveryCapabilityConsumed
        ) {
            _ = try await rejected.store.compareAndAdvance(
                rejected.fixture.precondition
            )
        }
        #expect(
            await rejected.database.headCASAttemptCount
                == rejected.attemptsBeforeRecovery + 1
        )
    }

    @Test("restart loses local ledgers but signed expiry remains authoritative")
    func restartReliesOnSignedWindowNotLocalConsumption() async throws {
        let harness = try await U6RecoveryCASHarness.make(now: 1_500)
        await harness.database.setFailNextHeadCASTransportBeforeSave(true)
        await #expect(throws: SecretSyncHeadCASError.transportFailure) {
            _ = try await harness.store.compareAndAdvance(
                harness.fixture.precondition
            )
        }
        let attemptsAfterIssuedFailure = await harness.database
            .headCASAttemptCount

        // A new store intentionally has no process-local consumption state.
        // The signed window under its independently fixed authority clock is
        // the cross-restart control and rejects before another write.
        let restarted = SecretSyncCloudKitPolicyStore(
            database: harness.database,
            digester: U5PolicyFixture.digester,
            recoveryTimeSource: { 2_000 }
        )
        await #expect(
            throws: SecretSyncHeadCASError.recoveryAuthorizationExpired
        ) {
            _ = try await restarted.compareAndAdvance(
                harness.fixture.precondition
            )
        }
        #expect(
            await harness.database.headCASAttemptCount
                == attemptsAfterIssuedFailure
        )
    }

    @Test("competing recovery children commit at most one child")
    func competingRecoveryChildrenCommitOneChild() async throws {
        let first = try U6RecoveryPolicyFixture.make(
            candidateGenerationByte: 0x62
        )
        let second = try U6RecoveryPolicyFixture.make(
            candidateGenerationByte: 0x63
        )
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester,
            recoveryTimeSource: { 1_500 }
        )
        try await store.appendStagedPolicy(first.current.entry)
        _ = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(first.current, expected: nil)
        )
        try await store.appendStagedPolicy(first.entry)
        try await store.appendStagedPolicy(second.entry)
        let attemptsBeforeRecovery = await database.headCASAttemptCount

        async let resultA = store.compareAndAdvance(first.precondition)
        async let resultB = store.compareAndAdvance(second.precondition)
        let results = try await [resultA, resultB]

        #expect(
            results.filter {
                if case .advanced = $0 { return true }
                return false
            }.count == 1
        )
        #expect(
            results.filter {
                if case .forkDetected = $0 { return true }
                return false
            }.count == 1
        )
        let recoveryAttempts = await database.headCASAttemptCount
            - attemptsBeforeRecovery
        // Both separately authorized children may reach CloudKit before the
        // first response returns. Conditional CAS still permits exactly one
        // committed child, and neither capability is reissued.
        #expect((1...2).contains(recoveryAttempts))
        let head = try #require(
            try await store.policyHead(for: first.entry.commit.scopeID)
        )
        #expect([
            first.precondition.candidateHead,
            second.precondition.candidateHead,
        ].contains(head))
    }

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

    @Test("restart reconstructs the head-referenced policy from durable state")
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
        let hydrated = try await restarted.unvalidatedHeadPolicy(
            for: fixture.entry.commit.scopeID,
            epoch: 1
        )

        // Hydration after restart still works — the graph comes back from the
        // durable head, not from any in-process cache. What changed is the
        // label: the store reports what it proved, and it did not prove
        // authority.
        let reconstructed = try #require(hydrated)
        #expect(reconstructed.commit == fixture.entry.commit)
        #expect(reconstructed.records.state == .staged)
        #expect(reconstructed.records.state != .committed)
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
                _ = try await store.unvalidatedHeadPolicy(
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
            _ = try await store.unvalidatedHeadPolicy(
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
            _ = try await store.unvalidatedHeadPolicy(
                for: invalid.commit.scopeID,
                epoch: 1
            )
        }
    }

    @Test("a forged head graph is never returned as committed authority")
    func forgedHeadIsNotCommittedAuthority() async throws {
        let fixture = try U5PolicyFixture.make()
        let forged = try Self.entryWithForgedCommitSignature(fixture)

        // The validator is the only thing entitled to admit authority, and it
        // refuses this graph: its commit signature is not one the verifier
        // accepts. Anything the store subsequently says about the same graph is
        // therefore a statement about transport, not about authority.
        #expect(throws: (any Error).self) {
            _ = try SecretPolicyValidator.validateTransition(
                currentSnapshot: nil,
                stagedRecords: forged.records,
                commit: forged.commit,
                trustedCredentials: forged.credentials,
                trustedDeviceRecords: forged.trustRecords,
                knownCompetingChildDigests: [],
                externalFreshness: try SecretBootstrapFreshnessCommitment(
                    scopeID: forged.commit.scopeID,
                    latestPolicyEpoch: forged.commit.policyEpoch,
                    headCommitDigest: forged.commit.recordDigest,
                    policyDigest: forged.commit.policyDigest
                ),
                digester: U5PolicyFixture.digester,
                signatureVerifier: U5ExactSignatureVerifier()
            )
        }

        // Stage the forged graph and move the mutable scope head onto it —
        // exactly what a party with write access to the SecretSync private
        // database can do without ever holding a signing key.
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(forged)
        try await database.replaceHead(
            SecretSyncCloudKitScopeHead(
                scopeID: forged.commit.scopeID,
                policyEpoch: forged.commit.policyEpoch,
                headCommitDigest: forged.commit.recordDigest,
                policyDigest: forged.commit.policyDigest
            )
        )

        let reconstructed = try #require(
            try await store.unvalidatedHeadPolicy(
                for: forged.commit.scopeID,
                epoch: 1
            )
        )

        // Reconstruction still succeeds: content-addressing and every
        // structural binding hold, because forging the signature bytes leaves
        // both intact. That is the whole point — structure is not authority.
        #expect(reconstructed.commit == forged.commit)
        #expect(reconstructed.records.signedPolicy == forged.records.signedPolicy)

        // The regression: head-derived material must never carry the
        // validator-admitted label.
        #expect(reconstructed.records.state != .committed)
        #expect(reconstructed.records.state == .staged)
    }

    /// Rebuild the genesis transition commit with signature bytes no verifier
    /// admits, recomputing its content address so the graph remains exactly
    /// content-addressed and every structural binding the store checks still
    /// holds. `U5ExactSignatureVerifier` admits only `Data([0xA1])`, so `0xEE`
    /// bytes cannot verify against any credential in the fixture.
    private static func entryWithForgedCommitSignature(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        let original = fixture.entry.commit
        let commit = try contentAddressedCommit { digest in
            try SecretTransitionCommit(
                recordDigest: digest,
                scopeID: original.scopeID,
                policyEpoch: original.policyEpoch,
                predecessorCommitDigest: original.predecessorCommitDigest,
                policyDigest: original.policyDigest,
                scopeSnapshotDigest: original.scopeSnapshotDigest,
                generationID: original.generationID,
                sealedPayloadDigest: original.sealedPayloadDigest,
                recipientEnvelopeDigests: original.recipientEnvelopeDigests,
                recoveryEnvelopeDigest: original.recoveryEnvelopeDigest,
                purgeRequirementDigests: original.purgeRequirementDigests,
                purgeReceiptDigests: original.purgeReceiptDigests,
                recoveryAuthorizationDigest: original.recoveryAuthorizationDigest,
                signerCredentialID: original.signerCredentialID,
                signature: Data([0xEE, 0xEE])
            )
        }
        return try SecretPolicyStoreEntry(
            commit: commit,
            records: fixture.entry.records,
            credentials: fixture.entry.credentials,
            trustRecords: fixture.entry.trustRecords,
            digester: U5PolicyFixture.digester
        )
    }

    /// Two-pass content addressing: `canonicalBytes()` excludes `recordDigest`,
    /// so building once with a placeholder yields the bytes whose digest is the
    /// record's true address.
    private static func contentAddressedCommit(
        _ build: (SecretRecordDigest) throws -> SecretTransitionCommit
    ) throws -> SecretTransitionCommit {
        let placeholder = try SecretRecordDigest(
            bytes: Data(repeating: 0, count: SecretRecordDigest.byteCount)
        )
        let provisional = try build(placeholder)
        let address = try U5PolicyFixture.digester.digest(
            canonicalBytes: provisional.canonicalBytes()
        )
        return try build(address)
    }
}

private struct U6RecoveryCASHarness {
    let fixture: U6RecoveryPolicyFixture
    let database: U5ScriptedDatabase
    let store: SecretSyncCloudKitPolicyStore
    let attemptsBeforeRecovery: Int

    static func make(now: UInt64) async throws -> U6RecoveryCASHarness {
        let fixture = try U6RecoveryPolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester,
            recoveryTimeSource: { now }
        )
        try await store.appendStagedPolicy(fixture.current.entry)
        _ = try await store.compareAndAdvance(
            U5PolicyFixture.precondition(fixture.current, expected: nil)
        )
        try await store.appendStagedPolicy(fixture.entry)
        return U6RecoveryCASHarness(
            fixture: fixture,
            database: database,
            store: store,
            attemptsBeforeRecovery: await database.headCASAttemptCount
        )
    }
}
