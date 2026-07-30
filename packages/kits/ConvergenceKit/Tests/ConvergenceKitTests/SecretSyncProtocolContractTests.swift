import Foundation
import Testing
@testable import ConvergenceKit

@Suite("SecretSync protocol contracts")
struct SecretSyncProtocolContractTests {
    @Test("signing and key-agreement custody remain type-distinct")
    func keyCustodyRolesRemainSeparated() async throws {
        let credentialID = fixtureCredentialID(1)
        let signingHandle = SigningPrivateKeyHandle(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let agreementHandle = KeyAgreementPrivateKeyHandle(
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let signing = SigningCustodyFake(
            credentialID: credentialID,
            handle: signingHandle,
            publicKey: try signingDescriptor(1)
        )
        let agreement = AgreementCustodyFake(
            credentialID: credentialID,
            handle: agreementHandle,
            publicKey: try agreementDescriptor(1)
        )

        #expect(
            try await signing.signingPublicCredential(for: credentialID)
                == signingDescriptor(1)
        )
        #expect(
            try await agreement.keyAgreementPublicCredential(for: credentialID)
                == agreementDescriptor(1)
        )
        #expect(
            try await signing.signingPrivateKeyHandle(for: credentialID)
                == signingHandle
        )
        #expect(
            try await agreement.keyAgreementPrivateKeyHandle(for: credentialID)
                == agreementHandle
        )

        let signingRequest = try SigningProofOfPossessionRequest(
            credentialID: credentialID,
            privateKeyHandle: signingHandle,
            challengeID: fixtureUUID(11),
            challengeBytes: Data([0xA1])
        )
        let agreementRequest = try KeyAgreementProofOfPossessionRequest(
            credentialID: credentialID,
            privateKeyHandle: agreementHandle,
            challengeID: fixtureUUID(12),
            challengeBytes: Data([0xA2])
        )

        #expect(
            try await signing.proveSigningKeyPossession(signingRequest)
                == SigningProofOfPossessionResult(
                    credentialID: credentialID,
                    challengeID: signingRequest.challengeID,
                    proofBytes: Data([0xB1])
                )
        )
        #expect(
            try await agreement.proveKeyAgreementKeyPossession(agreementRequest)
                == KeyAgreementProofOfPossessionResult(
                    credentialID: credentialID,
                    challengeID: agreementRequest.challengeID,
                    proofBytes: Data([0xB2])
                )
        )
    }

    @Test("approved-device and global-group snapshots preserve exact membership")
    func trustSnapshotsAreExactAndGloballyScoped() async throws {
        let first = try trustedCredential(1)
        let second = try trustedCredential(2)
        let snapshot = try ApprovedDeviceTrustSnapshot(
            policyEpoch: 7,
            credentials: [second, first]
        )
        let group = try GlobalTrustedGroupSnapshot(
            policyEpoch: 7,
            memberCredentialIDs: [second.credentialID, first.credentialID]
        )
        let trustSnapshot = try SecretSyncTrustSnapshot(
            approvedDevices: snapshot,
            globalTrustedGroup: group
        )
        let store = TrustStoreFake(snapshot: trustSnapshot)

        #expect(snapshot.credentials.map(\.credentialID) == [
            first.credentialID,
            second.credentialID,
        ])
        #expect(snapshot.credential(for: first.credentialID) == first)
        #expect(
            try await store.trustSnapshot().approvedDevices.credentials
                == snapshot.credentials
        )
        #expect(
            try await store.trustSnapshot()
                .globalTrustedGroup.memberCredentialIDs
                == [first.credentialID, second.credentialID]
        )

        let futureCredential = try trustedCredential(3)
        #expect(snapshot.credential(for: futureCredential.credentialID) == nil)
        #expect(
            group.memberCredentialIDs.contains(futureCredential.credentialID)
                == false
        )
        do {
            _ = try SecretSyncTrustSnapshot(
                approvedDevices: snapshot,
                globalTrustedGroup: GlobalTrustedGroupSnapshot(
                    policyEpoch: 7,
                    memberCredentialIDs: [futureCredential.credentialID]
                )
            )
            Issue.record("trusted group accepted an unapproved future credential")
        } catch let error as SecretSyncInterfaceError {
            #expect(error == .trustedGroupContainsUnapprovedCredential)
        }
    }

    @Test("policy compare-and-advance reports forks without overwriting the head")
    func policyCompareAndAdvanceIsMonotonic() async throws {
        let scopeID = SecretScopeID(fixtureUUID(20))
        let head = try SecretPolicyStoreHead(
            scopeID: scopeID,
            policyEpoch: 3,
            commitDigest: digest(0x31),
            policyDigest: digest(0x32)
        )
        let store = PolicyStoreFake(head: head)
        let next = try SecretPolicyStoreHead(
            scopeID: scopeID,
            policyEpoch: 4,
            commitDigest: digest(0x41),
            policyDigest: digest(0x42)
        )
        let precondition = try SecretPolicyAdvancePrecondition(
            expectedHead: head,
            candidateHead: next,
            predecessorCommitDigest: head.commitDigest
        )

        #expect(
            try await store.compareAndAdvance(precondition) == .advanced(next)
        )

        let sibling = try SecretPolicyStoreHead(
            scopeID: scopeID,
            policyEpoch: 4,
            commitDigest: digest(0x51),
            policyDigest: digest(0x52)
        )
        let siblingPrecondition = try SecretPolicyAdvancePrecondition(
            expectedHead: head,
            candidateHead: sibling,
            predecessorCommitDigest: head.commitDigest
        )
        let result = try await store.compareAndAdvance(siblingPrecondition)
        #expect(
            result == .forkDetected(
                currentHead: next,
                competingCommitDigest: sibling.commitDigest
            )
        )
        #expect(try await store.policyHead(for: scopeID) == next)
    }

    @Test("purge receipts are category-idempotent and admission defaults closed")
    func purgeReceiptsAreIdempotentAndFailClosed() async throws {
        let requirement = try purgeRequirement()
        let receipt = try purgeReceipt(for: requirement)
        let categoryReceipt = try PurgeArtifactCategoryReceipt(
            requirementDigest: requirement.recordDigest,
            category: .plaintext,
            respondingCredentialID: requirement.targetCredentialID,
            signedReceipt: receipt
        )
        let store = PurgeStoreFake(requirement: requirement)

        #expect(
            try await store.admissionSnapshot(
                for: requirement.targetCredentialID
            ).status == .blocked
        )
        #expect(
            try await store.recordArtifactReceipt(categoryReceipt) == .recorded
        )
        #expect(
            try await store.recordArtifactReceipt(categoryReceipt)
                == .alreadyRecorded(categoryReceipt)
        )
        do {
            _ = try PurgeAdmissionSnapshot(
                status: .admitted,
                pendingRequirementDigests: [requirement.recordDigest]
            )
            Issue.record("admission accepted a pending purge requirement")
        } catch let error as SecretSyncInterfaceError {
            #expect(error == .admissionWouldBypassPendingPurge)
        }

        let unreachable = NeverReconnectedPurgeFact(
            requirementDigest: requirement.recordDigest,
            targetCredentialID: requirement.targetCredentialID
        )
        #expect(unreachable.requirementDigest == requirement.recordDigest)
        #expect(receipt.status == .completed)
    }

    @Test("recovery is global break-glass and rotation requires a new generation")
    func recoveryContractsRequireFreshGenerationAndExternalAnchor() async throws {
        let recipient = try recoveryRecipient(1)
        let confirmation = try BlindRecoveryConfirmationEvidence(
            recoveryRecipientID: recipient.recoveryRecipientID,
            challengeID: fixtureUUID(61),
            evidenceBytes: Data([0x61])
        )
        let enrollment = try RecoveryEnrollmentRequest(
            requestID: fixtureUUID(62),
            recoveryRecipient: recipient,
            blindConfirmation: confirmation
        )
        let currentGeneration = SecretGenerationID(fixtureUUID(63))
        let replacementGeneration = SecretGenerationID(fixtureUUID(64))
        let anchorCommitment = try SecretBootstrapFreshnessCommitment(
            scopeID: SecretScopeID(fixtureUUID(66)),
            latestPolicyEpoch: 9,
            headCommitDigest: digest(0x66),
            policyDigest: digest(0x67)
        )
        let rotation = try RecoveryRotationRequest(
            requestID: fixtureUUID(65),
            scopeID: anchorCommitment.scopeID,
            currentRecoveryRecipientID: recipient.recoveryRecipientID,
            replacementRecoveryRecipient: recipient,
            currentGenerationID: currentGeneration,
            replacementGenerationID: replacementGeneration,
            expectedFreshnessCommitment: anchorCommitment,
            blindConfirmation: confirmation
        )
        let anchor = FreshnessAnchorFake(commitment: anchorCommitment)
        let custody = RecoveryCustodyFake(recipient: recipient)
        let breakGlass = try BreakGlassRecoveryRequest(
            requestID: fixtureUUID(68),
            scopeID: anchorCommitment.scopeID,
            recoveryRecipientID: recipient.recoveryRecipientID,
            sealedGenerationID: replacementGeneration,
            expectedFreshnessCommitment: anchorCommitment,
            blindConfirmation: confirmation
        )

        #expect(try await custody.globalRecoveryRecipient() == recipient)
        #expect(
            try await custody.stageEnrollment(enrollment).requestID
                == enrollment.requestID
        )
        #expect(
            try await custody.stageRotation(
                rotation,
                freshnessAnchor: anchor
            ).requestID == rotation.requestID
        )
        #expect(
            try await custody.stageBreakGlass(
                breakGlass,
                freshnessAnchor: anchor
            ).requestID == breakGlass.requestID
        )
        #expect(enrollment.recoveryRecipient == recipient)

        do {
            _ = try RecoveryRotationRequest(
                requestID: fixtureUUID(67),
                scopeID: anchorCommitment.scopeID,
                currentRecoveryRecipientID: recipient.recoveryRecipientID,
                replacementRecoveryRecipient: recipient,
                currentGenerationID: currentGeneration,
                replacementGenerationID: currentGeneration,
                expectedFreshnessCommitment: anchorCommitment,
                blindConfirmation: confirmation
            )
            Issue.record("rotation accepted generation reuse")
        } catch let error as SecretSyncInterfaceError {
            #expect(error == .generationReuse)
        }
    }
}

