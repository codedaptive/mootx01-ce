import Foundation
import Testing
@testable import ConvergenceKit

@Suite("SecretSync contract")
struct SecretSyncContractTests {
    @Test("stable security identifiers round-trip without HLC slot vocabulary")
    func stableIdentifiersRoundTrip() throws {
        let deviceID = TrustedDeviceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let credentialID = DeviceCredentialID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let scopeID = SecretScopeID(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        let generationID = SecretGenerationID(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)

        let encoded = try JSONEncoder().encode([deviceID.rawValue, credentialID.rawValue, scopeID.rawValue, generationID.rawValue])
        let decoded = try JSONDecoder().decode([UUID].self, from: encoded)

        #expect(decoded == [deviceID.rawValue, credentialID.rawValue, scopeID.rawValue, generationID.rawValue])
    }

    @Test("signing and key-agreement roles are distinct and cannot reuse one key")
    func credentialKeyRolesAreDistinct() throws {
        let signing = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "opaque-signature-suite",
            keyIdentifier: Data([0x01]),
            publicKeyBytes: Data([0x10, 0x11])
        )
        let agreement = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-agreement-suite",
            keyIdentifier: Data([0x02]),
            publicKeyBytes: Data([0x20, 0x21])
        )
        let proof = try DeviceCredentialEnrollmentProof(
            challengeID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            challengeBytes: Data([0x30]),
            signingProofBytes: Data([0x31]),
            keyAgreementProofBytes: Data([0x32]),
            authorityCredentialID: DeviceCredentialID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
            authoritySignature: Data([0x33])
        )

