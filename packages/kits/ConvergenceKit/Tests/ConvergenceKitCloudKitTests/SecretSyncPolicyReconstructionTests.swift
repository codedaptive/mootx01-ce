import CloudKit
@testable import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit policy reconstruction")
struct SecretSyncPolicyReconstructionTests {
    @Test("configured engine creates both SecretSync zones before exposure")
    func configuredEngineCreatesExactZones() async throws {
        let database = U5ScriptedDatabase()
        let storage = try await TwoEstateFixture.makeStorage()
        let actor = CloudKitStateActor(
            containerIdentifier: nil,
            secretSyncDigester: U5PolicyFixture.digester
        )
        await actor.setTestDatabase(database)

        try await actor.enable(
            manifest: TwoEstateFixture.manifest,
            storage: storage
        )

        let batches = await database.savedZoneBatches
        #expect(batches.count == 2)
        #expect(Set(batches[1]) == Set(SecretSyncCloudKitZones.allZoneIDs))
        _ = try await actor.secretSyncPolicyStore()
        _ = try await actor.secretSyncFreshnessTransport()
        await actor.disable()
    }

    @Test("complete exact immutable graph reconstructs the staged entry")
    func completeGraphReconstructs() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )

        try await store.appendStagedPolicy(fixture.entry)
        let reconstructed = try await store.stagedPolicy(
            for: fixture.entry.commit.scopeID,
            epoch: fixture.entry.commit.policyEpoch
        )

        #expect(reconstructed == fixture.entry)
        #expect(try await store.policyHead(for: fixture.entry.commit.scopeID) == nil)
        #expect(await database.savedHeadCount == 0)
    }

    @Test("full-loss authorization round-trips with credential provenance")
    func recoveryAuthorizationRoundTrips() async throws {
        let fixture = try U5PolicyFixture.make()
        let entry = try U5PolicyFixture.entryWithRecoveryAuthorization(fixture)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )

        try await store.appendStagedPolicy(entry)
        let reconstructed = try await store.reconstructPolicy(
            commitDigest: entry.commit.recordDigest
        )

        #expect(reconstructed == entry)
        #expect(reconstructed.records.recoveryAuthorization != nil)
        #expect(reconstructed.credentials == entry.credentials)
    }

    @Test("missing full-loss authorization remains non-authoritative")
    func missingRecoveryAuthorizationFailsClosed() async throws {
        let fixture = try U5PolicyFixture.make()
        let entry = try U5PolicyFixture.entryWithRecoveryAuthorization(fixture)
        let authorization = try #require(entry.records.recoveryAuthorization)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(entry)
        await database.removeRecord(
            digest: authorization.recordDigest,
            type: .fullLossRecoveryAuthorization
        )

        await #expect(
            throws: SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
        ) {
            _ = try await store.reconstructPolicy(
                commitDigest: entry.commit.recordDigest
            )
        }
    }

    @Test("missing cross-zone payload remains non-authoritative")
    func missingPayloadFailsClosed() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)
        await database.removeRecord(
            digest: fixture.entry.commit.sealedPayloadDigest,
            type: .sealedPayload
        )

        await #expect(throws: SecretSyncCloudKitPolicyStoreError.incompleteRecordSet) {
            _ = try await store.stagedPolicy(
                for: fixture.entry.commit.scopeID,
                epoch: fixture.entry.commit.policyEpoch
            )
        }
        #expect(try await store.policyHead(for: fixture.entry.commit.scopeID) == nil)
    }

    @Test("unexpected fetch results and tampered bytes fail closed")
    func fetchShapeAndBytesFailClosed() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)

        await database.setInjectUnexpectedFetchResult(true)
        await #expect(throws: SecretSyncCloudKitPolicyStoreError.incompleteFetchResults) {
            _ = try await store.reconstructPolicy(
                commitDigest: fixture.entry.commit.recordDigest
            )
        }

        await database.setInjectUnexpectedFetchResult(false)
        await database.tamperCanonicalBytes(
            digest: fixture.entry.commit.policyDigest,
            type: .signedPolicyEpoch
        )
        await #expect(throws: SecretSyncCloudKitPolicyStoreError.invalidCanonicalRecord) {
            _ = try await store.reconstructPolicy(
                commitDigest: fixture.entry.commit.recordDigest
            )
        }
    }

    @Test("same-scope same-epoch staged children are quarantined as a fork")
    func duplicateEpochCandidatesFailClosed() async throws {
        let first = try U5PolicyFixture.make(generationByte: 0x31)
        let second = try U5PolicyFixture.make(generationByte: 0x32)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(first.entry)
        try await store.appendStagedPolicy(second.entry)

        await #expect(throws: SecretSyncCloudKitPolicyStoreError.competingStagedPolicies) {
            _ = try await store.stagedPolicy(
                for: first.entry.commit.scopeID,
                epoch: 1
            )
        }
    }

    @Test("reconstruction includes the policy exact trust-record set")
    func trustSetIsExact() async throws {
        let fixture = try U5PolicyFixture.make()
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(fixture.entry)
        await database.removeRecord(
            digest: try #require(fixture.entry.trustRecords.first).recordDigest,
            type: .deviceTrustRecord
        )

        await #expect(throws: SecretSyncCloudKitPolicyStoreError.incompleteRecordSet) {
            _ = try await store.reconstructPolicy(
                commitDigest: fixture.entry.commit.recordDigest
            )
        }
    }

    @Test("canonically valid wrong-scope and old-recipient graphs reject")
    func crossRecordBindingsReject() async throws {
        let fixture = try U5PolicyFixture.make()
        for entry in [
            try U5PolicyFixture.entryWithWrongPayloadScope(fixture),
            try U5PolicyFixture.entryWithUnauthorizedRecipient(fixture),
        ] {
            let database = U5ScriptedDatabase()
            let store = SecretSyncCloudKitPolicyStore(
                database: database,
                digester: U5PolicyFixture.digester
            )
            try await store.appendStagedPolicy(entry)
            await #expect(
                throws: SecretSyncCloudKitPolicyStoreError.referenceMismatch
            ) {
                _ = try await store.reconstructPolicy(
                    commitDigest: entry.commit.recordDigest
                )
            }
        }
    }

    @Test("purge receipt must bind exactly to its requirement")
    func purgeBindingsReject() async throws {
        let fixture = try U5PolicyFixture.make()
        let entry = try U5PolicyFixture.entryWithInvalidPurgeReceipt(fixture)
        let database = U5ScriptedDatabase()
        let store = SecretSyncCloudKitPolicyStore(
            database: database,
            digester: U5PolicyFixture.digester
        )
        try await store.appendStagedPolicy(entry)

        await #expect(
            throws: SecretSyncCloudKitPolicyStoreError.referenceMismatch
        ) {
            _ = try await store.reconstructPolicy(
                commitDigest: entry.commit.recordDigest
            )
        }
    }
}

