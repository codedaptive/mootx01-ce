import Foundation
import Testing

@testable import ConvergenceKit

@Suite("SecretSync full-loss recovery authority")
struct SecretSyncRecoveryAuthorityContractTests {
    @Test("recovery descriptor binds separate agreement and authorization roles")
    func sevenElementRecoveryDescriptor() throws {
        let agreement = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "mootx01.secret-recovery.hkdf-sha256-p256-agreement.v2",
            keyIdentifier: Data([0x01]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x02, count: 64)
        )
        let authorization = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "mootx01.secret-recovery.hkdf-sha256-p256-ecdsa-sha256-authorization.v2",
            keyIdentifier: Data([0x03]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x05, count: 64)
        )

        let descriptor = try RecoveryRecipientDescriptor(
            recoveryRecipientID: UUID(
                uuidString: "A0000000-0000-0000-0000-000000000001"
            )!,
            keyAgreementPublicKey: agreement,
            authorizationSigningPublicKey: authorization
        )

        let values = try decodeSequence(descriptor.canonicalValue())
        #expect(values.count == 7)
        #expect(values[1] == Data(agreement.algorithmIdentifier.utf8))
        #expect(values[4] == Data(authorization.algorithmIdentifier.utf8))
        #expect(values[2] != values[5])
        #expect(values[3] != values[6])
    }

    @Test("challenge enforces nonce and half-open five-minute window")
    func challengeBounds() throws {
        let valid = try FullLossRecoveryChallenge(
            requestID: fixtureUUID(1),
            challengeID: fixtureUUID(2),
            sessionID: fixtureUUID(3),
            nonce: Data(repeating: 0xA0, count: 16),
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 301_000
        )
        #expect(valid.isValid(atMilliseconds: 1_000))
        #expect(valid.isValid(atMilliseconds: 300_999))
        #expect(!valid.isValid(atMilliseconds: 301_000))
        #expect(!valid.isValid(atMilliseconds: 999))

        expectRecoveryError(.invalidNonce) {
            _ = try FullLossRecoveryChallenge(
                requestID: fixtureUUID(1),
                challengeID: fixtureUUID(2),
                sessionID: fixtureUUID(3),
                nonce: Data(repeating: 0xA0, count: 15),
                issuedAtMilliseconds: 1_000,
                expiresAtMilliseconds: 2_000
            )
        }
        expectRecoveryError(.invalidTimeWindow) {
            _ = try FullLossRecoveryChallenge(
                requestID: fixtureUUID(1),
                challengeID: fixtureUUID(2),
                sessionID: fixtureUUID(3),
                nonce: Data(repeating: 0xA0, count: 16),
                issuedAtMilliseconds: 1_000,
                expiresAtMilliseconds: 301_001
            )
        }
    }

    @Test("candidate semantics sort complete digest sets and reject duplicates")
    func candidateSemanticsAreExactSets() throws {
        let value = try FullLossRecoveryCandidateSemantics(
            scopeSnapshotDigest: digest(0x01),
            signedPolicyDigest: digest(0x02),
            sealedPayloadDigest: digest(0x03),
            recipientEnvelopeDigests: [digest(0x05), digest(0x04)],
            recoveryEnvelopeDigest: digest(0x06),
            purgeRequirementDigests: [digest(0x08), digest(0x07)],
            purgeReceiptDigests: [],
            credentialDigests: [digest(0x0A), digest(0x09)],
            trustRecordDigests: [digest(0x0C), digest(0x0B)]
        )
        let expectedRecipients = [try digest(0x04), try digest(0x05)]
        let expectedCredentials = [try digest(0x09), try digest(0x0A)]
        #expect(value.recipientEnvelopeDigests == expectedRecipients)
        #expect(value.credentialDigests == expectedCredentials)

        expectRecoveryError(.duplicateDigest) {
            _ = try FullLossRecoveryCandidateSemantics(
                scopeSnapshotDigest: digest(0x01),
                signedPolicyDigest: digest(0x02),
                sealedPayloadDigest: digest(0x03),
                recipientEnvelopeDigests: [digest(0x04)],
                recoveryEnvelopeDigest: digest(0x06),
                purgeRequirementDigests: [],
                purgeReceiptDigests: [],
                credentialDigests: [digest(0x09), digest(0x09)],
                trustRecordDigests: [digest(0x0B)]
            )
        }
    }

    @Test("recovery enrollment provenance cannot impersonate device authority")
    func typedEnrollmentProvenance() throws {
        let proof = try DeviceCredentialEnrollmentProof(
            challengeID: fixtureUUID(20),
            challengeBytes: Data([0x20]),
            signingProofBytes: Data([0x21]),
            keyAgreementProofBytes: Data([0x22]),
            provenance: .globalRecovery(
                GlobalRecoveryEnrollmentAuthority(
                    requestID: fixtureUUID(21),
                    recoveryRecipientID: fixtureUUID(22)
                )
            )
        )
        let document = try SecretSyncCanonicalEncoding.decode(
            proof.canonicalBytes(),
            expectedDomain: .deviceEnrollmentProof
        )
        #expect(document.fields.map(\.tag) == [1, 2, 3, 4, 6, 7])
        #expect(proof.trustedDeviceAuthority == nil)
        #expect(proof.globalRecoveryAuthority != nil)
    }

    @Test("full-loss admission revokes old trust and installs one replacement")
    func fullLossAdmissionIsAtomic() throws {
        let fixture = try FullLossFixture.make()
        let snapshot = try fixture.validate()

        #expect(snapshot.state == .committed)
        #expect(
            snapshot.trustedDeviceRecords.filter { $0.trustState == .trusted }
                .map(\.credentialID) == [fixture.replacementCredentialID]
        )
        #expect(
            snapshot.trustedDeviceRecords.contains {
                $0.credentialID == fixture.oldCredentialID
                    && $0.trustState == .revoked
            }
        )
        #expect(snapshot.records.purgeReceipts.isEmpty)
    }

    @Test("full-loss challenge expires at the half-open boundary")
    func fullLossAdmissionRejectsExpiredChallenge() throws {
        let fixture = try FullLossFixture.make()
        expectPolicyError(.fullLossRecoveryChallengeExpired) {
            _ = try fixture.validate(nowMilliseconds: 2_000)
        }
    }

    @Test("candidate recovery key cannot authorize replacement of current key")
    func candidateRecoveryKeyIsNotAuthority() throws {
        let fixture = try FullLossFixture.make()
        expectPolicyError(.fullLossRecoveryProofRejected) {
            _ = try fixture.validate(
                recoveryVerifier: RecoveryAuthorityVerifier(
                    expectedAuthorizationKey: fixture.candidateRecoveryKey,
                    acceptSigningPossession: true,
                    acceptAgreementPossession: true
                )
            )
        }
    }

    @Test("both independent replacement-key possession proofs are required")
    func bothPossessionProofsAreRequired() throws {
        let fixture = try FullLossFixture.make()
        expectPolicyError(.fullLossRecoveryProofRejected) {
            _ = try fixture.validate(
                recoveryVerifier: RecoveryAuthorityVerifier(
                    expectedAuthorizationKey: fixture.currentRecoveryKey,
                    acceptSigningPossession: true,
                    acceptAgreementPossession: false
                )
            )
        }
    }

    @Test("known competing child blocks break-glass admission")
    func competingChildBlocksRecovery() throws {
        let fixture = try FullLossFixture.make()
        expectPolicyError(.samePredecessorForkDecisionRequired) {
            _ = try fixture.validate(
                knownCompetingChildDigests: [digest(0xF0)]
            )
        }
    }

    @Test("ordinary transition admission cannot consume recovery authority")
    func normalAdmissionRejectsRecoveryProof() throws {
        let fixture = try FullLossFixture.make()
        let entry = fixture.prepared.entry
        expectPolicyError(.recoveryAuthorizationUnexpected) {
            _ = try SecretPolicyValidator.validateTransition(
                currentSnapshot: fixture.currentSnapshot,
                stagedRecords: entry.records,
                commit: entry.commit,
                trustedCredentials: entry.credentials,
                trustedDeviceRecords: entry.trustRecords,
                knownCompetingChildDigests: [],
                externalFreshness: fixture.externalFreshness,
                digester: RecoveryAuthorityDigester(),
                signatureVerifier: ReplacementSignatureVerifier()
            )
        }
    }
}