        let credential = try TrustedDeviceCredential(
            deviceID: TrustedDeviceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            credentialID: DeviceCredentialID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!),
            credentialVersion: 1,
            status: .active,
            signingPublicKey: signing,
            keyAgreementPublicKey: agreement,
            enrollmentProof: proof
        )

        #expect(credential.signingPublicKey.keyIdentifier == Data([0x01]))
        #expect(credential.keyAgreementPublicKey.keyIdentifier == Data([0x02]))

        let reusedAgreement = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-agreement-suite",
            keyIdentifier: signing.keyIdentifier,
            publicKeyBytes: signing.publicKeyBytes
        )
        expectContractError(.keyRoleReuse) {
            _ = try TrustedDeviceCredential(
                deviceID: credential.deviceID,
                credentialID: credential.credentialID,
                credentialVersion: 1,
                status: .active,
                signingPublicKey: signing,
                keyAgreementPublicKey: reusedAgreement,
                enrollmentProof: proof
            )
        }
    }

    @Test("opaque record digests are exactly 32 bytes")
    func digestWidthIsFixed() throws {
        let bytes = Data(repeating: 0xAB, count: SecretRecordDigest.byteCount)
        let digest = try SecretRecordDigest(bytes: bytes)
        #expect(digest.bytes == bytes)

        expectContractError(.invalidDigestLength(actual: 31)) {
            _ = try SecretRecordDigest(bytes: Data(repeating: 0xAB, count: 31))
        }
    }

    @Test("canonical fields are sorted and the golden frame is stable")
    func canonicalGoldenFrame() throws {
        let first = SecretSyncCanonicalField(tag: 1, value: Data([0xAA]))
        let second = SecretSyncCanonicalField(tag: 2, value: Data([0xBB]))

        let ascending = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [first, second]
        )
        let descending = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [second, first]
        )
        #expect(ascending == descending)

        let oneField = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [first]
        )
        #expect(
            oneField.hexString
                == "53534350000100257365637265742d73796e632f747275737465642d6465766963652d63726564656e7469616c0001000100000001aa"
        )

        let decoded = try SecretSyncCanonicalEncoding.decode(
            ascending,
            expectedDomain: .trustedDeviceCredential
        )
        #expect(decoded.fields.map(\.tag) == [1, 2])
        #expect(decoded.fields.map(\.value) == [Data([0xAA]), Data([0xBB])])
    }

    @Test("canonical framing rejects ambiguity and malformed input")
    func canonicalFramingFailsClosed() throws {
        let field = SecretSyncCanonicalField(tag: 1, value: Data([0xAA]))
        let valid = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [field]
        )

        expectContractError(.duplicateField(tag: 1)) {
            _ = try SecretSyncCanonicalEncoding.encode(
                domain: .trustedDeviceCredential,
                fields: [field, field]
            )
        }
        expectContractError(.domainMismatch) {
            _ = try SecretSyncCanonicalEncoding.decode(valid, expectedDomain: .secretPolicyEpoch)
        }

        var unknownVersion = valid
        unknownVersion[5] = 0x02
        expectContractError(.unsupportedSchemaVersion(2)) {
            _ = try SecretSyncCanonicalEncoding.decode(
                unknownVersion,
                expectedDomain: .trustedDeviceCredential
            )
        }

        expectContractError(.truncatedCanonicalBytes) {
            _ = try SecretSyncCanonicalEncoding.decode(
                Data(valid.dropLast()),
                expectedDomain: .trustedDeviceCredential
            )
        }

        var trailing = valid
        trailing.append(0)
        expectContractError(.trailingCanonicalBytes) {
            _ = try SecretSyncCanonicalEncoding.decode(
                trailing,
                expectedDomain: .trustedDeviceCredential
            )
        }

        expectContractError(.fieldTooLarge) {
            _ = try SecretSyncCanonicalEncoding.encode(
                domain: .trustedDeviceCredential,
                fields: [
                    SecretSyncCanonicalField(
                        tag: 1,
                        value: Data(
                            repeating: 0,
                            count: SecretSyncCanonicalEncoding.maximumFieldByteCount + 1
                        )
                    ),
                ]
            )
        }
    }

    @Test("scope snapshots and recipient sets are exact, sorted, and duplicate-free")
    func exactScopeAndRecipientSnapshots() throws {
        let memberA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let memberB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let snapshotDigest = try digest(0x40)
        let forward = try SecretScopeSnapshot(
            scopeID: scopeID,
            rootRecordID: rootRecordID,
            memberRecordIDs: [memberA, memberB],
            snapshotDigest: snapshotDigest
        )
        let reverse = try SecretScopeSnapshot(
            scopeID: scopeID,
            rootRecordID: rootRecordID,
            memberRecordIDs: [memberB, memberA],
            snapshotDigest: snapshotDigest
        )

        #expect(forward.memberRecordIDs == [memberA, memberB])
        #expect(try forward.canonicalBytes() == reverse.canonicalBytes())

        expectContractError(.duplicateIdentifier(field: "memberRecordIDs")) {
            _ = try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: rootRecordID,
                memberRecordIDs: [memberA, memberA],
                snapshotDigest: snapshotDigest
            )
        }
        expectContractError(.emptySet(field: "memberRecordIDs")) {
            _ = try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: rootRecordID,
                memberRecordIDs: [],
                snapshotDigest: snapshotDigest
            )
        }
    }

    @Test("policy epochs are monotonic immutable snapshots with recovery separated")
    func immutablePolicyEpochs() throws {
        let snapshot = try scopeSnapshot()
        let recipientA = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let recipientB = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let recovery = try recoveryRecipient()
        let predecessor = try digest(0x41)

        let forward = try SecretPolicyEpoch(
            epoch: 2,
            predecessorPolicyDigest: predecessor,
            scopeSnapshot: snapshot,
            generationID: generationID,
            authorizedRecipientCredentialIDs: [recipientA, recipientB],
            recoveryRecipient: recovery,
            signerCredentialID: signerCredentialID
        )
        let reverse = try SecretPolicyEpoch(
            epoch: 2,
            predecessorPolicyDigest: predecessor,
            scopeSnapshot: snapshot,
            generationID: generationID,
            authorizedRecipientCredentialIDs: [recipientB, recipientA],
            recoveryRecipient: recovery,
            signerCredentialID: signerCredentialID
        )

        #expect(forward.authorizedRecipientCredentialIDs == [recipientA, recipientB])
        #expect(try forward.canonicalBytes() == reverse.canonicalBytes())
        #expect(
            !forward.authorizedRecipientCredentialIDs.contains(
                DeviceCredentialID(
                    UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
                )
            )
        )

        expectContractError(.duplicateIdentifier(field: "authorizedRecipientCredentialIDs")) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: predecessor,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipientA, recipientA],
                recoveryRecipient: recovery,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.recoveryRecipientIsRoutineRecipient) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: predecessor,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [
                    DeviceCredentialID(recovery.recoveryRecipientID),
                ],
                recoveryRecipient: recovery,
                signerCredentialID: signerCredentialID
            )
        }
    }

    @Test("policy epoch shape rejects zero and invalid predecessor relationships")
    func policyEpochShapeFailsClosed() throws {
        let snapshot = try scopeSnapshot()
        let recipient = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        expectContractError(.invalidPolicyEpoch) {
            _ = try SecretPolicyEpoch(
                epoch: 0,
                predecessorPolicyDigest: nil,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.missingPredecessor) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: nil,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.unexpectedPredecessor) {
            _ = try SecretPolicyEpoch(
                epoch: 1,
                predecessorPolicyDigest: try digest(0x42),
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
    }

    @Test("validating Codable cannot bypass epoch invariants")
    func policyCodableRejectsMalformedState() throws {
        let policy = try policyEpoch()
        let valid = try JSONEncoder().encode(policy)
        var object = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["epoch"] = 0
        let malformed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SecretPolicyEpoch.self, from: malformed)
        }
    }

    @Test("sealed payload and recipient envelopes expose only opaque bound bytes")
    func opaqueEnvelopeContracts() throws {
        let policyDigest = try digest(0x43)
        let snapshotDigest = try digest(0x44)
        let payload = try SealedPayload(
            recordDigest: try digest(0x45),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            formatVersion: 1,
            ciphertextBytes: Data([0x50, 0x51])
        )
        let recipient = try RecipientKeyEnvelope(
            recordDigest: try digest(0x46),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            recipientCredentialID: DeviceCredentialID(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            ),
            formatVersion: 1,
            wrappedKeyBytes: Data([0x52, 0x53])
        )
        let recovery = try RecoveryEnvelope(
            recordDigest: try digest(0x47),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            recoveryRecipientID: UUID(
                uuidString: "20000000-0000-0000-0000-000000000001"
            )!,
            formatVersion: 1,
            wrappedKeyBytes: Data([0x54, 0x55])
        )

        #expect(payload.ciphertextBytes == Data([0x50, 0x51]))
        #expect(recipient.wrappedKeyBytes == Data([0x52, 0x53]))
        #expect(recovery.usage == .breakGlassRecoveryOnly)
        #expect(
            try recipient.canonicalBytes()
                != recovery.canonicalBytes()
        )
    }

    @Test("device trust is a policy-epoch record, not a transient slot")
    func deviceTrustRecordIsStable() throws {
        let record = try DeviceTrustRecord(
            recordDigest: try digest(0x48),
            deviceID: TrustedDeviceID(
                UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            credentialID: DeviceCredentialID(
                UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            trustState: .trusted,
            effectivePolicyEpoch: 2
        )

        #expect(record.trustState == .trusted)
        #expect(record.effectivePolicyEpoch == 2)
    }

    @Test("signed enrollment requires the expected challenge and authority")
    func signedEnrollmentFailsClosed() throws {
        let candidate = try enrolledCredential()
        let authority = try authorityCredential()
        let verifier = TestSignatureVerifier(acceptedSignatures: [Data([0x33])])

        try SecretPolicyValidator.validateEnrollment(
            candidate,
            expectedChallengeID: candidate.enrollmentProof.challengeID,
            authorityCredential: authority,
            signatureVerifier: verifier
        )

        expectPolicyError(.enrollmentChallengeMismatch) {
            try SecretPolicyValidator.validateEnrollment(
                candidate,
                expectedChallengeID: UUID(),
                authorityCredential: authority,
                signatureVerifier: verifier
            )
        }
        expectPolicyError(.signatureRejected) {
            try SecretPolicyValidator.validateEnrollment(
                candidate,
                expectedChallengeID: candidate.enrollmentProof.challengeID,
                authorityCredential: authority,
                signatureVerifier: TestSignatureVerifier(
                    acceptedSignatures: []
                )
            )
        }
    }

    @Test("complete staged records validate before becoming a control snapshot")
    func completeStagedTransitionValidates() throws {
        let fixture = try TransitionFixture()

        let snapshot = try SecretPolicyValidator.validateTransition(
            currentSnapshot: fixture.currentSnapshot,
            stagedRecords: fixture.records,
            commit: fixture.commit,
            trustedCredentials: [fixture.signerCredential],
            knownCompetingChildDigests: [],
            externalFreshness: fixture.externalFreshness,
            digester: fixture.digester,
            signatureVerifier: TestSignatureVerifier(
                acceptedSignatures: fixture.acceptedSignatures
            )
        )

        #expect(snapshot.commit.recordDigest == fixture.commit.recordDigest)
        #expect(snapshot.records == fixture.records)
        #expect(snapshot.state == .committed)
    }

    @Test("monotonic validation rejects rollback, epoch forks, and sibling forks")
    func monotonicAndForkValidationFailsClosed() throws {
        let fixture = try TransitionFixture()

        expectPolicyError(.lowerEpoch) {
            try SecretPolicyValidator.validateMonotonicTransition(
                currentHead: fixture.commitWith(epoch: 3, digestByte: 0x81),
                candidate: fixture.commit,
                knownCompetingChildDigests: []
            )
        }
        expectPolicyError(.sameEpochFork) {
            try SecretPolicyValidator.validateMonotonicTransition(
                currentHead: fixture.commitWith(epoch: 2, digestByte: 0x82),
                candidate: fixture.commit,
                knownCompetingChildDigests: []
            )
        }
        expectPolicyError(.wrongPredecessor) {
            try SecretPolicyValidator.validateMonotonicTransition(
                currentHead: fixture.currentSnapshot.commit,
                candidate: fixture.commitWith(
                    epoch: 2,
                    digestByte: 0x83,
                    predecessorDigest: digest(0x84)
                ),
                knownCompetingChildDigests: []
            )
        }
        expectPolicyError(.samePredecessorForkDecisionRequired) {
            try SecretPolicyValidator.validateMonotonicTransition(
                currentHead: fixture.currentSnapshot.commit,
                candidate: fixture.commit,
                knownCompetingChildDigests: [try digest(0x85)]
            )
        }
    }

    @Test("purge coverage and staged references must be complete and exact")
    func stagedSetCompletenessFailsClosed() throws {
        let fixture = try TransitionFixture()
        let missingReceiptRecords = try SecretControlRecords(
            state: .staged,
            signedPolicy: fixture.records.signedPolicy,
            sealedPayload: fixture.records.sealedPayload,
            recipientEnvelopes: fixture.records.recipientEnvelopes,
            recoveryEnvelope: fixture.records.recoveryEnvelope,
            purgeRequirements: fixture.records.purgeRequirements,
            purgeReceipts: []
        )

        expectPolicyError(.incompletePurgeReceipts) {
            _ = try SecretPolicyValidator.validateTransition(
                currentSnapshot: fixture.currentSnapshot,
                stagedRecords: missingReceiptRecords,
                commit: fixture.commit,
                trustedCredentials: [fixture.signerCredential],
                knownCompetingChildDigests: [],
                externalFreshness: fixture.externalFreshness,
                digester: fixture.digester,
                signatureVerifier: TestSignatureVerifier(
                    acceptedSignatures: fixture.acceptedSignatures
                )
            )
        }
    }

    @Test("local state cannot authorize bootstrap without an exact external anchor")
    func externalFreshnessFailsClosed() throws {
        let fixture = try TransitionFixture()
        let staleLocal = try SecretBootstrapFreshnessCommitment(
            scopeID: scopeID,
            latestPolicyEpoch: fixture.commit.policyEpoch + 1,
            headCommitDigest: digest(0x86),
            policyDigest: digest(0x87)
        )

        expectPolicyError(.staleExternalFreshness) {
            try SecretPolicyValidator.validateBootstrapFreshness(
                localCommit: fixture.commit,
                against: staleLocal
            )
        }

        let forkedAnchor = try SecretBootstrapFreshnessCommitment(
            scopeID: scopeID,
            latestPolicyEpoch: fixture.commit.policyEpoch,
            headCommitDigest: digest(0x88),
            policyDigest: fixture.commit.policyDigest
        )
        expectPolicyError(.externalFreshnessFork) {
            try SecretPolicyValidator.validateBootstrapFreshness(
                localCommit: fixture.commit,
                against: forkedAnchor
            )
        }
    }

    @Test("tampered staged bytes and rejected signatures cannot authorize")
    func tamperAndSignatureValidationFailClosed() throws {
        let fixture = try TransitionFixture()

        expectPolicyError(
            .digestMismatch(domain: .secretScopeSnapshot)
        ) {
            _ = try SecretPolicyValidator.validateTransition(
                currentSnapshot: fixture.currentSnapshot,
                stagedRecords: fixture.records,
                commit: fixture.commit,
                trustedCredentials: [fixture.signerCredential],
                knownCompetingChildDigests: [],
                externalFreshness: fixture.externalFreshness,
                digester: ConstantDigesting(value: digest(0xFF)),
                signatureVerifier: TestSignatureVerifier(
                    acceptedSignatures: fixture.acceptedSignatures
                )
            )
        }

        expectPolicyError(.signatureRejected) {
            _ = try SecretPolicyValidator.validateTransition(
                currentSnapshot: fixture.currentSnapshot,
                stagedRecords: fixture.records,
                commit: fixture.commit,
                trustedCredentials: [fixture.signerCredential],
                knownCompetingChildDigests: [],
                externalFreshness: fixture.externalFreshness,
                digester: fixture.digester,
                signatureVerifier: TestSignatureVerifier(
                    acceptedSignatures: []
                )
            )
        }
    }

    @Test("canonical golden vectors pin every SecretSync record model")
    func canonicalModelGoldenVectors() throws {
        let fixture = try TransitionFixture()
        let credential = try transitionSignerCredential()
        let trust = try DeviceTrustRecord(
            recordDigest: digest(0x48),
            deviceID: credential.deviceID,
            credentialID: credential.credentialID,
            trustState: .trusted,
            effectivePolicyEpoch: 2
        )
        let vectors: [(String, Data)] = [
            ("enrollmentProof", try credential.enrollmentProof.canonicalBytes()),
            ("credential", try credential.canonicalBytes()),
            ("trust", try trust.canonicalBytes()),
            (
                "scope",
                try fixture.records.signedPolicy.policy.scopeSnapshot
                    .canonicalBytes()
            ),
            ("policy", try fixture.records.signedPolicy.policy.canonicalBytes()),
            ("signedPolicy", try fixture.records.signedPolicy.canonicalBytes()),
            ("payload", try fixture.records.sealedPayload.canonicalBytes()),
            (
                "recipient",
                try #require(fixture.records.recipientEnvelopes.first)
                    .canonicalBytes()
            ),
            (
                "recovery",
                try #require(fixture.records.recoveryEnvelope).canonicalBytes()
            ),
            (
                "purgeRequirement",
                try #require(fixture.records.purgeRequirements.first)
                    .canonicalBytes()
            ),
            (
                "purgeReceipt",
                try #require(fixture.records.purgeReceipts.first)
                    .canonicalBytes()
            ),
            ("commit", try fixture.commit.canonicalBytes()),
            ("records", try fixture.records.canonicalBytes()),
            ("freshness", try fixture.externalFreshness.canonicalBytes()),
        ]
        let expectedBase64 = [
            "enrollmentProof": "U1NDUAABACNzZWNyZXQtc3luYy9kZXZpY2UtZW5yb2xsbWVudC1wcm9vZgAFAAEAAAAkM2VlZWVlZWUtZWVlZS1lZWVlLWVlZWUtZWVlZWVlZWVlZWVlAAIAAAABtQADAAAAAbYABAAAAAG3AAUAAAAkZjAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAx",
            "credential": "U1NDUAABACVzZWNyZXQtc3luYy90cnVzdGVkLWRldmljZS1jcmVkZW50aWFsAAwAAQAAACQzYWFhYWFhYS1hYWFhLWFhYWEtYWFhYS1hYWFhYWFhYWFhYWEAAgAAACQzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDQAAwAAAAIAAQAEAAAABmFjdGl2ZQAFAAAAIW9wYXF1ZS10cmFuc2l0aW9uLXNpZ25hdHVyZS1zdWl0ZQAGAAAAAbEABwAAAAGyAAgAAAAhb3BhcXVlLXRyYW5zaXRpb24tYWdyZWVtZW50LXN1aXRlAAkAAAABswAKAAAAAbQACwAAAJZTU0NQAAEAI3NlY3JldC1zeW5jL2RldmljZS1lbnJvbGxtZW50LXByb29mAAUAAQAAACQzZWVlZWVlZS1lZWVlLWVlZWUtZWVlZS1lZWVlZWVlZWVlZWUAAgAAAAG1AAMAAAABtgAEAAAAAbcABQAAACRmMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEADAAAAAG4",
            "trust": "U1NDUAABAB9zZWNyZXQtc3luYy9kZXZpY2UtdHJ1c3QtcmVjb3JkAAQAAQAAACQzYWFhYWFhYS1hYWFhLWFhYWEtYWFhYS1hYWFhYWFhYWFhYWEAAgAAACQzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDQAAwAAAAd0cnVzdGVkAAQAAAAIAAAAAAAAAAI=",
            "scope": "U1NDUAABACFzZWNyZXQtc3luYy9zZWNyZXQtc2NvcGUtc25hcHNob3QAAwABAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMQACAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMgADAAAAUgACAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMgAAACQzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDU=",
            "policy": "U1NDUAABAB9zZWNyZXQtc3luYy9zZWNyZXQtcG9saWN5LWVwb2NoAAkAAQAAAAIAAQACAAAACAAAAAAAAAACAAMAAAAgY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2MABAAAANdTU0NQAAEAIXNlY3JldC1zeW5jL3NlY3JldC1zY29wZS1zbmFwc2hvdAADAAEAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAIAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAyAAMAAABSAAIAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAyAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwNQAFAAAAIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgAAYAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAcAAAAqAAEAAAAkMTAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAgAAABXAAQAAAAkMjAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAAAH29wYXF1ZS1yZWNvdmVyeS1hZ3JlZW1lbnQtc3VpdGUAAAABYQAAAAFiAAkAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDA0",
            "signedPolicy": "U1NDUAABACZzZWNyZXQtc3luYy9zaWduZWQtc2VjcmV0LXBvbGljeS1lcG9jaAACAAEAAAJJU1NDUAABAB9zZWNyZXQtc3luYy9zZWNyZXQtcG9saWN5LWVwb2NoAAkAAQAAAAIAAQACAAAACAAAAAAAAAACAAMAAAAgY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2MABAAAANdTU0NQAAEAIXNlY3JldC1zeW5jL3NlY3JldC1zY29wZS1zbmFwc2hvdAADAAEAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAIAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAyAAMAAABSAAIAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAyAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwNQAFAAAAIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgAAYAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAcAAAAqAAEAAAAkMTAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAgAAABXAAQAAAAkMjAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAAAH29wYXF1ZS1yZWNvdmVyeS1hZ3JlZW1lbnQtc3VpdGUAAAABYQAAAAFiAAkAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDA0AAIAAAABoQ==",
            "payload": "U1NDUAABABpzZWNyZXQtc3luYy9zZWFsZWQtcGF5bG9hZAAHAAEAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAIAAAAgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGAAAwAAAAgAAAAAAAAAAgAEAAAAIGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkAAUAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAYAAAACAAEABwAAAAGi",
            "recipient": "U1NDUAABACJzZWNyZXQtc3luYy9yZWNpcGllbnQta2V5LWVudmVsb3BlAAgAAQAAACQzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEAAgAAACBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYAADAAAACAAAAAAAAAACAAQAAAAgZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGQABQAAACQzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDMABgAAAAIAAQAHAAAAJDEwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMQAIAAAAAaM=",
            "recovery": "U1NDUAABAB1zZWNyZXQtc3luYy9yZWNvdmVyeS1lbnZlbG9wZQAJAAEAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAIAAAAgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGAAAwAAAAgAAAAAAAAAAgAEAAAAIGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkAAUAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAYAAAACAAEABwAAACQyMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEACAAAABZicmVha0dsYXNzUmVjb3ZlcnlPbmx5AAkAAAABpA==",
            "purgeRequirement": "U1NDUAABAB1zZWNyZXQtc3luYy9wdXJnZS1yZXF1aXJlbWVudAAGAAEAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxAAIAAAAIAAAAAAAAAAIAAwAAACBkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAEAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMwAFAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwNAAGAAAAMwADAAAAEWRlcml2ZWRQcm9qZWN0aW9uAAAACXBsYWludGV4dAAAAAtzZWFyY2hJbmRleA==",
            "purgeReceipt": "U1NDUAABABlzZWNyZXQtc3luYy9wdXJnZS1yZWNlaXB0AAkAAQAAACBoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaAACAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMQADAAAACAAAAAAAAAACAAQAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAUAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDA0AAYAAAAzAAMAAAARZGVyaXZlZFByb2plY3Rpb24AAAAJcGxhaW50ZXh0AAAAC3NlYXJjaEluZGV4AAcAAAAJY29tcGxldGVkAAgAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDA0AAkAAAABpQ==",
            "commit": "U1NDUAABACRzZWNyZXQtc3luYy9zZWNyZXQtdHJhbnNpdGlvbi1jb21taXQADQABAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMQACAAAACAAAAAAAAAACAAMAAAAgcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHAABAAAACBkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAFAAAAIGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgAAYAAAAkMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAzAAcAAAAgZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWUACAAAACYAAQAAACBmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZgAJAAAAIGdnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnAAoAAAAmAAEAAAAgaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGgACwAAACYAAQAAACBpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaQAMAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwNAAOAAAAAac=",
            "records": "U1NDUAABACJzZWNyZXQtc3luYy9zZWNyZXQtY29udHJvbC1yZWNvcmRzAAcAAQAAAAZzdGFnZWQAAgAAACBkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAADAAAAIGVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlAAQAAAAmAAEAAAAgZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmYABQAAACBnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZwAGAAAAJgABAAAAIGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoAAcAAAAmAAEAAAAgaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWk=",
            "freshness": "U1NDUAABACpzZWNyZXQtc3luYy9ib290c3RyYXAtZnJlc2huZXNzLWNvbW1pdG1lbnQABAABAAAAJDMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMQACAAAACAAAAAAAAAACAAMAAAAgampqampqampqampqampqampqampqampqampqampqamoABAAAACBkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZA==",
        ]
        for (name, bytes) in vectors {
            #expect(bytes.base64EncodedString() == expectedBase64[name])
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func expectContractError(
    _ expected: SecretSyncContractError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected \(expected)")
    } catch let error as SecretSyncContractError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func expectPolicyError(
    _ expected: SecretPolicyValidationError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected \(expected)")
    } catch let error as SecretPolicyValidationError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private let scopeID = SecretScopeID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
)
private let rootRecordID = UUID(
    uuidString: "30000000-0000-0000-0000-000000000002"
)!
private let generationID = SecretGenerationID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
)
private let signerCredentialID = DeviceCredentialID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
)

private func digest(_ byte: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(repeating: byte, count: SecretRecordDigest.byteCount))
}