private actor SigningCustodyFake:
    SecretSyncSigningPublicCredentialRetrieving,
    SecretSyncSigningKeyCustody
{
    let credentialID: DeviceCredentialID
    let handle: SigningPrivateKeyHandle
    let publicKey: SigningPublicKeyDescriptor

    init(
        credentialID: DeviceCredentialID,
        handle: SigningPrivateKeyHandle,
        publicKey: SigningPublicKeyDescriptor
    ) {
        self.credentialID = credentialID
        self.handle = handle
        self.publicKey = publicKey
    }

    func signingPublicCredential(
        for credentialID: DeviceCredentialID
    ) async throws -> SigningPublicKeyDescriptor {
        precondition(credentialID == self.credentialID)
        return publicKey
    }

    func signingPrivateKeyHandle(
        for credentialID: DeviceCredentialID
    ) async throws -> SigningPrivateKeyHandle {
        precondition(credentialID == self.credentialID)
        return handle
    }

    func proveSigningKeyPossession(
        _ request: SigningProofOfPossessionRequest
    ) async throws -> SigningProofOfPossessionResult {
        precondition(request.privateKeyHandle == handle)
        return try SigningProofOfPossessionResult(
            credentialID: request.credentialID,
            challengeID: request.challengeID,
            proofBytes: Data([0xB1])
        )
    }
}