private struct FullLossFixture {
    static let appNamespace = "com.codedaptive.fulcrum.tests"
    static let estateID = fixtureUUID(400)

    let currentSnapshot: SecretControlSnapshot
    let prepared: RecoveryPreparedTransition
    let externalFreshness: SecretBootstrapFreshnessCommitment
    let oldCredentialID: DeviceCredentialID
    let replacementCredentialID: DeviceCredentialID
    let currentRecoveryKey: SigningPublicKeyDescriptor
    let candidateRecoveryKey: SigningPublicKeyDescriptor

    static func make() throws -> FullLossFixture {
        let digester = RecoveryAuthorityDigester()
        let scopeID = SecretScopeID(fixtureUUID(401))
        let oldCredential = try normalCredential(
            device: 402,
            credential: 403,
            byte: 0x21
        )
        let oldCredentialDigest = try digester.digest(
            canonicalBytes: oldCredential.canonicalBytes()
        )
        let currentTrust = try addressed(digester) { recordDigest in
            try DeviceTrustRecord(
                recordDigest: recordDigest,
                credentialDigest: oldCredentialDigest,
                deviceID: oldCredential.deviceID,
                credentialID: oldCredential.credentialID,
                trustState: .trusted,
                effectivePolicyEpoch: 1
            )
        }
        let currentRecovery = try recoveryDescriptor(
            id: 404,
            agreementByte: 0x31,
            signingByte: 0x32
        )
        let currentGeneration = SecretGenerationID(fixtureUUID(405))
        let currentScope = try addressed(digester) { snapshotDigest in
            try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: fixtureUUID(406),
                memberRecordIDs: [fixtureUUID(406)],
                snapshotDigest: snapshotDigest
            )
        }
        let currentPolicy = try SecretPolicyEpoch(
            epoch: 1,
            predecessorPolicyDigest: nil,
            scopeSnapshot: currentScope,
            generationID: currentGeneration,
            authorizedRecipientCredentialIDs: [oldCredential.credentialID],
            trustedDeviceRecordDigests: [currentTrust.recordDigest],
            recoveryRecipient: currentRecovery,
            signerCredentialID: oldCredential.credentialID
        )
        let currentSigned = try addressed(digester) { recordDigest in
            try SignedSecretPolicyEpoch(
                recordDigest: recordDigest,
                policy: currentPolicy,
                signature: Data([0x41])
            )
        }
        let currentPayload = try addressed(digester) { recordDigest in
            try SealedPayload(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: currentScope.snapshotDigest,
                policyEpoch: 1,
                policyDigest: currentSigned.recordDigest,
                generationID: currentGeneration,
                formatVersion: 1,
                ciphertextBytes: Data([0x42])
            )
        }
        let currentRecipient = try addressed(digester) { recordDigest in
            try RecipientKeyEnvelope(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: currentScope.snapshotDigest,
                policyEpoch: 1,
                policyDigest: currentSigned.recordDigest,
                generationID: currentGeneration,
                recipientCredentialID: oldCredential.credentialID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x43])
            )
        }
        let currentRecoveryEnvelope = try addressed(digester) { recordDigest in
            try RecoveryEnvelope(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: currentScope.snapshotDigest,
                policyEpoch: 1,
                policyDigest: currentSigned.recordDigest,
                generationID: currentGeneration,
                recoveryRecipientID: currentRecovery.recoveryRecipientID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x44])
            )
        }
        let currentRecords = try SecretControlRecords(
            state: .committed,
            signedPolicy: currentSigned,
            sealedPayload: currentPayload,
            recipientEnvelopes: [currentRecipient],
            recoveryEnvelope: currentRecoveryEnvelope,
            purgeRequirements: [],
            purgeReceipts: [],
            recoveryAuthorization: nil
        )
        let currentCommit = try addressed(digester) { recordDigest in
            try SecretTransitionCommit(
                recordDigest: recordDigest,
                scopeID: scopeID,
                policyEpoch: 1,
                predecessorCommitDigest: nil,
                policyDigest: currentSigned.recordDigest,
                scopeSnapshotDigest: currentScope.snapshotDigest,
                generationID: currentGeneration,
                sealedPayloadDigest: currentPayload.recordDigest,
                recipientEnvelopeDigests: [currentRecipient.recordDigest],
                recoveryEnvelopeDigest: currentRecoveryEnvelope.recordDigest,
                purgeRequirementDigests: [],
                purgeReceiptDigests: [],
                recoveryAuthorizationDigest: nil,
                signerCredentialID: oldCredential.credentialID,
                signature: Data([0x45])
            )
        }
        let currentSnapshot = try SecretControlSnapshot(
            commit: currentCommit,
            records: currentRecords,
            trustedDeviceRecords: [currentTrust]
        )

        let challenge = try FullLossRecoveryChallenge(
            requestID: fixtureUUID(410),
            challengeID: fixtureUUID(411),
            sessionID: fixtureUUID(412),
            nonce: Data(repeating: 0x51, count: 16),
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        )
        let replacement = try recoveryCredential(challenge: challenge)
        let replacementCredentialDigest = try digester.digest(
            canonicalBytes: replacement.canonicalBytes()
        )
        let revokedOldTrust = try addressed(digester) { recordDigest in
            try DeviceTrustRecord(
                recordDigest: recordDigest,
                credentialDigest: oldCredentialDigest,
                deviceID: oldCredential.deviceID,
                credentialID: oldCredential.credentialID,
                trustState: .revoked,
                effectivePolicyEpoch: 2
            )
        }
        let replacementTrust = try addressed(digester) { recordDigest in
            try DeviceTrustRecord(
                recordDigest: recordDigest,
                credentialDigest: replacementCredentialDigest,
                deviceID: replacement.deviceID,
                credentialID: replacement.credentialID,
                trustState: .trusted,
                effectivePolicyEpoch: 2
            )
        }
        let candidateRecovery = try recoveryDescriptor(
            id: 413,
            agreementByte: 0x61,
            signingByte: 0x62
        )
        let candidateGeneration = SecretGenerationID(fixtureUUID(414))
        let candidateScope = try addressed(digester) { snapshotDigest in
            try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: fixtureUUID(406),
                memberRecordIDs: [fixtureUUID(406)],
                snapshotDigest: snapshotDigest
            )
        }
        let candidatePolicy = try SecretPolicyEpoch(
            epoch: 2,
            predecessorPolicyDigest: currentSigned.recordDigest,
            scopeSnapshot: candidateScope,
            generationID: candidateGeneration,
            authorizedRecipientCredentialIDs: [replacement.credentialID],
            trustedDeviceRecordDigests: [
                revokedOldTrust.recordDigest,
                replacementTrust.recordDigest,
            ],
            recoveryRecipient: candidateRecovery,
            signerCredentialID: replacement.credentialID
        )
        let candidateSigned = try addressed(digester) { recordDigest in
            try SignedSecretPolicyEpoch(
                recordDigest: recordDigest,
                policy: candidatePolicy,
                signature: Data([0x71])
            )
        }
        let candidatePayload = try addressed(digester) { recordDigest in
            try SealedPayload(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: candidateScope.snapshotDigest,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                generationID: candidateGeneration,
                formatVersion: 1,
                ciphertextBytes: Data([0x72])
            )
        }
        let candidateRecipient = try addressed(digester) { recordDigest in
            try RecipientKeyEnvelope(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: candidateScope.snapshotDigest,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                generationID: candidateGeneration,
                recipientCredentialID: replacement.credentialID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x73])
            )
        }
        let candidateRecoveryEnvelope = try addressed(digester) { recordDigest in
            try RecoveryEnvelope(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: candidateScope.snapshotDigest,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                generationID: candidateGeneration,
                recoveryRecipientID: candidateRecovery.recoveryRecipientID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x74])
            )
        }
        let purge = try addressed(digester) { recordDigest in
            try PurgeRequirement(
                recordDigest: recordDigest,
                scopeID: scopeID,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                supersededGenerationID: currentGeneration,
                replacementGenerationID: candidateGeneration,
                targetCredentialID: oldCredential.credentialID,
                requiredCategories: [.plaintext]
            )
        }
        let semantics = try FullLossRecoveryCandidateSemantics(
            scopeSnapshotDigest: candidateScope.snapshotDigest,
            signedPolicyDigest: candidateSigned.recordDigest,
            sealedPayloadDigest: candidatePayload.recordDigest,
            recipientEnvelopeDigests: [candidateRecipient.recordDigest],
            recoveryEnvelopeDigest: candidateRecoveryEnvelope.recordDigest,
            purgeRequirementDigests: [purge.recordDigest],
            purgeReceiptDigests: [],
            credentialDigests: [oldCredentialDigest, replacementCredentialDigest],
            trustRecordDigests: [
                revokedOldTrust.recordDigest,
                replacementTrust.recordDigest,
            ]
        )
        let intent = try GlobalRecoveryTransitionIntent(
            appNamespace: appNamespace,
            estateID: estateID,
            scopeID: scopeID,
            challenge: challenge,
            warning: FullLossRecoveryWarningAcknowledgement(
                acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
            ),
            currentCommitDigest: currentCommit.recordDigest,
            currentPolicyDigest: currentSigned.recordDigest,
            currentPolicyEpoch: 1,
            currentGenerationID: currentGeneration,
            currentRecoveryRecipient: currentRecovery,
            replacementDeviceID: replacement.deviceID,
            replacementCredentialID: replacement.credentialID,
            replacementSigningPublicKey: replacement.signingPublicKey,
            replacementAgreementPublicKey: replacement.keyAgreementPublicKey,
            signingPossessionProof: Data([0x52]),
            agreementPossessionProof: Data([0x53]),
            candidatePolicyEpoch: 2,
            candidateGenerationID: candidateGeneration,
            candidateSignedPolicyDigest: candidateSigned.recordDigest,
            replacementRecoveryRecipient: candidateRecovery,
            recoveryEnvelopeDigest: candidateRecoveryEnvelope.recordDigest,
            candidateSemantics: semantics
        )
        let authorization = try addressed(digester) { recordDigest in
            try FullLossRecoveryAuthorization(
                recordDigest: recordDigest,
                intent: intent,
                signature: Data([0x54])
            )
        }
        let staged = try SecretControlRecords(
            state: .staged,
            signedPolicy: candidateSigned,
            sealedPayload: candidatePayload,
            recipientEnvelopes: [candidateRecipient],
            recoveryEnvelope: candidateRecoveryEnvelope,
            purgeRequirements: [purge],
            purgeReceipts: [],
            recoveryAuthorization: authorization
        )
        let commit = try addressed(digester) { recordDigest in
            try SecretTransitionCommit(
                recordDigest: recordDigest,
                scopeID: scopeID,
                policyEpoch: 2,
                predecessorCommitDigest: currentCommit.recordDigest,
                policyDigest: candidateSigned.recordDigest,
                scopeSnapshotDigest: candidateScope.snapshotDigest,
                generationID: candidateGeneration,
                sealedPayloadDigest: candidatePayload.recordDigest,
                recipientEnvelopeDigests: [candidateRecipient.recordDigest],
                recoveryEnvelopeDigest: candidateRecoveryEnvelope.recordDigest,
                purgeRequirementDigests: [purge.recordDigest],
                purgeReceiptDigests: [],
                recoveryAuthorizationDigest: authorization.recordDigest,
                signerCredentialID: replacement.credentialID,
                signature: Data([0x75])
            )
        }
        let prepared = try RecoveryPreparedTransition(
            commit: commit,
            records: staged,
            credentials: [oldCredential, replacement],
            trustRecords: [revokedOldTrust, replacementTrust],
            digester: digester
        )
        return try FullLossFixture(
            currentSnapshot: currentSnapshot,
            prepared: prepared,
            externalFreshness: SecretBootstrapFreshnessCommitment(
                scopeID: scopeID,
                latestPolicyEpoch: 1,
                headCommitDigest: currentCommit.recordDigest,
                policyDigest: currentSigned.recordDigest
            ),
            oldCredentialID: oldCredential.credentialID,
            replacementCredentialID: replacement.credentialID,
            currentRecoveryKey: currentRecovery.authorizationSigningPublicKey,
            candidateRecoveryKey: candidateRecovery.authorizationSigningPublicKey
        )
    }

    func validate(
        nowMilliseconds: UInt64 = 1_500,
        knownCompetingChildDigests: [SecretRecordDigest] = [],
        recoveryVerifier: RecoveryAuthorityVerifier? = nil
    ) throws -> SecretControlSnapshot {
        try SecretPolicyValidator.validateFullLossRecoveryTransition(
            currentSnapshot: currentSnapshot,
            preparedTransition: prepared,
            knownCompetingChildDigests: knownCompetingChildDigests,
            externalFreshness: externalFreshness,
            appNamespace: Self.appNamespace,
            estateID: Self.estateID,
            nowMilliseconds: nowMilliseconds,
            digester: RecoveryAuthorityDigester(),
            signatureVerifier: ReplacementSignatureVerifier(),
            recoveryVerifier: recoveryVerifier
                ?? RecoveryAuthorityVerifier(
                    expectedAuthorizationKey: currentRecoveryKey,
                    acceptSigningPossession: true,
                    acceptAgreementPossession: true
                )
        )
    }
}