private func scopeSnapshot() throws -> SecretScopeSnapshot {
    try SecretScopeSnapshot(
        scopeID: scopeID,
        rootRecordID: rootRecordID,
        memberRecordIDs: [
            rootRecordID,
            UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
        ],
        snapshotDigest: digest(0x60)
    )
}

private func recoveryRecipient() throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
        recoveryRecipientID: UUID(
            uuidString: "20000000-0000-0000-0000-000000000001"
        )!,
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-recovery-agreement-suite",
            keyIdentifier: Data([0x61]),
            publicKeyBytes: Data([0x62])
        )
    )
}

private func policyEpoch() throws -> SecretPolicyEpoch {
    try SecretPolicyEpoch(
        epoch: 2,
        predecessorPolicyDigest: digest(0x63),
        scopeSnapshot: scopeSnapshot(),
        generationID: generationID,
        authorizedRecipientCredentialIDs: [
            DeviceCredentialID(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            ),
        ],
        recoveryRecipient: recoveryRecipient(),
        signerCredentialID: signerCredentialID
    )
}

private struct TestSignatureVerifier: SecretSignatureVerifying {
    let acceptedSignatures: Set<Data>

    func verify(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool {
        acceptedSignatures.contains(signature)
            && !canonicalBytes.isEmpty
            && !signingPublicKey.publicKeyBytes.isEmpty
    }
}

private struct TestDigesting: SecretSyncDigesting {
    let mappings: [Data: SecretRecordDigest]

    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        try #require(mappings[canonicalBytes])
    }
}