private actor AgreementCustodyFake:
    SecretSyncKeyAgreementPublicCredentialRetrieving,
    SecretSyncKeyAgreementKeyCustody
{
    let credentialID: DeviceCredentialID
    let handle: KeyAgreementPrivateKeyHandle
    let publicKey: KeyAgreementPublicKeyDescriptor

    init(
        credentialID: DeviceCredentialID,
        handle: KeyAgreementPrivateKeyHandle,
        publicKey: KeyAgreementPublicKeyDescriptor
    ) {
        self.credentialID = credentialID
        self.handle = handle
        self.publicKey = publicKey
    }

    func keyAgreementPublicCredential(
        for credentialID: DeviceCredentialID
    ) async throws -> KeyAgreementPublicKeyDescriptor {
        precondition(credentialID == self.credentialID)
        return publicKey
    }

    func keyAgreementPrivateKeyHandle(
        for credentialID: DeviceCredentialID
    ) async throws -> KeyAgreementPrivateKeyHandle {
        precondition(credentialID == self.credentialID)
        return handle
    }

    func proveKeyAgreementKeyPossession(
        _ request: KeyAgreementProofOfPossessionRequest
    ) async throws -> KeyAgreementProofOfPossessionResult {
        precondition(request.privateKeyHandle == handle)
        return try KeyAgreementProofOfPossessionResult(
            credentialID: request.credentialID,
            challengeID: request.challengeID,
            proofBytes: Data([0xB2])
        )
    }
}