struct U5PolicyFixture: Sendable {
    let entry: SecretPolicyStoreEntry
    let snapshot: SecretControlSnapshot
    let credentials: [TrustedDeviceCredential]

    static let digester = U5DeterministicDigester()
    static let scopeID = SecretScopeID(uuid(0x11))
    static let credentialID = DeviceCredentialID(uuid(0x12))
    static let deviceID = TrustedDeviceID(uuid(0x13))

    static func make(
        previous: U5PolicyFixture? = nil,
        generationByte: UInt8 = 0x31
    ) throws -> U5PolicyFixture {
        let epoch = (previous?.entry.commit.policyEpoch ?? 0) + 1
        let generationID = SecretGenerationID(uuid(generationByte))
        let signingKey = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x21]),
            publicKeyBytes: Data([0x22])
        )
        let agreementKey = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "P256-KA",
            keyIdentifier: Data([0x23]),
            publicKeyBytes: Data([0x24])
        )
        let proof = try DeviceCredentialEnrollmentProof(
            challengeID: uuid(0x14),
            challengeBytes: Data([0x25]),
            signingProofBytes: Data([0x26]),
            keyAgreementProofBytes: Data([0x27]),
            provenance: .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: DeviceCredentialID(uuid(0x15)),
                    signature: Data([0xA1])
                )
            )
        )
        let credential = try TrustedDeviceCredential(
            deviceID: deviceID,
            credentialID: credentialID,
            credentialVersion: 1,
            status: .active,
            signingPublicKey: signingKey,
            keyAgreementPublicKey: agreementKey,
            enrollmentProof: proof
        )
        let credentialDigest = try digester.digest(
            canonicalBytes: credential.canonicalBytes()
        )
        let trustRecord = try contentAddressed { digest in
            try DeviceTrustRecord(
                recordDigest: digest,
                credentialDigest: credentialDigest,
                deviceID: deviceID,
                credentialID: credentialID,
                trustState: .trusted,
                effectivePolicyEpoch: epoch
            )
        }
        let scope = try contentAddressed { digest in
            try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: uuid(0x16),
                memberRecordIDs: [uuid(0x16), uuid(0x17)],
                snapshotDigest: digest
            )
        }
        let recoveryDescriptor = try RecoveryRecipientDescriptor(
            recoveryRecipientID: uuid(0x18),
            keyAgreementPublicKey: try KeyAgreementPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .agreementAlgorithmIdentifier,
                keyIdentifier: Data([0x28]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: 0x29, count: 64)
            ),
            authorizationSigningPublicKey: try SigningPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .authorizationSigningAlgorithmIdentifier,
                keyIdentifier: Data([0x2A]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: 0x2B, count: 64)
            )
        )
        let policy = try SecretPolicyEpoch(
            epoch: epoch,
            predecessorPolicyDigest: previous?.entry.commit.policyDigest,
            scopeSnapshot: scope,
            generationID: generationID,
            authorizedRecipientCredentialIDs: [credentialID],
            trustedDeviceRecordDigests: [trustRecord.recordDigest],
            recoveryRecipient: recoveryDescriptor,
            signerCredentialID: credentialID
        )
        let signedPolicy = try contentAddressed { digest in
            try SignedSecretPolicyEpoch(
                recordDigest: digest,
                policy: policy,
                signature: Data([0xA1])
            )
        }
        let payload = try contentAddressed { digest in
            try SealedPayload(
                recordDigest: digest,
                scopeID: scopeID,
                scopeSnapshotDigest: scope.snapshotDigest,
                policyEpoch: epoch,
                policyDigest: signedPolicy.recordDigest,
                generationID: generationID,
                formatVersion: 1,
                ciphertextBytes: Data([0x30, generationByte])
            )
        }
        let recipient = try contentAddressed { digest in
            try RecipientKeyEnvelope(
                recordDigest: digest,
                scopeID: scopeID,
                scopeSnapshotDigest: scope.snapshotDigest,
                policyEpoch: epoch,
                policyDigest: signedPolicy.recordDigest,
                generationID: generationID,
                recipientCredentialID: credentialID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x32, generationByte])
            )
        }
        let recovery = try contentAddressed { digest in
            try RecoveryEnvelope(
                recordDigest: digest,
                scopeID: scopeID,
                scopeSnapshotDigest: scope.snapshotDigest,
                policyEpoch: epoch,
                policyDigest: signedPolicy.recordDigest,
                generationID: generationID,
                recoveryRecipientID: recoveryDescriptor.recoveryRecipientID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x33, generationByte])
            )
        }
        let records = try SecretControlRecords(
            state: .staged,
            signedPolicy: signedPolicy,
            sealedPayload: payload,
            recipientEnvelopes: [recipient],
            recoveryEnvelope: recovery,
            purgeRequirements: [],
            purgeReceipts: [],
            recoveryAuthorization: nil
        )
        let commit = try contentAddressed { digest in
            try SecretTransitionCommit(
                recordDigest: digest,
                scopeID: scopeID,
                policyEpoch: epoch,
                predecessorCommitDigest: previous?.entry.commit.recordDigest,
                policyDigest: signedPolicy.recordDigest,
                scopeSnapshotDigest: scope.snapshotDigest,
                generationID: generationID,
                sealedPayloadDigest: payload.recordDigest,
                recipientEnvelopeDigests: [recipient.recordDigest],
                recoveryEnvelopeDigest: recovery.recordDigest,
                purgeRequirementDigests: [],
                purgeReceiptDigests: [],
                recoveryAuthorizationDigest: nil,
                signerCredentialID: credentialID,
                signature: Data([0xA1])
            )
        }
        let external = try SecretBootstrapFreshnessCommitment(
            scopeID: scopeID,
            latestPolicyEpoch: epoch,
            headCommitDigest: commit.recordDigest,
            policyDigest: signedPolicy.recordDigest
        )
        let snapshot = try SecretPolicyValidator.validateTransition(
            currentSnapshot: previous?.snapshot,
            stagedRecords: records,
            commit: commit,
            trustedCredentials: [credential],
            trustedDeviceRecords: [trustRecord],
            knownCompetingChildDigests: [],
            externalFreshness: external,
            digester: digester,
            signatureVerifier: U5ExactSignatureVerifier()
        )
        return try U5PolicyFixture(
            entry: SecretPolicyStoreEntry(
                commit: commit,
                records: records,
                credentials: [credential],
                trustRecords: [trustRecord],
                digester: digester
            ),
            snapshot: snapshot,
            credentials: [credential]
        )
    }

    static func commitment(_ fixture: U5PolicyFixture) throws
        -> SecretBootstrapFreshnessCommitment
    {
        try SecretBootstrapFreshnessCommitment(
            scopeID: fixture.entry.commit.scopeID,
            latestPolicyEpoch: fixture.entry.commit.policyEpoch,
            headCommitDigest: fixture.entry.commit.recordDigest,
            policyDigest: fixture.entry.commit.policyDigest
        )
    }

    static func entryWithWrongPayloadScope(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        let original = fixture.entry.records.sealedPayload
        let payload = try contentAddressed { digest in
            try SealedPayload(
                recordDigest: digest,
                scopeID: SecretScopeID(uuid(0x41)),
                scopeSnapshotDigest: original.scopeSnapshotDigest,
                policyEpoch: original.policyEpoch,
                policyDigest: original.policyDigest,
                generationID: original.generationID,
                formatVersion: original.formatVersion,
                ciphertextBytes: original.ciphertextBytes
            )
        }
        return try rebuiltEntry(fixture, payload: payload)
    }

    static func entryWithRecoveryAuthorization(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        let original = fixture.entry
        let policy = original.records.signedPolicy.policy
        let replacementRecovery = try #require(policy.recoveryRecipient)
        let recoveryEnvelope = try #require(original.records.recoveryEnvelope)
        let replacementCredential = try #require(
            original.credentials.first {
                $0.credentialID == original.commit.signerCredentialID
            }
        )
        let currentRecovery = try RecoveryRecipientDescriptor(
            recoveryRecipientID: uuid(0x91),
            keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .agreementAlgorithmIdentifier,
                keyIdentifier: Data([0x92]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: 0x93, count: 64)
            ),
            authorizationSigningPublicKey: SigningPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .authorizationSigningAlgorithmIdentifier,
                keyIdentifier: Data([0x94]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: 0x95, count: 64)
            )
        )
        let credentialDigests = try original.credentials.map {
            try digester.digest(canonicalBytes: $0.canonicalBytes())
        }
        let semantics = try FullLossRecoveryCandidateSemantics(
            scopeSnapshotDigest: original.commit.scopeSnapshotDigest,
            signedPolicyDigest: original.commit.policyDigest,
            sealedPayloadDigest: original.commit.sealedPayloadDigest,
            recipientEnvelopeDigests: original.commit.recipientEnvelopeDigests,
            recoveryEnvelopeDigest: recoveryEnvelope.recordDigest,
            purgeRequirementDigests: original.commit.purgeRequirementDigests,
            purgeReceiptDigests: [],
            credentialDigests: credentialDigests,
            trustRecordDigests: original.trustRecords.map(\.recordDigest)
        )
        let challenge = try FullLossRecoveryChallenge(
            requestID: uuid(0x96),
            challengeID: uuid(0x97),
            sessionID: uuid(0x98),
            nonce: Data(repeating: 0x99, count: 16),
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        )
        let intent = try GlobalRecoveryTransitionIntent(
            appNamespace: "com.codedaptive.cloudkit.tests",
            estateID: uuid(0x9A),
            scopeID: original.commit.scopeID,
            challenge: challenge,
            warning: FullLossRecoveryWarningAcknowledgement(
                acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
            ),
            currentCommitDigest: try digest(0x9B),
            currentPolicyDigest: try digest(0x9C),
            currentPolicyEpoch: original.commit.policyEpoch - 1,
            currentGenerationID: SecretGenerationID(uuid(0x9D)),
            currentRecoveryRecipient: currentRecovery,
            replacementDeviceID: replacementCredential.deviceID,
            replacementCredentialID: replacementCredential.credentialID,
            replacementSigningPublicKey: replacementCredential.signingPublicKey,
            replacementAgreementPublicKey: replacementCredential.keyAgreementPublicKey,
            signingPossessionProof: Data([0x9E]),
            agreementPossessionProof: Data([0x9F]),
            candidatePolicyEpoch: original.commit.policyEpoch,
            candidateGenerationID: original.commit.generationID,
            candidateSignedPolicyDigest: original.commit.policyDigest,
            replacementRecoveryRecipient: replacementRecovery,
            recoveryEnvelopeDigest: recoveryEnvelope.recordDigest,
            candidateSemantics: semantics
        )
        let authorization = try contentAddressed { recordDigest in
            try FullLossRecoveryAuthorization(
                recordDigest: recordDigest,
                intent: intent,
                signature: Data([0xA0])
            )
        }
        let records = try SecretControlRecords(
            state: .staged,
            signedPolicy: original.records.signedPolicy,
            sealedPayload: original.records.sealedPayload,
            recipientEnvelopes: original.records.recipientEnvelopes,
            recoveryEnvelope: recoveryEnvelope,
            purgeRequirements: original.records.purgeRequirements,
            purgeReceipts: [],
            recoveryAuthorization: authorization
        )
        let commit = try contentAddressed { recordDigest in
            try SecretTransitionCommit(
                recordDigest: recordDigest,
                scopeID: original.commit.scopeID,
                policyEpoch: original.commit.policyEpoch,
                predecessorCommitDigest: original.commit.predecessorCommitDigest,
                policyDigest: original.commit.policyDigest,
                scopeSnapshotDigest: original.commit.scopeSnapshotDigest,
                generationID: original.commit.generationID,
                sealedPayloadDigest: original.commit.sealedPayloadDigest,
                recipientEnvelopeDigests: original.commit.recipientEnvelopeDigests,
                recoveryEnvelopeDigest: original.commit.recoveryEnvelopeDigest,
                purgeRequirementDigests: original.commit.purgeRequirementDigests,
                purgeReceiptDigests: [],
                recoveryAuthorizationDigest: authorization.recordDigest,
                signerCredentialID: original.commit.signerCredentialID,
                signature: original.commit.signature
            )
        }
        return try SecretPolicyStoreEntry(
            commit: commit,
            records: records,
            credentials: original.credentials,
            trustRecords: original.trustRecords,
            digester: digester
        )
    }

    static func entryWithUnauthorizedRecipient(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        guard let original = fixture.entry.records.recipientEnvelopes.first else {
            throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
        }
        let recipient = try contentAddressed { digest in
            try RecipientKeyEnvelope(
                recordDigest: digest,
                scopeID: original.scopeID,
                scopeSnapshotDigest: original.scopeSnapshotDigest,
                policyEpoch: original.policyEpoch,
                policyDigest: original.policyDigest,
                generationID: original.generationID,
                recipientCredentialID: DeviceCredentialID(uuid(0x42)),
                formatVersion: original.formatVersion,
                wrappedKeyBytes: original.wrappedKeyBytes
            )
        }
        return try rebuiltEntry(fixture, recipients: [recipient])
    }

    static func entryWithInvalidPurgeReceipt(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        try entryWithPurgeTombstone(
            fixture,
            supersededGenerationID: SecretGenerationID(uuid(0x43)),
            status: .partial
        )
    }

    static func entryWithExtraPurgeTarget(
        _ fixture: U5PolicyFixture,
        predecessor: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        try entryWithPurgeTombstone(
            fixture,
            supersededGenerationID: predecessor.entry.commit.generationID,
            status: .completed
        )
    }

    private static func entryWithPurgeTombstone(
        _ fixture: U5PolicyFixture,
        supersededGenerationID: SecretGenerationID,
        status: PurgeReceiptStatus
    ) throws -> SecretPolicyStoreEntry {
        let commit = fixture.entry.commit
        let requirement = try contentAddressed { digest in
            try PurgeRequirement(
                recordDigest: digest,
                scopeID: commit.scopeID,
                policyEpoch: commit.policyEpoch,
                policyDigest: commit.policyDigest,
                supersededGenerationID: supersededGenerationID,
                replacementGenerationID: commit.generationID,
                targetCredentialID: credentialID,
                requiredCategories: [.plaintext]
            )
        }
        let receipt = try contentAddressed { digest in
            try SignedPurgeReceipt(
                recordDigest: digest,
                requirementDigest: requirement.recordDigest,
                scopeID: requirement.scopeID,
                policyEpoch: requirement.policyEpoch,
                policyDigest: requirement.policyDigest,
                supersededGenerationID: requirement.supersededGenerationID,
                replacementGenerationID: requirement.replacementGenerationID,
                respondingCredentialID: requirement.targetCredentialID,
                coveredCategories: requirement.requiredCategories,
                status: status,
                signerCredentialID: requirement.targetCredentialID,
                signature: Data([0xA1])
            )
        }
        return try rebuiltEntry(
            fixture,
            purgeRequirements: [requirement],
            purgeReceipts: [receipt]
        )
    }

    static func entryWithWrongPredecessorPolicy(
        _ fixture: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        try entryRebindingPolicy(
            fixture,
            predecessorPolicyDigest: try digest(0x44),
            generationID: fixture.entry.commit.generationID
        )
    }

    static func entryReusingGeneration(
        _ fixture: U5PolicyFixture,
        predecessor: U5PolicyFixture
    ) throws -> SecretPolicyStoreEntry {
        try entryRebindingPolicy(
            fixture,
            predecessorPolicyDigest: predecessor.entry.commit.policyDigest,
            generationID: predecessor.entry.commit.generationID
        )
    }

    static func overflowPredecessorChain(
        _ fixture: U5PolicyFixture
    ) throws -> (
        predecessor: SecretPolicyStoreEntry,
        child: SecretPolicyStoreEntry
    ) {
        let predecessor = try entryRebindingPolicy(
            fixture,
            predecessorPolicyDigest: try digest(0x45),
            generationID: SecretGenerationID(uuid(0x46)),
            policyEpoch: .max
        )
        let child = try entryRebindingPolicy(
            fixture,
            predecessorPolicyDigest: predecessor.commit.policyDigest,
            generationID: fixture.entry.commit.generationID,
            predecessorCommitDigest: predecessor.commit.recordDigest
        )
        return (predecessor, child)
    }

    private static func entryRebindingPolicy(
        _ fixture: U5PolicyFixture,
        predecessorPolicyDigest: SecretRecordDigest,
        generationID: SecretGenerationID,
        policyEpoch: UInt64? = nil,
        predecessorCommitDigest: SecretRecordDigest? = nil
    ) throws -> SecretPolicyStoreEntry {
        let old = fixture.entry.records.signedPolicy.policy
        let reboundEpoch = policyEpoch ?? old.epoch
        let policy = try SecretPolicyEpoch(
            epoch: reboundEpoch,
            predecessorPolicyDigest: predecessorPolicyDigest,
            scopeSnapshot: old.scopeSnapshot,
            generationID: generationID,
            authorizedRecipientCredentialIDs: old.authorizedRecipientCredentialIDs,
            trustedDeviceRecordDigests: old.trustedDeviceRecordDigests,
            recoveryRecipient: old.recoveryRecipient,
            signerCredentialID: old.signerCredentialID
        )
        let signed = try contentAddressed { digest in
            try SignedSecretPolicyEpoch(
                recordDigest: digest,
                policy: policy,
                signature: Data([0xA1])
            )
        }
        let oldPayload = fixture.entry.records.sealedPayload
        let payload = try contentAddressed { digest in
            try SealedPayload(
                recordDigest: digest,
                scopeID: oldPayload.scopeID,
                scopeSnapshotDigest: oldPayload.scopeSnapshotDigest,
                policyEpoch: reboundEpoch,
                policyDigest: signed.recordDigest,
                generationID: generationID,
                formatVersion: oldPayload.formatVersion,
                ciphertextBytes: oldPayload.ciphertextBytes
            )
        }
        let recipients = try fixture.entry.records.recipientEnvelopes.map { old in
            try contentAddressed { digest in
                try RecipientKeyEnvelope(
                    recordDigest: digest,
                    scopeID: old.scopeID,
                    scopeSnapshotDigest: old.scopeSnapshotDigest,
                    policyEpoch: reboundEpoch,
                    policyDigest: signed.recordDigest,
                    generationID: generationID,
                    recipientCredentialID: old.recipientCredentialID,
                    formatVersion: old.formatVersion,
                    wrappedKeyBytes: old.wrappedKeyBytes
                )
            }
        }
        let recovery = try fixture.entry.records.recoveryEnvelope.map { old in
            try contentAddressed { digest in
                try RecoveryEnvelope(
                    recordDigest: digest,
                    scopeID: old.scopeID,
                    scopeSnapshotDigest: old.scopeSnapshotDigest,
                    policyEpoch: reboundEpoch,
                    policyDigest: signed.recordDigest,
                    generationID: generationID,
                    recoveryRecipientID: old.recoveryRecipientID,
                    formatVersion: old.formatVersion,
                    wrappedKeyBytes: old.wrappedKeyBytes
                )
            }
        }
        return try rebuiltEntry(
            fixture,
            signedPolicy: signed,
            payload: payload,
            recipients: recipients,
            recovery: recovery,
            generationID: generationID,
            policyEpoch: reboundEpoch,
            predecessorCommitDigest: predecessorCommitDigest
        )
    }

    private static func rebuiltEntry(
        _ fixture: U5PolicyFixture,
        signedPolicy: SignedSecretPolicyEpoch? = nil,
        payload: SealedPayload? = nil,
        recipients: [RecipientKeyEnvelope]? = nil,
        recovery: RecoveryEnvelope? = nil,
        purgeRequirements: [PurgeRequirement] = [],
        purgeReceipts: [SignedPurgeReceipt] = [],
        generationID: SecretGenerationID? = nil,
        policyEpoch: UInt64? = nil,
        predecessorCommitDigest: SecretRecordDigest? = nil
    ) throws -> SecretPolicyStoreEntry {
        let original = fixture.entry
        let signed = signedPolicy ?? original.records.signedPolicy
        let sealed = payload ?? original.records.sealedPayload
        let recipientValues = recipients ?? original.records.recipientEnvelopes
        let recoveryValue = recovery ?? original.records.recoveryEnvelope
        let records = try SecretControlRecords(
            state: .staged,
            signedPolicy: signed,
            sealedPayload: sealed,
            recipientEnvelopes: recipientValues,
            recoveryEnvelope: recoveryValue,
            purgeRequirements: purgeRequirements,
            purgeReceipts: purgeReceipts,
            recoveryAuthorization: nil
        )
        let commit = try contentAddressed { digest in
            try SecretTransitionCommit(
                recordDigest: digest,
                scopeID: original.commit.scopeID,
                policyEpoch: policyEpoch ?? original.commit.policyEpoch,
                predecessorCommitDigest: predecessorCommitDigest
                    ?? original.commit.predecessorCommitDigest,
                policyDigest: signed.recordDigest,
                scopeSnapshotDigest: original.commit.scopeSnapshotDigest,
                generationID: generationID ?? original.commit.generationID,
                sealedPayloadDigest: sealed.recordDigest,
                recipientEnvelopeDigests: recipientValues.map(\.recordDigest),
                recoveryEnvelopeDigest: recoveryValue?.recordDigest,
                purgeRequirementDigests: purgeRequirements.map(\.recordDigest),
                purgeReceiptDigests: purgeReceipts.map(\.recordDigest),
                recoveryAuthorizationDigest: nil,
                signerCredentialID: original.commit.signerCredentialID,
                signature: original.commit.signature
            )
        }
        return try SecretPolicyStoreEntry(
            commit: commit,
            records: records,
            credentials: original.credentials,
            trustRecords: original.trustRecords,
            digester: digester
        )
    }

    static func precondition(
        _ fixture: U5PolicyFixture,
        expected: U5PolicyFixture?
    ) throws -> SecretPolicyAdvancePrecondition {
        try SecretPolicyAdvancePrecondition(
            expectedHead: try expected.map {
                try SecretPolicyStoreHead(
                    scopeID: $0.entry.commit.scopeID,
                    policyEpoch: $0.entry.commit.policyEpoch,
                    commitDigest: $0.entry.commit.recordDigest,
                    policyDigest: $0.entry.commit.policyDigest
                )
            },
            candidateEntry: fixture.entry,
            validatedSnapshot: fixture.snapshot
        )
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte
        ))
    }

    private static func contentAddressed<T: SecretSyncCanonicalEncodable>(
        _ build: (SecretRecordDigest) throws -> T
    ) throws -> T {
        let provisional = try build(try digest(0))
        let computed = try digester.digest(canonicalBytes: provisional.canonicalBytes())
        return try build(computed)
    }

    private static func digest(_ byte: UInt8) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
    }
}