private func normalCredential(
    device: Int,
    credential: Int,
    byte: UInt8
) throws -> TrustedDeviceCredential {
    try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(fixtureUUID(device)),
        credentialID: DeviceCredentialID(fixtureUUID(credential)),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([byte]),
            publicKeyBytes: Data([0x04]) + Data(repeating: byte, count: 64)
        ),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([byte &+ 1]),
            publicKeyBytes: Data([0x04])
                + Data(repeating: byte &+ 1, count: 64)
        ),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: fixtureUUID(credential + 100),
            challengeBytes: Data([byte &+ 2]),
            signingProofBytes: Data([byte &+ 3]),
            keyAgreementProofBytes: Data([byte &+ 4]),
            provenance: .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: DeviceCredentialID(fixtureUUID(499)),
                    signature: Data([byte &+ 5])
                )
            )
        )
    )
}

private func recoveryCredential(
    challenge: FullLossRecoveryChallenge
) throws -> TrustedDeviceCredential {
    try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(fixtureUUID(415)),
        credentialID: DeviceCredentialID(fixtureUUID(416)),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x57]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x58, count: 64)
        ),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x59]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x5A, count: 64)
        ),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: challenge.challengeID,
            challengeBytes: challenge.nonce,
            signingProofBytes: Data([0x52]),
            keyAgreementProofBytes: Data([0x53]),
            provenance: .globalRecovery(
                GlobalRecoveryEnrollmentAuthority(
                    requestID: challenge.requestID,
                    recoveryRecipientID: fixtureUUID(404)
                )
            )
        )
    )
}