private actor TrustStoreFake: SecretSyncTrustStore {
    let snapshot: SecretSyncTrustSnapshot

    init(snapshot: SecretSyncTrustSnapshot) {
        self.snapshot = snapshot
    }

    func trustSnapshot() async throws -> SecretSyncTrustSnapshot {
        snapshot
    }
}

private actor PolicyStoreFake: SecretSyncPolicyStore {
    private var currentHead: SecretPolicyStoreHead

    init(head: SecretPolicyStoreHead) {
        currentHead = head
    }

    func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretControlRecords? {
        nil
    }

    func committedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretControlRecords? {
        nil
    }

    func policyHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead? {
        currentHead.scopeID == scopeID ? currentHead : nil
    }

    func appendStagedPolicy(_ records: SecretControlRecords) async throws {}

    func compareAndAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult {
        let candidate = precondition.candidateHead
        guard precondition.expectedHead == currentHead else {
            return .forkDetected(
                currentHead: currentHead,
                competingCommitDigest: candidate.commitDigest
            )
        }
        currentHead = candidate
        return .advanced(candidate)
    }
}

private actor PurgeStoreFake: SecretSyncPurgeStore {
    let requirement: PurgeRequirement
    private var receipts: [PurgeArtifactReceiptKey: PurgeArtifactCategoryReceipt] = [:]

    init(requirement: PurgeRequirement) {
        self.requirement = requirement
    }

    func pendingRequirements(
        for credentialID: DeviceCredentialID
    ) async throws -> [PurgeRequirement] {
        credentialID == requirement.targetCredentialID ? [requirement] : []
    }

    func recordArtifactReceipt(
        _ receipt: PurgeArtifactCategoryReceipt
    ) async throws -> PurgeArtifactReceiptRecordingResult {
        if let existing = receipts[receipt.key] {
            return .alreadyRecorded(existing)
        }
        receipts[receipt.key] = receipt
        return .recorded
    }

    func admissionSnapshot(
        for credentialID: DeviceCredentialID
    ) async throws -> PurgeAdmissionSnapshot {
        try PurgeAdmissionSnapshot()
    }
}

private struct FreshnessAnchorFake: ExternalBootstrapFreshnessAnchor {
    let commitment: SecretBootstrapFreshnessCommitment

