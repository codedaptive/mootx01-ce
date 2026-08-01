import Foundation
import CryptoKit
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

    @Test("recovery proof, intent, and candidate semantics have fixed vectors")
    func recoveryCanonicalVectorsAreFixed() throws {
        let fixture = try FullLossFixture.make()
        let authorization = try #require(
            fixture.prepared.entry.records.recoveryAuthorization
        )

        #expect(
            sha256Hex(
                try authorization.intent.candidateSemantics.canonicalBytes()
            ) == "096714a3d5ac30e8d139983b0be589c9f8edebc2a69a0e6297f6f4341a47443b"
        )
        #expect(
            sha256Hex(try authorization.intent.canonicalBytes())
                == "6ede9a5a69ac3d7c40d5639f690030b1d6511eaf230f7b6eeb9ded6b3b8466d8"
        )
        #expect(
            sha256Hex(try authorization.canonicalBytes())
                == "af4c81634e1b8dc9fc3fec2b6fc8d690d6ec12ed97dfff01e9dc71d5d03dacb5"
        )
    }

    @Test(
        "every intent transcript field changes the authorization input",
        arguments: (1...31).map(UInt16.init)
    )
    func everyIntentFieldIsBound(_ tag: UInt16) throws {
        let fixture = try FullLossFixture.make()
        let authorization = try #require(
            fixture.prepared.entry.records.recoveryAuthorization
        )
        let original = try authorization.intent.canonicalBytes()
        let mutated = try mutateCanonicalField(
            original,
            domain: .globalRecoveryTransitionIntent,
            tag: tag
        )

        #expect(mutated != original)
        #expect(sha256Hex(mutated) != sha256Hex(original))
    }

    @Test(
        "every candidate digest field changes the authorization input",
        arguments: (1...9).map(UInt16.init)
    )
    func everyCandidateDigestFieldIsBound(_ tag: UInt16) throws {
        let fixture = try FullLossFixture.make()
        let authorization = try #require(
            fixture.prepared.entry.records.recoveryAuthorization
        )
        let original = try authorization.intent.candidateSemantics
            .canonicalBytes()
        let mutated = try mutateCanonicalField(
            original,
            domain: .fullLossRecoveryCandidateSemantics,
            tag: tag
        )

        #expect(mutated != original)
        #expect(sha256Hex(mutated) != sha256Hex(original))
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
                    expectedSigningKey: fixture.replacementSigningKey,
                    expectedAgreementKey: fixture.replacementAgreementKey,
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
                    expectedSigningKey: fixture.replacementSigningKey,
                    expectedAgreementKey: fixture.replacementAgreementKey,
                    acceptSigningPossession: true,
                    acceptAgreementPossession: false
                )
            )
        }
    }

    @Test("each replacement-key possession proof rejects independently")
    func wrongPossessionProofsRejectIndependently() throws {
        let wrongSigning = try FullLossFixture.make(
            signingPossessionProof: Data([0x99])
        )
        expectPolicyError(.fullLossRecoveryProofRejected) {
            _ = try wrongSigning.validate()
        }

        let wrongAgreement = try FullLossFixture.make(
            agreementPossessionProof: Data([0x99])
        )
        expectPolicyError(.fullLossRecoveryProofRejected) {
            _ = try wrongAgreement.validate()
        }

        let substituted = try FullLossFixture.make(
            signingPossessionProof: Data([0x53]),
            agreementPossessionProof: Data([0x52])
        )
        expectPolicyError(.fullLossRecoveryProofRejected) {
            _ = try substituted.validate()
        }
    }

    @Test("replacement enrollment binds the exact recovery challenge nonce")
    func replacementEnrollmentRejectsWrongChallengeBytes() throws {
        let fixture = try FullLossFixture.make(
            enrollmentChallengeBytes: Data(repeating: 0x98, count: 16)
        )
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("empty replacement-key possession proofs cannot form an intent")
    func absentPossessionProofsRejectIndependently() {
        expectAnyRejection {
            _ = try FullLossFixture.make(signingPossessionProof: Data())
        }
        expectAnyRejection {
            _ = try FullLossFixture.make(agreementPossessionProof: Data())
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

    @Test("an accepted proof cannot replay after the head advances")
    func acceptedProofCannotReplayAfterCAS() throws {
        let fixture = try FullLossFixture.make()
        let accepted = try fixture.validate()
        expectPolicyError(.replayedHead) {
            _ = try fixture.validate(currentSnapshot: accepted)
        }
    }

    @Test(
        "full-loss graph rejects replacement, tombstone, envelope, and receipt drift",
        arguments: RecoveryGraphMutation.allCases
    )
    fileprivate func malformedRecoveryGraphsReject(
        _ mutation: RecoveryGraphMutation
    ) throws {
        expectAnyRejection {
            let fixture = try FullLossFixture.make(graphMutation: mutation)
            _ = try fixture.validate()
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

    @Test("full-loss recovery requires a fresh replacement device identifier")
    func replacementDeviceIdentifierMustBeFresh() throws {
        let fixture = try FullLossFixture.make(deviceReuse: .deviceID)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("full-loss recovery rejects a reused signing key")
    func replacementSigningKeyMustBeFresh() throws {
        let fixture = try FullLossFixture.make(deviceReuse: .signingKey)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("full-loss recovery rejects a reused agreement key")
    func replacementAgreementKeyMustBeFresh() throws {
        let fixture = try FullLossFixture.make(deviceReuse: .agreementKey)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("full-loss recovery rejects cross-role device key reuse")
    func replacementDeviceKeysMustNotCrossRoles() throws {
        let fixture = try FullLossFixture.make(
            deviceReuse: .signingFromPriorAgreement
        )
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("replacement recovery requires a fresh recipient identifier")
    func replacementRecoveryIdentifierMustBeFresh() throws {
        let fixture = try FullLossFixture.make(recoveryReuse: .recipientID)
        expectPolicyError(.fullLossRecoveryCandidateMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("replacement recovery rejects a reused agreement key")
    func replacementRecoveryAgreementKeyMustBeFresh() throws {
        let fixture = try FullLossFixture.make(recoveryReuse: .agreementKey)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("replacement recovery rejects a reused authorization key")
    func replacementRecoveryAuthorizationKeyMustBeFresh() throws {
        let fixture = try FullLossFixture.make(recoveryReuse: .authorizationKey)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("replacement recovery agreement keys cannot reuse authorization keys")
    func replacementRecoveryAgreementKeyMustNotCrossRoles() throws {
        let fixture = try FullLossFixture.make(
            recoveryReuse: .agreementFromPriorAuthorization
        )
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test("replacement recovery authorization keys cannot reuse agreement keys")
    func replacementRecoveryAuthorizationKeyMustNotCrossRoles() throws {
        let fixture = try FullLossFixture.make(
            recoveryReuse: .authorizationFromPriorAgreement
        )
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }

    @Test(
        "replacement key roles reject identifier and public-byte collisions",
        arguments: GlobalKeyCollision.allCases
    )
    fileprivate func replacementKeyRolesAreGloballyDistinct(
        _ collision: GlobalKeyCollision
    ) throws {
        let fixture = try FullLossFixture.make(keyCollision: collision)
        expectPolicyError(.fullLossRecoveryTrustMismatch) {
            _ = try fixture.validate()
        }
    }
}

private enum ReplacementCredentialReuse {
    case none
    case deviceID
    case signingKey
    case agreementKey
    case signingFromPriorAgreement
}

private enum ReplacementRecoveryReuse {
    case none
    case recipientID
    case agreementKey
    case authorizationKey
    case agreementFromPriorAuthorization
    case authorizationFromPriorAgreement
}

fileprivate enum GlobalKeyCollision: CaseIterable, Sendable {
    case deviceSigningIdentifierWithCurrentRecoveryAgreement
    case deviceSigningBytesWithCurrentRecoveryAuthorization
    case deviceAgreementIdentifierWithCurrentRecoveryAuthorization
    case deviceAgreementBytesWithCurrentRecoveryAgreement
    case recoveryAgreementIdentifierWithPriorDeviceSigning
    case recoveryAgreementBytesWithPriorDeviceAgreement
    case recoveryAuthorizationIdentifierWithPriorDeviceAgreement
    case recoveryAuthorizationBytesWithPriorDeviceSigning
    case recoveryAgreementIdentifierWithReplacementSigning
    case recoveryAgreementBytesWithReplacementSigning
    case recoveryAuthorizationIdentifierWithReplacementAgreement
    case recoveryAuthorizationBytesWithReplacementAgreement
}

fileprivate enum RecoveryGraphMutation: CaseIterable, Sendable {
    case zeroReplacements
    case twoReplacements
    case missingPriorTombstone
    case extraTombstone
    case survivingOldAuthority
    case survivingOldEnvelope
    case surrogateReceipt
    case reusedGeneration
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
    let replacementSigningKey: SigningPublicKeyDescriptor
    let replacementAgreementKey: KeyAgreementPublicKeyDescriptor

    static func make(
        deviceReuse: ReplacementCredentialReuse = .none,
        recoveryReuse: ReplacementRecoveryReuse = .none,
        keyCollision: GlobalKeyCollision? = nil,
        signingPossessionProof: Data = Data([0x52]),
        agreementPossessionProof: Data = Data([0x53]),
        enrollmentChallengeBytes: Data? = nil,
        graphMutation: RecoveryGraphMutation? = nil
    ) throws -> FullLossFixture {
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
        let replacement = try recoveryCredential(
            challenge: challenge,
            priorCredential: oldCredential,
            currentRecovery: currentRecovery,
            reuse: deviceReuse,
            keyCollision: keyCollision,
            signingPossessionProof: signingPossessionProof,
            agreementPossessionProof: agreementPossessionProof,
            enrollmentChallengeBytes: enrollmentChallengeBytes
        )
        let replacementCredentialDigest = try digester.digest(
            canonicalBytes: replacement.canonicalBytes()
        )
        let candidateOldTrust = try addressed(digester) { recordDigest in
            try DeviceTrustRecord(
                recordDigest: recordDigest,
                credentialDigest: oldCredentialDigest,
                deviceID: oldCredential.deviceID,
                credentialID: oldCredential.credentialID,
                trustState: graphMutation == .survivingOldAuthority
                    ? .trusted
                    : .revoked,
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
        let extraCredential = try normalCredential(
            device: 417,
            credential: 418,
            byte: 0x81
        )
        let extraCredentialDigest = try digester.digest(
            canonicalBytes: extraCredential.canonicalBytes()
        )
        let extraTrust = try addressed(digester) { recordDigest in
            try DeviceTrustRecord(
                recordDigest: recordDigest,
                credentialDigest: extraCredentialDigest,
                deviceID: extraCredential.deviceID,
                credentialID: extraCredential.credentialID,
                trustState: graphMutation == .extraTombstone
                    ? .revoked
                    : .trusted,
                effectivePolicyEpoch: 2
            )
        }
        var candidateCredentials = [oldCredential]
        var candidateTrustRecords: [DeviceTrustRecord] = []
        if graphMutation != .missingPriorTombstone {
            candidateTrustRecords.append(candidateOldTrust)
        }
        if graphMutation != .zeroReplacements {
            candidateCredentials.append(replacement)
            candidateTrustRecords.append(replacementTrust)
        }
        if graphMutation == .twoReplacements
            || graphMutation == .extraTombstone
        {
            candidateCredentials.append(extraCredential)
            candidateTrustRecords.append(extraTrust)
        }
        let candidateRecovery = try replacementRecoveryDescriptor(
            current: currentRecovery,
            priorCredential: oldCredential,
            replacementCredential: replacement,
            reuse: recoveryReuse,
            keyCollision: keyCollision
        )
        let candidateGeneration = graphMutation == .reusedGeneration
            ? currentGeneration
            : SecretGenerationID(fixtureUUID(414))
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
            trustedDeviceRecordDigests: candidateTrustRecords.map(\.recordDigest),
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
        let survivingOldRecipient = try addressed(digester) { recordDigest in
            try RecipientKeyEnvelope(
                recordDigest: recordDigest,
                scopeID: scopeID,
                scopeSnapshotDigest: candidateScope.snapshotDigest,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                generationID: candidateGeneration,
                recipientCredentialID: oldCredential.credentialID,
                formatVersion: 1,
                wrappedKeyBytes: Data([0x76])
            )
        }
        let candidateRecipients = graphMutation == .survivingOldEnvelope
            ? [candidateRecipient, survivingOldRecipient]
            : [candidateRecipient]
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
        let surrogateReceipt = try addressed(digester) { recordDigest in
            try PurgeReceipt(
                recordDigest: recordDigest,
                requirementDigest: purge.recordDigest,
                scopeID: scopeID,
                policyEpoch: 2,
                policyDigest: candidateSigned.recordDigest,
                supersededGenerationID: currentGeneration,
                replacementGenerationID: candidateGeneration,
                respondingCredentialID: replacement.credentialID,
                coveredCategories: [.plaintext],
                status: .completed,
                signerCredentialID: replacement.credentialID,
                signature: Data([0x77])
            )
        }
        let candidateReceipts = graphMutation == .surrogateReceipt
            ? [surrogateReceipt]
            : []
        let candidateCredentialDigests = try candidateCredentials.map {
            try digester.digest(canonicalBytes: $0.canonicalBytes())
        }
        let semantics = try FullLossRecoveryCandidateSemantics(
            scopeSnapshotDigest: candidateScope.snapshotDigest,
            signedPolicyDigest: candidateSigned.recordDigest,
            sealedPayloadDigest: candidatePayload.recordDigest,
            recipientEnvelopeDigests: candidateRecipients.map(\.recordDigest),
            recoveryEnvelopeDigest: candidateRecoveryEnvelope.recordDigest,
            purgeRequirementDigests: [purge.recordDigest],
            purgeReceiptDigests: candidateReceipts.map(\.recordDigest),
            credentialDigests: candidateCredentialDigests,
            trustRecordDigests: candidateTrustRecords.map(\.recordDigest)
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
            signingPossessionProof: signingPossessionProof,
            agreementPossessionProof: agreementPossessionProof,
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
            recipientEnvelopes: candidateRecipients,
            recoveryEnvelope: candidateRecoveryEnvelope,
            purgeRequirements: [purge],
            purgeReceipts: candidateReceipts,
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
                recipientEnvelopeDigests: candidateRecipients.map(\.recordDigest),
                recoveryEnvelopeDigest: candidateRecoveryEnvelope.recordDigest,
                purgeRequirementDigests: [purge.recordDigest],
                purgeReceiptDigests: candidateReceipts.map(\.recordDigest),
                recoveryAuthorizationDigest: authorization.recordDigest,
                signerCredentialID: replacement.credentialID,
                signature: Data([0x75])
            )
        }
        let prepared = try RecoveryPreparedTransition(
            commit: commit,
            records: staged,
            credentials: candidateCredentials,
            trustRecords: candidateTrustRecords,
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
            candidateRecoveryKey: candidateRecovery.authorizationSigningPublicKey,
            replacementSigningKey: replacement.signingPublicKey,
            replacementAgreementKey: replacement.keyAgreementPublicKey
        )
    }

    func validate(
        nowMilliseconds: UInt64 = 1_500,
        knownCompetingChildDigests: [SecretRecordDigest] = [],
        currentSnapshot: SecretControlSnapshot? = nil,
        recoveryVerifier: RecoveryAuthorityVerifier? = nil
    ) throws -> SecretControlSnapshot {
        try SecretPolicyValidator.validateFullLossRecoveryTransition(
            currentSnapshot: currentSnapshot ?? self.currentSnapshot,
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
                    expectedSigningKey: replacementSigningKey,
                    expectedAgreementKey: replacementAgreementKey,
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
    challenge: FullLossRecoveryChallenge,
    priorCredential: TrustedDeviceCredential,
    currentRecovery: RecoveryRecipientDescriptor,
    reuse: ReplacementCredentialReuse,
    keyCollision: GlobalKeyCollision?,
    signingPossessionProof: Data,
    agreementPossessionProof: Data,
    enrollmentChallengeBytes: Data?
) throws -> TrustedDeviceCredential {
    let deviceID = reuse == .deviceID
        ? priorCredential.deviceID
        : TrustedDeviceID(fixtureUUID(415))
    var signingPublicKey: SigningPublicKeyDescriptor
    switch reuse {
    case .signingKey:
        signingPublicKey = priorCredential.signingPublicKey
    case .signingFromPriorAgreement:
        signingPublicKey = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: priorCredential.keyAgreementPublicKey.keyIdentifier,
            publicKeyBytes: priorCredential.keyAgreementPublicKey.publicKeyBytes
        )
    case .none, .deviceID, .agreementKey:
        signingPublicKey = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x57]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x58, count: 64)
        )
    }
    var agreementPublicKey = try reuse == .agreementKey
        ? priorCredential.keyAgreementPublicKey
        : KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x59]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x5A, count: 64)
        )
    switch keyCollision {
    case .deviceSigningIdentifierWithCurrentRecoveryAgreement:
        signingPublicKey = try signingDescriptor(
            basedOn: signingPublicKey,
            keyIdentifier: currentRecovery.keyAgreementPublicKey.keyIdentifier
        )
    case .deviceSigningBytesWithCurrentRecoveryAuthorization:
        signingPublicKey = try signingDescriptor(
            basedOn: signingPublicKey,
            publicKeyBytes: currentRecovery.authorizationSigningPublicKey
                .publicKeyBytes
        )
    case .deviceAgreementIdentifierWithCurrentRecoveryAuthorization:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            keyIdentifier: currentRecovery.authorizationSigningPublicKey
                .keyIdentifier
        )
    case .deviceAgreementBytesWithCurrentRecoveryAgreement:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            publicKeyBytes: currentRecovery.keyAgreementPublicKey.publicKeyBytes
        )
    case .none, .recoveryAgreementIdentifierWithPriorDeviceSigning,
            .recoveryAgreementBytesWithPriorDeviceAgreement,
            .recoveryAuthorizationIdentifierWithPriorDeviceAgreement,
            .recoveryAuthorizationBytesWithPriorDeviceSigning,
            .recoveryAgreementIdentifierWithReplacementSigning,
            .recoveryAgreementBytesWithReplacementSigning,
            .recoveryAuthorizationIdentifierWithReplacementAgreement,
            .recoveryAuthorizationBytesWithReplacementAgreement:
        break
    }
    return try TrustedDeviceCredential(
        deviceID: deviceID,
        credentialID: DeviceCredentialID(fixtureUUID(416)),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: signingPublicKey,
        keyAgreementPublicKey: agreementPublicKey,
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: challenge.challengeID,
            challengeBytes: enrollmentChallengeBytes ?? challenge.nonce,
            signingProofBytes: signingPossessionProof,
            keyAgreementProofBytes: agreementPossessionProof,
            provenance: .globalRecovery(
                GlobalRecoveryEnrollmentAuthority(
                    requestID: challenge.requestID,
                    recoveryRecipientID: fixtureUUID(404)
                )
            )
        )
    )
}

private func replacementRecoveryDescriptor(
    current: RecoveryRecipientDescriptor,
    priorCredential: TrustedDeviceCredential,
    replacementCredential: TrustedDeviceCredential,
    reuse: ReplacementRecoveryReuse,
    keyCollision: GlobalKeyCollision?
) throws -> RecoveryRecipientDescriptor {
    let recipientID = reuse == .recipientID
        ? current.recoveryRecipientID
        : fixtureUUID(413)
    var agreementPublicKey: KeyAgreementPublicKeyDescriptor
    switch reuse {
    case .agreementKey:
        agreementPublicKey = current.keyAgreementPublicKey
    case .agreementFromPriorAuthorization:
        agreementPublicKey = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .agreementAlgorithmIdentifier,
            keyIdentifier: current.authorizationSigningPublicKey.keyIdentifier,
            publicKeyBytes: current.authorizationSigningPublicKey.publicKeyBytes
        )
    case .none, .recipientID, .authorizationKey,
            .authorizationFromPriorAgreement:
        agreementPublicKey = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .agreementAlgorithmIdentifier,
            keyIdentifier: Data([0x61]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x61, count: 64)
        )
    }
    var authorizationPublicKey: SigningPublicKeyDescriptor
    switch reuse {
    case .authorizationKey:
        authorizationPublicKey = current.authorizationSigningPublicKey
    case .authorizationFromPriorAgreement:
        authorizationPublicKey = try SigningPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .authorizationSigningAlgorithmIdentifier,
            keyIdentifier: current.keyAgreementPublicKey.keyIdentifier,
            publicKeyBytes: current.keyAgreementPublicKey.publicKeyBytes
        )
    case .none, .recipientID, .agreementKey,
            .agreementFromPriorAuthorization:
        authorizationPublicKey = try SigningPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .authorizationSigningAlgorithmIdentifier,
            keyIdentifier: Data([0x62]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x62, count: 64)
        )
    }
    switch keyCollision {
    case .recoveryAgreementIdentifierWithPriorDeviceSigning:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            keyIdentifier: priorCredential.signingPublicKey.keyIdentifier
        )
    case .recoveryAgreementBytesWithPriorDeviceAgreement:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            publicKeyBytes: priorCredential.keyAgreementPublicKey.publicKeyBytes
        )
    case .recoveryAuthorizationIdentifierWithPriorDeviceAgreement:
        authorizationPublicKey = try signingDescriptor(
            basedOn: authorizationPublicKey,
            keyIdentifier: priorCredential.keyAgreementPublicKey.keyIdentifier
        )
    case .recoveryAuthorizationBytesWithPriorDeviceSigning:
        authorizationPublicKey = try signingDescriptor(
            basedOn: authorizationPublicKey,
            publicKeyBytes: priorCredential.signingPublicKey.publicKeyBytes
        )
    case .recoveryAgreementIdentifierWithReplacementSigning:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            keyIdentifier: replacementCredential.signingPublicKey.keyIdentifier
        )
    case .recoveryAgreementBytesWithReplacementSigning:
        agreementPublicKey = try agreementDescriptor(
            basedOn: agreementPublicKey,
            publicKeyBytes: replacementCredential.signingPublicKey.publicKeyBytes
        )
    case .recoveryAuthorizationIdentifierWithReplacementAgreement:
        authorizationPublicKey = try signingDescriptor(
            basedOn: authorizationPublicKey,
            keyIdentifier: replacementCredential.keyAgreementPublicKey
                .keyIdentifier
        )
    case .recoveryAuthorizationBytesWithReplacementAgreement:
        authorizationPublicKey = try signingDescriptor(
            basedOn: authorizationPublicKey,
            publicKeyBytes: replacementCredential.keyAgreementPublicKey
                .publicKeyBytes
        )
    case .none, .deviceSigningIdentifierWithCurrentRecoveryAgreement,
            .deviceSigningBytesWithCurrentRecoveryAuthorization,
            .deviceAgreementIdentifierWithCurrentRecoveryAuthorization,
            .deviceAgreementBytesWithCurrentRecoveryAgreement:
        break
    }
    return try RecoveryRecipientDescriptor(
        recoveryRecipientID: recipientID,
        keyAgreementPublicKey: agreementPublicKey,
        authorizationSigningPublicKey: authorizationPublicKey
    )
}