private func recoveryDescriptor(
    id: Int,
    agreementByte: UInt8,
    signingByte: UInt8
) throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
        recoveryRecipientID: fixtureUUID(id),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .agreementAlgorithmIdentifier,
            keyIdentifier: Data([agreementByte]),
            publicKeyBytes: Data([0x04])
                + Data(repeating: agreementByte, count: 64)
        ),
        authorizationSigningPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .authorizationSigningAlgorithmIdentifier,
            keyIdentifier: Data([signingByte]),
            publicKeyBytes: Data([0x04])
                + Data(repeating: signingByte, count: 64)
        )
    )
}

private func addressed<T: SecretSyncCanonicalEncodable>(
    _ digester: RecoveryAuthorityDigester,
    build: (SecretRecordDigest) throws -> T
) throws -> T {
    let zero = try digest(0)
    let provisional = try build(zero)
    return try build(
        digester.digest(canonicalBytes: provisional.canonicalBytes())
    )
}

private struct RecoveryAuthorityDigester: SecretSyncDigesting {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        var bytes = [UInt8](repeating: 0, count: SecretRecordDigest.byteCount)
        for (index, byte) in canonicalBytes.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return try SecretRecordDigest(bytes: Data(bytes))
    }
}

private struct ReplacementSignatureVerifier: SecretSignatureVerifying {
    func verify(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool {
        (signature == Data([0x71]) || signature == Data([0x75]))
            && !canonicalBytes.isEmpty
            && signingPublicKey.keyIdentifier == Data([0x57])
    }
}

private struct RecoveryAuthorityVerifier: FullLossRecoveryProofVerifying {
    let expectedAuthorizationKey: SigningPublicKeyDescriptor
    let acceptSigningPossession: Bool
    let acceptAgreementPossession: Bool