private struct ConstantDigesting: SecretSyncDigesting {
    let value: SecretRecordDigest

    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        value
    }
}

private func enrolledCredential() throws -> TrustedDeviceCredential {
    let signing = try SigningPublicKeyDescriptor(
        algorithmIdentifier: "opaque-signature-suite",
        keyIdentifier: Data([0x01]),
        publicKeyBytes: Data([0x10, 0x11])
    )
    let agreement = try KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: "opaque-agreement-suite",
        keyIdentifier: Data([0x02]),
        publicKeyBytes: Data([0x20, 0x21])
    )
    return try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        ),
        credentialID: DeviceCredentialID(
            UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        ),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: signing,
        keyAgreementPublicKey: agreement,
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: UUID(
                uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
            )!,
            challengeBytes: Data([0x30]),
            signingProofBytes: Data([0x31]),
            keyAgreementProofBytes: Data([0x32]),
            authorityCredentialID: DeviceCredentialID(
                UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
            ),
            authoritySignature: Data([0x33])
        )
    )
}

private func authorityCredential() throws -> TrustedDeviceCredential {
    try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(
            UUID(uuidString: "FAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        ),
        credentialID: DeviceCredentialID(
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        ),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: "opaque-authority-signature-suite",
            keyIdentifier: Data([0x91]),
            publicKeyBytes: Data([0x92])
        ),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-authority-agreement-suite",
            keyIdentifier: Data([0x93]),
            publicKeyBytes: Data([0x94])
        ),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: UUID(
                uuidString: "FEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
            )!,
            challengeBytes: Data([0x95]),
            signingProofBytes: Data([0x96]),
            keyAgreementProofBytes: Data([0x97]),
            authorityCredentialID: DeviceCredentialID(
                UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
            ),
            authoritySignature: Data([0x98])
        )
    )
}