    func latestCommitment(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment {
        precondition(scopeID == commitment.scopeID)
        return commitment
    }
}

private actor RecoveryCustodyFake: SecretSyncRecoveryRecipientCustody {
    let recipient: RecoveryRecipientDescriptor

    init(recipient: RecoveryRecipientDescriptor) {
        self.recipient = recipient
    }

    func globalRecoveryRecipient() async throws -> RecoveryRecipientDescriptor? {
        recipient
    }

    func stageEnrollment(
        _ request: RecoveryEnrollmentRequest
    ) async throws -> RecoveryOperationEvidence {
        return try RecoveryOperationEvidence(
            requestID: request.requestID,
            evidenceBytes: Data([0xE1])
        )
    }

    func stageRotation(
        _ request: RecoveryRotationRequest,
        freshnessAnchor: any ExternalBootstrapFreshnessAnchor
    ) async throws -> RecoveryOperationEvidence {
        _ = try await freshnessAnchor.latestCommitment(
            for: SecretScopeID(fixtureUUID(66))
        )
        return try RecoveryOperationEvidence(
            requestID: request.requestID,
            evidenceBytes: Data([0xE2])
        )
    }

    func stageBreakGlass(
        _ request: BreakGlassRecoveryRequest,
        freshnessAnchor: any ExternalBootstrapFreshnessAnchor
    ) async throws -> RecoveryOperationEvidence {
        let commitment = try await freshnessAnchor.latestCommitment(
            for: request.scopeID
        )
        precondition(commitment == request.expectedFreshnessCommitment)
        return try RecoveryOperationEvidence(
            requestID: request.requestID,
            evidenceBytes: Data([0xE3])
        )
    }
}

private func fixtureUUID(_ suffix: Int) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012d",
            suffix
        )
    )!
}

private func fixtureCredentialID(_ suffix: Int) -> DeviceCredentialID {
    DeviceCredentialID(fixtureUUID(suffix))
}

private func digest(_ byte: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(
        bytes: Data(repeating: byte, count: SecretRecordDigest.byteCount)
    )
}

private func signingDescriptor(
    _ byte: UInt8
) throws -> SigningPublicKeyDescriptor {
    try SigningPublicKeyDescriptor(
        algorithmIdentifier: "opaque-signing-suite",
        keyIdentifier: Data([byte]),
        publicKeyBytes: Data([byte, byte])
    )
}

private func agreementDescriptor(
    _ byte: UInt8
) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: "opaque-agreement-suite",
        keyIdentifier: Data([byte &+ 0x40]),
        publicKeyBytes: Data([byte &+ 0x40, byte &+ 0x40])
    )
}

private func trustedCredential(
    _ suffix: Int
) throws -> TrustedDeviceCredential {
    let byte = UInt8(suffix)
    return try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(fixtureUUID(100 + suffix)),
        credentialID: fixtureCredentialID(suffix),
        credentialVersion: 1,
        status: .active,
        signingPublicKey: signingDescriptor(byte),
        keyAgreementPublicKey: agreementDescriptor(byte),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: fixtureUUID(200 + suffix),
            challengeBytes: Data([byte]),
            signingProofBytes: Data([byte &+ 1]),
            keyAgreementProofBytes: Data([byte &+ 2]),
            authorityCredentialID: fixtureCredentialID(99),
            authoritySignature: Data([byte &+ 3])
        )
    )
}

private func purgeRequirement() throws -> PurgeRequirement {
    try PurgeRequirement(
        recordDigest: digest(0x71),
        scopeID: SecretScopeID(fixtureUUID(71)),
        policyEpoch: 2,
        policyDigest: digest(0x72),
        supersededGenerationID: SecretGenerationID(fixtureUUID(72)),
        replacementGenerationID: SecretGenerationID(fixtureUUID(73)),
        targetCredentialID: fixtureCredentialID(71),
        requiredCategories: [.plaintext, .searchIndex]
    )
}

private func purgeReceipt(
    for requirement: PurgeRequirement
) throws -> SignedPurgeReceipt {
    try SignedPurgeReceipt(
        recordDigest: digest(0x73),
        requirementDigest: requirement.recordDigest,
        scopeID: requirement.scopeID,
        policyEpoch: requirement.policyEpoch,
        policyDigest: requirement.policyDigest,
        supersededGenerationID: requirement.supersededGenerationID,
        replacementGenerationID: requirement.replacementGenerationID,
        respondingCredentialID: requirement.targetCredentialID,
        coveredCategories: requirement.requiredCategories,
        status: .completed,
        signerCredentialID: requirement.targetCredentialID,
        signature: Data([0x74])
    )
}

private func recoveryRecipient(
    _ suffix: Int
) throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
        recoveryRecipientID: fixtureUUID(500 + suffix),
        keyAgreementPublicKey: agreementDescriptor(UInt8(80 + suffix))
    )
}