    func verifyRecoveryAuthorization(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool {
        signature == Data([0x54])
            && !canonicalBytes.isEmpty
            && signingPublicKey == expectedAuthorizationKey
    }

    func verifyReplacementSigningPossession(
        proof: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool {
        acceptSigningPossession
            && proof == Data([0x52])
            && !canonicalBytes.isEmpty
            && signingPublicKey.keyIdentifier == Data([0x57])
    }

    func verifyReplacementAgreementPossession(
        proof: Data,
        canonicalBytes: Data,
        agreementPublicKey: KeyAgreementPublicKeyDescriptor
    ) throws -> Bool {
        acceptAgreementPossession
            && proof == Data([0x53])
            && !canonicalBytes.isEmpty
            && agreementPublicKey.keyIdentifier == Data([0x59])
    }
}

private func expectPolicyError(
    _ expected: SecretPolicyValidationError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected policy validation error")
    } catch let error as SecretPolicyValidationError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error")
    }
}

private func fixtureUUID(_ suffix: Int) -> UUID {
    UUID(
        uuidString: String(
            format: "A0000000-0000-0000-0000-%012d",
            suffix
        )
    )!
}

private func digest(_ byte: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(
        bytes: Data(repeating: byte, count: SecretRecordDigest.byteCount)
    )
}

private func expectRecoveryError(
    _ expected: FullLossRecoveryContractError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected recovery contract error")
    } catch let error as FullLossRecoveryContractError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error")
    }
}

private func decodeSequence(_ data: Data) throws -> [Data] {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { throw RecoveryAuthorityTestError.invalid }
    let count = Int(bytes[0]) << 8 | Int(bytes[1])
    var cursor = 2
    var result: [Data] = []
    result.reserveCapacity(count)
    for _ in 0..<count {
        guard cursor + 4 <= bytes.count else {
            throw RecoveryAuthorityTestError.invalid
        }
        let length = Int(bytes[cursor]) << 24
            | Int(bytes[cursor + 1]) << 16
            | Int(bytes[cursor + 2]) << 8
            | Int(bytes[cursor + 3])
        cursor += 4
        guard cursor + length <= bytes.count else {
            throw RecoveryAuthorityTestError.invalid
        }
        result.append(Data(bytes[cursor..<(cursor + length)]))
        cursor += length
    }
    guard cursor == bytes.count else { throw RecoveryAuthorityTestError.invalid }
    return result
}

private enum RecoveryAuthorityTestError: Error { case invalid }