struct U5DeterministicDigester: SecretSyncDigesting {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        var bytes = [UInt8](repeating: 0, count: SecretRecordDigest.byteCount)
        for (index, byte) in canonicalBytes.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return try SecretRecordDigest(bytes: Data(bytes))
    }
}

struct U5ExactSignatureVerifier: SecretSignatureVerifying {
    func verify(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool {
        signature == Data([0xA1])
            && canonicalBytes.starts(with: Data([0x53, 0x53, 0x43, 0x50]))
            && signingPublicKey.algorithmIdentifier == "P256"
            && signingPublicKey.keyIdentifier == Data([0x21])
    }
}

actor U5ScriptedDatabase: CloudKitDatabaseProtocol {
    struct ModifyCapture: Sendable {
        let types: [String]
        let savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        let atomically: Bool
    }

    private var records: [CKRecord.ID: CKRecord] = [:]
    private var captures: [ModifyCapture] = []
    private var zoneSaveBatches: [[CKRecordZone.ID]] = []
    private var detachedHeadCandidate = false
    private var preservedHeadChangeTag = false
    private var failNextHeadCAS = false
    private var failNextFetchTransport = false
    private var injectUnexpectedFetchResult = false

    var savedHeadCount: Int {
        records.values.filter {
            $0.recordType == SecretSyncCloudKitRecordType.scopeHead.rawValue
        }.count
    }

    var headCASAttemptCount: Int {
        captures.filter { $0.types == [SecretSyncCloudKitRecordType.scopeHead.rawValue] }.count
    }

    var savedZoneBatches: [[CKRecordZone.ID]] { zoneSaveBatches }
    var observedDetachedHeadCandidate: Bool { detachedHeadCandidate }
    var observedPreservedHeadChangeTag: Bool { preservedHeadChangeTag }

    func setFailNextHeadCAS(_ value: Bool) { failNextHeadCAS = value }
    func setFailNextFetchTransport(_ value: Bool) {
        failNextFetchTransport = value
    }
    func setInjectUnexpectedFetchResult(_ value: Bool) {
        injectUnexpectedFetchResult = value
    }

    func removeHead(scopeID: SecretScopeID) {
        records.removeValue(forKey: Self.headID(scopeID))
    }

    func replaceHead(_ value: SecretSyncCloudKitScopeHead) throws {
        let record = try CKRecordMapping.secretSyncScopeHeadRecord(value)
        records[record.recordID] = record
    }

    func removeRecord(
        digest: SecretRecordDigest,
        type: SecretSyncCloudKitRecordType
    ) {
        records.removeValue(forKey: Self.recordID(digest, type: type))
    }

    func tamperCanonicalBytes(
        digest: SecretRecordDigest,
        type: SecretSyncCloudKitRecordType
    ) {
        let id = Self.recordID(digest, type: type)
        records[id]?["ss_canonical_bytes"] = Data([0x00]) as NSData
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        captures.append(
            ModifyCapture(
                types: recordsToSave.map(\.recordType),
                savePolicy: savePolicy,
                atomically: atomically
            )
        )
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in recordsToSave {
            if record.recordType
                == SecretSyncCloudKitRecordType.scopeHead.rawValue,
                let existing = records[record.recordID]
            {
                detachedHeadCandidate = detachedHeadCandidate
                    || record !== existing
                preservedHeadChangeTag = preservedHeadChangeTag
                    || record.recordChangeTag == existing.recordChangeTag
            }
            if record.recordType == SecretSyncCloudKitRecordType.scopeHead.rawValue,
               failNextHeadCAS
            {
                failNextHeadCAS = false
                saveResults[record.recordID] = .failure(CKError(.serverRecordChanged))
            } else if record.recordType
                == SecretSyncCloudKitRecordType.scopeHead.rawValue,
                let existing = records[record.recordID],
                let existingHead = try? CKRecordMapping
                    .decodeSecretSyncScopeHead(existing),
                let candidateHead = try? CKRecordMapping
                    .decodeSecretSyncScopeHead(record),
                existingHead.policyEpoch >= candidateHead.policyEpoch
            {
                // The in-memory CKRecord test double has no writable server
                // change tag, so epoch monotonicity models the server's stale
                // conditional-write rejection for deterministic CAS races.
                saveResults[record.recordID] = .failure(
                    CKError(.serverRecordChanged)
                )
            } else if let existing = records[record.recordID],
                      record.recordType != SecretSyncCloudKitRecordType.scopeHead.rawValue
            {
                saveResults[record.recordID] = .failure(
                    CKError(
                        .serverRecordChanged,
                        userInfo: [CKRecordChangedErrorServerRecordKey: existing]
                    )
                )
            } else {
                records[record.recordID] = record
                saveResults[record.recordID] = .success(record)
            }
        }
        return (
            saveResults,
            Dictionary(uniqueKeysWithValues: recordIDsToDelete.map { ($0, .success(())) })
        )
    }

    func fetch(
        withRecordIDs recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        if failNextFetchTransport {
            failNextFetchTransport = false
            throw CKError(.networkFailure)
        }
        var result: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for id in recordIDs {
            if let record = records[id] {
                result[id] = .success(record)
            } else {
                result[id] = .failure(CKError(.unknownItem))
            }
        }
        if injectUnexpectedFetchResult {
            let extra = CKRecord.ID(
                recordName: "unexpected",
                zoneID: SecretSyncCloudKitZones.controlZoneID
            )
            result[extra] = .failure(CKError(.unknownItem))
        }
        return result
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since _: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        CloudKitZoneChanges(
            modifiedRecords: records.values.filter { $0.recordID.zoneID == zoneID },
            deletedRecordIDs: [],
            changeToken: nil
        )
    }

    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        zoneSaveBatches.append(recordZonesToSave.map(\.zoneID))
        return (
            Dictionary(uniqueKeysWithValues: recordZonesToSave.map { ($0.zoneID, .success($0)) }),
            Dictionary(uniqueKeysWithValues: recordZoneIDsToDelete.map { ($0, .success(())) })
        )
    }

    func modifySubscriptions(
        saving subscriptionsToSave: [CKSubscription],
        deleting subscriptionIDsToDelete: [CKSubscription.ID]
    ) async throws -> (
        saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
        deleteResults: [CKSubscription.ID: Result<Void, any Error>]
    ) {
        (
            Dictionary(uniqueKeysWithValues: subscriptionsToSave.map {
                ($0.subscriptionID, .success($0))
            }),
            Dictionary(uniqueKeysWithValues: subscriptionIDsToDelete.map {
                ($0, .success(()))
            })
        )
    }

    private static func recordID(
        _ digest: SecretRecordDigest,
        type: SecretSyncCloudKitRecordType
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: digest.bytes.map { String(format: "%02x", $0) }.joined(),
            zoneID: SecretSyncCloudKitZones.zoneID(for: type)
        )
    }

    private static func headID(_ scopeID: SecretScopeID) -> CKRecord.ID {
        var value = scopeID.rawValue.uuid
        let bytes = withUnsafeBytes(of: &value) { Data($0) }
        return CKRecord.ID(
            recordName: bytes.map { String(format: "%02x", $0) }.joined(),
            zoneID: SecretSyncCloudKitZones.controlZoneID
        )
    }
}