private func transitionSignerCredential() throws -> TrustedDeviceCredential {
    try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(
            UUID(uuidString: "3AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        ),
        credentialID: signerCredentialID,
        credentialVersion: 1,
        status: .active,
        signingPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: "opaque-transition-signature-suite",
            keyIdentifier: Data([0xB1]),
            publicKeyBytes: Data([0xB2])
        ),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-transition-agreement-suite",
            keyIdentifier: Data([0xB3]),
            publicKeyBytes: Data([0xB4])
        ),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: UUID(
                uuidString: "3EEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
            )!,
            challengeBytes: Data([0xB5]),
            signingProofBytes: Data([0xB6]),
            keyAgreementProofBytes: Data([0xB7]),
            authorityCredentialID: DeviceCredentialID(
                UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
            ),
            authoritySignature: Data([0xB8])
        )
    )
}

private struct TransitionFixture {
    let signerCredential: TrustedDeviceCredential
    let records: SecretControlRecords
    let commit: SecretTransitionCommit
    let currentSnapshot: SecretControlSnapshot
    let externalFreshness: SecretBootstrapFreshnessCommitment
    let digester: TestDigesting
    let acceptedSignatures: Set<Data>

    init() throws {
        signerCredential = try transitionSignerCredential()
        let snapshot = try scopeSnapshot()
        let signedPolicy = try SignedSecretPolicyEpoch(
            recordDigest: digest(0x64),
            policy: policyEpoch(),
            signature: Data([0xA1])
        )
        let payload = try SealedPayload(
            recordDigest: digest(0x65),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshot.snapshotDigest,
            policyEpoch: 2,
            policyDigest: signedPolicy.recordDigest,
            generationID: generationID,
            formatVersion: 1,
            ciphertextBytes: Data([0xA2])
        )
        let recipient = try RecipientKeyEnvelope(
            recordDigest: digest(0x66),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshot.snapshotDigest,
            policyEpoch: 2,
            policyDigest: signedPolicy.recordDigest,
            generationID: generationID,
            recipientCredentialID: policyEpoch()
                .authorizedRecipientCredentialIDs[0],
            formatVersion: 1,
            wrappedKeyBytes: Data([0xA3])
        )
        let recovery = try RecoveryEnvelope(
            recordDigest: digest(0x67),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshot.snapshotDigest,
            policyEpoch: 2,
            policyDigest: signedPolicy.recordDigest,
            generationID: generationID,
            recoveryRecipientID: try #require(
                policyEpoch().recoveryRecipient?.recoveryRecipientID
            ),
            formatVersion: 1,
            wrappedKeyBytes: Data([0xA4])
        )
        let requirement = try PurgeRequirement(
            recordDigest: digest(0x68),
            scopeID: scopeID,
            policyEpoch: 2,
            policyDigest: signedPolicy.recordDigest,
            generationID: generationID,
            targetCredentialID: signerCredential.credentialID,
            requiredCategories: [.plaintext, .searchIndex, .derivedProjection]
        )
        let receipt = try SignedPurgeReceipt(
            recordDigest: digest(0x69),
            requirementDigest: requirement.recordDigest,
            scopeID: scopeID,
            policyEpoch: 2,
            generationID: generationID,
            respondingCredentialID: signerCredential.credentialID,
            coveredCategories: requirement.requiredCategories,
            status: .completed,
            signerCredentialID: signerCredential.credentialID,
            signature: Data([0xA5])
        )
        records = try SecretControlRecords(
            state: .staged,
            signedPolicy: signedPolicy,
            sealedPayload: payload,
            recipientEnvelopes: [recipient],
            recoveryEnvelope: recovery,
            purgeRequirements: [requirement],
            purgeReceipts: [receipt]
        )