private func signingDescriptor(
    basedOn descriptor: SigningPublicKeyDescriptor,
    keyIdentifier: Data? = nil,
    publicKeyBytes: Data? = nil
) throws -> SigningPublicKeyDescriptor {
    try SigningPublicKeyDescriptor(
        algorithmIdentifier: descriptor.algorithmIdentifier,
        keyIdentifier: keyIdentifier ?? descriptor.keyIdentifier,
        publicKeyBytes: publicKeyBytes ?? descriptor.publicKeyBytes
    )
}

private func agreementDescriptor(
    basedOn descriptor: KeyAgreementPublicKeyDescriptor,
    keyIdentifier: Data? = nil,
    publicKeyBytes: Data? = nil
) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: descriptor.algorithmIdentifier,
        keyIdentifier: keyIdentifier ?? descriptor.keyIdentifier,
        publicKeyBytes: publicKeyBytes ?? descriptor.publicKeyBytes
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
    let expectedSigningKey: SigningPublicKeyDescriptor
    let expectedAgreementKey: KeyAgreementPublicKeyDescriptor
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
            && signingPublicKey == expectedSigningKey
    }

    func verifyReplacementAgreementPossession(
        proof: Data,
        canonicalBytes: Data,
        agreementPublicKey: KeyAgreementPublicKeyDescriptor
    ) throws -> Bool {
        acceptAgreementPossession
            && proof == Data([0x53])
            && !canonicalBytes.isEmpty
            && agreementPublicKey == expectedAgreementKey
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

private func expectAnyRejection(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected fail-closed rejection")
    } catch {
        // Construction, store-integrity, and policy-admission guards are all
        // valid fail-closed boundaries for malformed recovery graphs.
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mutateCanonicalField(
    _ canonicalBytes: Data,
    domain: SecretSyncCanonicalDomain,
    tag: UInt16
) throws -> Data {
    let document = try SecretSyncCanonicalEncoding.decode(
        canonicalBytes,
        expectedDomain: domain
    )
    let fields = try document.fields.map { field -> SecretSyncCanonicalField in
        guard field.tag == tag else { return field }
        guard !field.value.isEmpty else {
            throw RecoveryAuthorityTestError.invalid
        }
        var value = field.value
        value[value.startIndex] ^= 0x01
        return SecretSyncCanonicalField(tag: field.tag, value: value)
    }
    guard fields.contains(where: { $0.tag == tag }) else {
        throw RecoveryAuthorityTestError.invalid
    }
    return try SecretSyncCanonicalEncoding.encode(domain: domain, fields: fields)
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