        let previousCommit = try SecretTransitionCommit(
            recordDigest: digest(0x70),
            scopeID: scopeID,
            policyEpoch: 1,
            predecessorCommitDigest: nil,
            policyDigest: digest(0x63),
            scopeSnapshotDigest: snapshot.snapshotDigest,
            generationID: SecretGenerationID(
                UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
            ),
            sealedPayloadDigest: digest(0x71),
            recipientEnvelopeDigests: [digest(0x72)],
            recoveryEnvelopeDigest: nil,
            purgeRequirementDigests: [],
            purgeReceiptDigests: [],
            signerCredentialID: signerCredential.credentialID,
            signature: Data([0xA6])
        )
        currentSnapshot = SecretControlSnapshot(
            state: .committed,
            commit: previousCommit,
            records: records
        )

        commit = try SecretTransitionCommit(
            recordDigest: digest(0x6A),
            scopeID: scopeID,
            policyEpoch: 2,
            predecessorCommitDigest: previousCommit.recordDigest,
            policyDigest: signedPolicy.recordDigest,
            scopeSnapshotDigest: snapshot.snapshotDigest,
            generationID: generationID,
            sealedPayloadDigest: payload.recordDigest,
            recipientEnvelopeDigests: [recipient.recordDigest],
            recoveryEnvelopeDigest: recovery.recordDigest,
            purgeRequirementDigests: [requirement.recordDigest],
            purgeReceiptDigests: [receipt.recordDigest],
            signerCredentialID: signerCredential.credentialID,
            signature: Data([0xA7])
        )
        externalFreshness = try SecretBootstrapFreshnessCommitment(
            scopeID: scopeID,
            latestPolicyEpoch: 2,
            headCommitDigest: commit.recordDigest,
            policyDigest: commit.policyDigest
        )
        acceptedSignatures = [
            signedPolicy.signature,
            receipt.signature,
            commit.signature,
        ]
        digester = TestDigesting(
            mappings: [
                try snapshot.canonicalBytes(): snapshot.snapshotDigest,
                try signedPolicy.canonicalBytes(): signedPolicy.recordDigest,
                try payload.canonicalBytes(): payload.recordDigest,
                try recipient.canonicalBytes(): recipient.recordDigest,
                try recovery.canonicalBytes(): recovery.recordDigest,
                try requirement.canonicalBytes(): requirement.recordDigest,
                try receipt.canonicalBytes(): receipt.recordDigest,
                try commit.canonicalBytes(): commit.recordDigest,
            ]
        )
    }

    func commitWith(
        epoch: UInt64,
        digestByte: UInt8,
        predecessorDigest: SecretRecordDigest? = nil
    ) throws -> SecretTransitionCommit {
        try SecretTransitionCommit(
            recordDigest: digest(digestByte),
            scopeID: commit.scopeID,
            policyEpoch: epoch,
            predecessorCommitDigest: predecessorDigest
                ?? commit.predecessorCommitDigest,
            policyDigest: commit.policyDigest,
            scopeSnapshotDigest: commit.scopeSnapshotDigest,
            generationID: commit.generationID,
            sealedPayloadDigest: commit.sealedPayloadDigest,
            recipientEnvelopeDigests: commit.recipientEnvelopeDigests,
            recoveryEnvelopeDigest: commit.recoveryEnvelopeDigest,
            purgeRequirementDigests: commit.purgeRequirementDigests,
            purgeReceiptDigests: commit.purgeReceiptDigests,
            signerCredentialID: commit.signerCredentialID,
            signature: commit.signature
        )
    }
}
