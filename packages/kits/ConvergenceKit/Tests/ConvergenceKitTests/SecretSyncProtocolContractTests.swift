import Foundation
import Testing
@testable import ConvergenceKit

@Suite("SecretSync protocol contracts")
struct SecretSyncProtocolContractTests {
    @Test("signing and key-agreement custody remain type-distinct")
    func keyCustodyRolesRemainSeparated() async throws {
        let fixture = try keyCustodyFixture()
        try await expectKeyCustodyLookups(fixture)
        try await expectKeyCustodyProofs(fixture)
    }

    @Test("approved-device and global-group snapshots preserve exact membership")
    func trustSnapshotsAreExactAndGloballyScoped() async throws {
        let fixture = try trustSnapshotFixture()
        try await expectExactTrustSnapshot(fixture)
        let futureCredential = try trustedCredential(3)
        #expect(
            fixture.snapshot.credential(for: futureCredential.credentialID)
                == nil
        )
        #expect(
            fixture.group.memberCredentialIDs.contains(
                futureCredential.credentialID
            )
                == false
        )
        expectFutureCredentialRejected(
            snapshot: fixture.snapshot,
            futureCredential: futureCredential
        )
        expectMismatchedTrustRecordRejected(
            credential: fixture.first,
            otherDevice: fixture.second.deviceID
        )
    }

    @Test("policy entries retain signed commits required for rehydration")
    func policyEntriesRetainCommits() async throws {
        let entry = try policyStoreEntry()
        let revoked = try #require(
            entry.trustRecords.first { $0.trustState == .revoked }
        )
        #expect(
            entry.records.signedPolicy.policy.trustedDeviceRecordDigests
                .contains(revoked.recordDigest)
        )
        #expect(revoked.credentialID == fixtureCredentialID(806))
    }

    @Test("policy CAS requires the exact staged validator-produced candidate")
    func policyCompareAndAdvanceIsMonotonic() async throws {
        let entry = try policyStoreEntry()
        let snapshot = try authoritativeSnapshotFixture(for: entry)
        let precondition = try SecretPolicyAdvancePrecondition(
            expectedHead: nil,
            candidateEntry: entry,
            validatedSnapshot: snapshot
        )
        #expect(precondition.recoveryPublicationCapability == nil)
        let store = PolicyStoreFake()
        #expect(
            await store.cancelRecoveryAdvance(precondition) == .notRecovery
        )
        await #expect(throws: SecretSyncInterfaceError.self) {
            try await store.compareAndAdvance(precondition)
        }
        try await store.appendStagedPolicy(
            policyStoreEntry(seed: 900, byte: 0x90)
        )
        await #expect(throws: SecretSyncInterfaceError.self) {
            try await store.compareAndAdvance(precondition)
        }
        try await store.appendStagedPolicy(entry)
        #expect(
            try await store.compareAndAdvance(precondition)
                == .advanced(precondition.candidateHead)
        )
        let hydrated = try #require(
            try await store.unvalidatedHeadPolicy(
                for: entry.commit.scopeID,
                epoch: entry.commit.policyEpoch
            )
        )
        #expect(hydrated.commit == snapshot.commit)
        #expect(hydrated.records == snapshot.records)
        #expect(hydrated.trustRecords == snapshot.trustedDeviceRecords)
    }

    @Test("purge receipts are category-idempotent and admission defaults closed")
    func purgeReceiptsAreIdempotentAndFailClosed() async throws {
        let requirement = try purgeRequirement()
        let receipt = try purgeReceipt(for: requirement)
        let categoryReceipt = try PurgeArtifactCategoryReceipt(
            requirement: requirement,
            category: .plaintext,
            signedReceipt: receipt
        )
        let store = PurgeStoreFake(requirement: requirement)
        try await expectIdempotentPurgeRecording(
            store: store,
            requirement: requirement,
            categoryReceipt: categoryReceipt
        )
        expectPendingPurgeBlocksAdmission(requirement)
        try expectMismatchedPurgeBindingsRejected(requirement)
        let unreachable = NeverReconnectedPurgeFact(
            requirementDigest: requirement.recordDigest,
            targetCredentialID: requirement.targetCredentialID
        )
        #expect(unreachable.requirementDigest == requirement.recordDigest)
        #expect(receipt.status == .completed)
    }

    @Test("recovery is global break-glass and rotation requires a new generation")
    func recoveryContractsRequireFreshGenerationAndExternalAnchor() async throws {
        let fixture = try recoveryContractFixture()
        try await expectRecoveryOperations(fixture)
        expectRecoveryGenerationReuseRejected(fixture)
    }
}

private struct KeyCustodyFixture {
    let credentialID: DeviceCredentialID
    let signingHandle: SigningPrivateKeyHandle
    let agreementHandle: KeyAgreementPrivateKeyHandle
    let signing: SigningCustodyFake
    let agreement: AgreementCustodyFake
}

private func keyCustodyFixture() throws -> KeyCustodyFixture {
    let credentialID = fixtureCredentialID(1)
    let signingHandle = SigningPrivateKeyHandle(
        UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    let agreementHandle = KeyAgreementPrivateKeyHandle(
        UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
    return KeyCustodyFixture(
        credentialID: credentialID,
        signingHandle: signingHandle,
        agreementHandle: agreementHandle,
        signing: SigningCustodyFake(
            credentialID: credentialID,
            handle: signingHandle,
            publicKey: try signingDescriptor(1)
        ),
        agreement: AgreementCustodyFake(
            credentialID: credentialID,
            handle: agreementHandle,
            publicKey: try agreementDescriptor(1)
        )
    )
}

private func expectKeyCustodyLookups(
    _ fixture: KeyCustodyFixture
) async throws {
    #expect(
        try await fixture.signing.signingPublicCredential(
            for: fixture.credentialID
        ) == signingDescriptor(1)
    )
    #expect(
        try await fixture.agreement.keyAgreementPublicCredential(
            for: fixture.credentialID
        ) == agreementDescriptor(1)
    )
    #expect(
        try await fixture.signing.signingPrivateKeyHandle(
            for: fixture.credentialID
        ) == fixture.signingHandle
    )
    #expect(
        try await fixture.agreement.keyAgreementPrivateKeyHandle(
            for: fixture.credentialID
        ) == fixture.agreementHandle
    )
}

private func expectKeyCustodyProofs(
    _ fixture: KeyCustodyFixture
) async throws {
    let signingRequest = try SigningProofOfPossessionRequest(
        credentialID: fixture.credentialID,
        privateKeyHandle: fixture.signingHandle,
        challengeID: fixtureUUID(11),
        challengeBytes: Data([0xA1])
    )
    let agreementRequest = try KeyAgreementProofOfPossessionRequest(
        credentialID: fixture.credentialID,
        privateKeyHandle: fixture.agreementHandle,
        challengeID: fixtureUUID(12),
        challengeBytes: Data([0xA2])
    )
    #expect(
        try await fixture.signing.proveSigningKeyPossession(signingRequest)
            == SigningProofOfPossessionResult(
                credentialID: fixture.credentialID,
                challengeID: signingRequest.challengeID,
                proofBytes: Data([0xB1])
            )
    )
    #expect(
        try await fixture.agreement.proveKeyAgreementKeyPossession(
            agreementRequest
        ) == KeyAgreementProofOfPossessionResult(
            credentialID: fixture.credentialID,
            challengeID: agreementRequest.challengeID,
            proofBytes: Data([0xB2])
        )
    )
}

private struct TrustSnapshotFixture {
    let first: TrustedDeviceCredential
    let second: TrustedDeviceCredential
    let firstTrust: DeviceTrustRecord
    let snapshot: ApprovedDeviceTrustSnapshot
    let group: GlobalTrustedGroupSnapshot
    let store: TrustStoreFake
}

private func trustSnapshotFixture() throws -> TrustSnapshotFixture {
    let first = try trustedCredential(1)
    let second = try trustedCredential(2)
    let firstTrust = try trustRecord(for: first, byte: 0x21, epoch: 7)
    let secondTrust = try trustRecord(for: second, byte: 0x22, epoch: 7)
    let snapshot = try ApprovedDeviceTrustSnapshot(
        policyEpoch: 7,
        credentials: [second, first],
        trustRecords: [secondTrust, firstTrust]
    )
    let group = try GlobalTrustedGroupSnapshot(
        policyEpoch: 7,
        memberCredentialIDs: [second.credentialID, first.credentialID]
    )
    let trustSnapshot = try SecretSyncTrustSnapshot(
        approvedDevices: snapshot,
        globalTrustedGroup: group
    )
    return TrustSnapshotFixture(
        first: first,
        second: second,
        firstTrust: firstTrust,
        snapshot: snapshot,
        group: group,
        store: TrustStoreFake(snapshot: trustSnapshot)
    )
}

private func expectExactTrustSnapshot(
    _ fixture: TrustSnapshotFixture
) async throws {
    #expect(fixture.snapshot.credentials.map(\.credentialID) == [
        fixture.first.credentialID,
        fixture.second.credentialID,
    ])
    #expect(
        fixture.snapshot.credential(for: fixture.first.credentialID)
            == fixture.first
    )
    #expect(
        fixture.snapshot.trustRecord(for: fixture.first.credentialID)
            == fixture.firstTrust
    )
    #expect(
        try await fixture.store.trustSnapshot().approvedDevices.credentials
            == fixture.snapshot.credentials
    )
    #expect(
        try await fixture.store.trustSnapshot()
            .globalTrustedGroup.memberCredentialIDs
            == [fixture.first.credentialID, fixture.second.credentialID]
    )
}

private func expectFutureCredentialRejected(
    snapshot: ApprovedDeviceTrustSnapshot,
    futureCredential: TrustedDeviceCredential
) {
    do {
        _ = try SecretSyncTrustSnapshot(
            approvedDevices: snapshot,
            globalTrustedGroup: GlobalTrustedGroupSnapshot(
                policyEpoch: snapshot.policyEpoch,
                memberCredentialIDs: [futureCredential.credentialID]
            )
        )
        Issue.record("trusted group accepted an unapproved future credential")
    } catch let error as SecretSyncInterfaceError {
        #expect(error == .trustedGroupContainsUnapprovedCredential)
    } catch {
        Issue.record("unexpected trust snapshot error: \(error)")
    }
}

private func expectIdempotentPurgeRecording(
    store: PurgeStoreFake,
    requirement: PurgeRequirement,
    categoryReceipt: PurgeArtifactCategoryReceipt
) async throws {
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
}

private func expectPendingPurgeBlocksAdmission(
    _ requirement: PurgeRequirement
) {
    do {
        _ = try PurgeAdmissionSnapshot(
            status: .admitted,
            pendingRequirementDigests: [requirement.recordDigest]
        )
        Issue.record("admission accepted a pending purge requirement")
    } catch let error as SecretSyncInterfaceError {
        #expect(error == .admissionWouldBypassPendingPurge)
    } catch {
        Issue.record("unexpected purge admission error: \(error)")
    }
}

private func expectMismatchedTrustRecordRejected(
    credential: TrustedDeviceCredential,
    otherDevice: TrustedDeviceID
) {
    do {
        let mismatched = try DeviceTrustRecord(
            recordDigest: digest(0x29),
            credentialDigest: digest(0x49),
            deviceID: otherDevice,
            credentialID: credential.credentialID,
            trustState: .trusted,
            effectivePolicyEpoch: 7
        )
        _ = try ApprovedDeviceTrustSnapshot(
            policyEpoch: 7,
            credentials: [credential],
            trustRecords: [mismatched]
        )
        Issue.record("trust snapshot accepted a mismatched device binding")
    } catch let error as SecretSyncInterfaceError {
        #expect(error == .trustRecordMismatch)
    } catch {
        Issue.record("unexpected trust-record error: \(error)")
    }
}

private func expectMismatchedPurgeBindingsRejected(
    _ requirement: PurgeRequirement
) throws {
    try expectInvalidPurgeReceipt {
        _ = try PurgeArtifactCategoryReceipt(
            requirement: requirement,
            category: .plaintext,
            signedReceipt: purgeReceipt(
                for: requirement,
                signerCredentialID: fixtureCredentialID(999)
            )
        )
    }
    let otherGeneration = try PurgeRequirement(
        recordDigest: requirement.recordDigest,
        scopeID: requirement.scopeID,
        policyEpoch: requirement.policyEpoch,
        policyDigest: requirement.policyDigest,
        supersededGenerationID: requirement.supersededGenerationID,
        replacementGenerationID: SecretGenerationID(fixtureUUID(999)),
        targetCredentialID: requirement.targetCredentialID,
        requiredCategories: requirement.requiredCategories
    )
    try expectInvalidPurgeReceipt {
        _ = try PurgeArtifactCategoryReceipt(
            requirement: otherGeneration,
            category: .plaintext,
            signedReceipt: purgeReceipt(for: requirement)
        )
    }
    try expectInvalidPurgeReceipt {
        _ = try PurgeArtifactCategoryReceipt(
            requirement: requirement,
            category: .embedding,
            signedReceipt: purgeReceipt(for: requirement)
        )
    }
    try expectInvalidPurgeReceipt {
        _ = try PurgeArtifactCategoryReceipt(
            requirement: requirement,
            category: .plaintext,
            signedReceipt: purgeReceipt(
                for: requirement,
                coveredCategories: [.plaintext]
            )
        )
    }
}

private func expectInvalidPurgeReceipt(
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("purge receipt accepted mismatched requirement bindings")
    } catch let error as SecretSyncInterfaceError {
        #expect(error == .invalidPurgeReceipt)
    }
}

private struct RecoveryContractFixture {
    let recipient: RecoveryRecipientDescriptor
    let confirmation: BlindRecoveryConfirmationEvidence
    let enrollment: RecoveryEnrollmentRequest
    let currentGeneration: SecretGenerationID
    let replacementGeneration: SecretGenerationID
    let anchorCommitment: SecretBootstrapFreshnessCommitment
    let rotation: RecoveryRotationRequest
    let breakGlass: BreakGlassRecoveryRequest
    let anchor: FreshnessAnchorFake
    let custody: RecoveryCustodyFake
}

private func recoveryContractFixture() throws -> RecoveryContractFixture {
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
    let commitment = try SecretBootstrapFreshnessCommitment(
        scopeID: SecretScopeID(fixtureUUID(66)),
        latestPolicyEpoch: 9,
        headCommitDigest: digest(0x66),
        policyDigest: digest(0x67)
    )
    let rotation = try RecoveryRotationRequest(
        requestID: fixtureUUID(65),
        scopeID: commitment.scopeID,
        currentRecoveryRecipientID: recipient.recoveryRecipientID,
        replacementRecoveryRecipient: recipient,
        currentGenerationID: currentGeneration,
        replacementGenerationID: replacementGeneration,
        expectedFreshnessCommitment: commitment,
        blindConfirmation: confirmation
    )
    let breakGlass = try BreakGlassRecoveryRequest(
        requestID: fixtureUUID(68),
        scopeID: commitment.scopeID,
        recoveryRecipientID: recipient.recoveryRecipientID,
        sealedGenerationID: replacementGeneration,
        expectedFreshnessCommitment: commitment,
        blindConfirmation: confirmation
    )
    return RecoveryContractFixture(
        recipient: recipient,
        confirmation: confirmation,
        enrollment: enrollment,
        currentGeneration: currentGeneration,
        replacementGeneration: replacementGeneration,
        anchorCommitment: commitment,
        rotation: rotation,
        breakGlass: breakGlass,
        anchor: FreshnessAnchorFake(commitment: commitment),
        custody: RecoveryCustodyFake(recipient: recipient)
    )
}

private func expectRecoveryOperations(
    _ fixture: RecoveryContractFixture
) async throws {
    #expect(
        try await fixture.custody.globalRecoveryRecipient()
            == fixture.recipient
    )
    #expect(
        try await fixture.custody.stageEnrollment(fixture.enrollment).requestID
            == fixture.enrollment.requestID
    )
    #expect(
        try await fixture.custody.stageRotation(
            fixture.rotation,
            freshnessAnchor: fixture.anchor
        ).requestID == fixture.rotation.requestID
    )
    #expect(
        try await fixture.custody.stageBreakGlass(
            fixture.breakGlass,
            freshnessAnchor: fixture.anchor
        ).requestID == fixture.breakGlass.requestID
    )
    #expect(fixture.enrollment.recoveryRecipient == fixture.recipient)
}

private func expectRecoveryGenerationReuseRejected(
    _ fixture: RecoveryContractFixture
) {
    do {
        _ = try RecoveryRotationRequest(
            requestID: fixtureUUID(67),
            scopeID: fixture.anchorCommitment.scopeID,
            currentRecoveryRecipientID: fixture.recipient.recoveryRecipientID,
            replacementRecoveryRecipient: fixture.recipient,
            currentGenerationID: fixture.currentGeneration,
            replacementGenerationID: fixture.currentGeneration,
            expectedFreshnessCommitment: fixture.anchorCommitment,
            blindConfirmation: fixture.confirmation
        )
        Issue.record("rotation accepted generation reuse")
    } catch let error as SecretSyncInterfaceError {
        #expect(error == .generationReuse)
    } catch {
        Issue.record("unexpected recovery rotation error: \(error)")
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
    private var currentHead: SecretPolicyStoreHead?
    private var stagedEntry: SecretPolicyStoreEntry?
    private var committedEntry: SecretPolicyStoreEntry?

    func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry? {
        guard
            stagedEntry?.commit.scopeID == scopeID,
            stagedEntry?.commit.policyEpoch == epoch
        else {
            return nil
        }
        return stagedEntry
    }

    // This double keeps the entry `compareAndAdvance` accepted, so what it
    // hands back is material the validator already admitted through the
    // precondition. It still answers under the unvalidated name because the
    // protocol promises the caller nothing about authority — a conformer that
    // happens to hold validated material does not widen the contract.
    func unvalidatedHeadPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry? {
        guard
            committedEntry?.commit.scopeID == scopeID,
            committedEntry?.commit.policyEpoch == epoch
        else {
            return nil
        }
        return committedEntry
    }

    func policyHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead? {
        currentHead?.scopeID == scopeID ? currentHead : nil
    }

    func appendStagedPolicy(_ entry: SecretPolicyStoreEntry) async throws {
        stagedEntry = entry
    }

    func compareAndAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult {
        let candidate = precondition.candidateHead
        guard stagedEntry == precondition.candidateEntry else {
            throw SecretSyncInterfaceError.invalidPolicyAdvancePrecondition
        }
        guard precondition.expectedHead == currentHead else {
            guard let currentHead else {
                throw SecretSyncInterfaceError.invalidPolicyAdvancePrecondition
            }
            return .forkDetected(
                currentHead: currentHead,
                competingCommitDigest: candidate.commitDigest
            )
        }
        currentHead = candidate
        committedEntry = try SecretPolicyStoreEntry(
            commit: precondition.validatedSnapshot.commit,
            records: precondition.validatedSnapshot.records,
            credentials: precondition.candidateEntry.credentials,
            trustRecords: precondition.validatedSnapshot.trustedDeviceRecords,
            digester: ProtocolEntryDigester()
        )
        stagedEntry = nil
        return .advanced(candidate)
    }

    func cancelRecoveryAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async -> SecretRecoveryAdvanceCancellationResult {
        precondition.recoveryPublicationCapability == nil
            ? .notRecovery
            : .cancelled
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
        let commitment = try await freshnessAnchor.latestCommitment(
            for: request.scopeID
        )
        precondition(commitment == request.expectedFreshnessCommitment)
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
            provenance: .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: fixtureCredentialID(99),
                    signature: Data([byte &+ 3])
                )
            )
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
    for requirement: PurgeRequirement,
    signerCredentialID: DeviceCredentialID? = nil,
    coveredCategories: [PurgeArtifactCategory]? = nil
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
        coveredCategories: coveredCategories ?? requirement.requiredCategories,
        status: .completed,
        signerCredentialID: signerCredentialID
            ?? requirement.targetCredentialID,
        signature: Data([0x74])
    )
}

private func trustRecord(
    for credential: TrustedDeviceCredential,
    byte: UInt8,
    epoch: UInt64
) throws -> DeviceTrustRecord {
    try DeviceTrustRecord(
        recordDigest: digest(byte),
        credentialDigest: digest(byte &+ 0x20),
        deviceID: credential.deviceID,
        credentialID: credential.credentialID,
        trustState: .trusted,
        effectivePolicyEpoch: epoch
    )
}

private func policyStoreEntry(
    seed: Int = 800,
    byte: UInt8 = 0x80
) throws -> SecretPolicyStoreEntry {
    let scopeID = SecretScopeID(fixtureUUID(seed))
    let generationID = SecretGenerationID(fixtureUUID(seed + 1))
    let credentialID = fixtureCredentialID(seed + 2)
    let activeCredential = try policyEntryCredential(
        deviceID: TrustedDeviceID(fixtureUUID(seed + 5)),
        credentialID: credentialID,
        byte: byte
    )
    let revokedCredential = try policyEntryCredential(
        deviceID: TrustedDeviceID(fixtureUUID(seed + 6)),
        credentialID: fixtureCredentialID(seed + 6),
        byte: byte &+ 1,
        status: .revoked
    )
    let entryDigester = ProtocolEntryDigester()
    let snapshot = try SecretScopeSnapshot(
        scopeID: scopeID,
        rootRecordID: fixtureUUID(seed + 3),
        memberRecordIDs: [fixtureUUID(seed + 3)],
        snapshotDigest: digest(byte)
    )
    let policy = try SecretPolicyEpoch(
        epoch: 1,
        predecessorPolicyDigest: nil,
        scopeSnapshot: snapshot,
        generationID: generationID,
        authorizedRecipientCredentialIDs: [credentialID],
        trustedDeviceRecordDigests: [
            digest(byte &+ 1),
            digest(byte &+ 6),
        ],
        recoveryRecipient: nil,
        signerCredentialID: credentialID
    )
    let signedPolicy = try SignedSecretPolicyEpoch(
        recordDigest: digest(byte &+ 2),
        policy: policy,
        signature: Data([byte &+ 2])
    )
    let payload = try SealedPayload(
        recordDigest: digest(byte &+ 3),
        scopeID: scopeID,
        scopeSnapshotDigest: snapshot.snapshotDigest,
        policyEpoch: 1,
        policyDigest: signedPolicy.recordDigest,
        generationID: generationID,
        formatVersion: 1,
        ciphertextBytes: Data([byte &+ 3])
    )
    let envelope = try RecipientKeyEnvelope(
        recordDigest: digest(byte &+ 4),
        scopeID: scopeID,
        scopeSnapshotDigest: snapshot.snapshotDigest,
        policyEpoch: 1,
        policyDigest: signedPolicy.recordDigest,
        generationID: generationID,
        recipientCredentialID: credentialID,
        formatVersion: 1,
        wrappedKeyBytes: Data([byte &+ 4])
    )
    let records = try SecretControlRecords(
        state: .staged,
        signedPolicy: signedPolicy,
        sealedPayload: payload,
        recipientEnvelopes: [envelope],
        recoveryEnvelope: nil,
        purgeRequirements: [],
        purgeReceipts: [],
        recoveryAuthorization: nil
    )
    let commit = try SecretTransitionCommit(
        recordDigest: digest(byte &+ 5),
        scopeID: scopeID,
        policyEpoch: 1,
        predecessorCommitDigest: nil,
        policyDigest: signedPolicy.recordDigest,
        scopeSnapshotDigest: snapshot.snapshotDigest,
        generationID: generationID,
        sealedPayloadDigest: payload.recordDigest,
        recipientEnvelopeDigests: [envelope.recordDigest],
        recoveryEnvelopeDigest: nil,
        purgeRequirementDigests: [],
        purgeReceiptDigests: [],
        recoveryAuthorizationDigest: nil,
        signerCredentialID: credentialID,
        signature: Data([byte &+ 5])
    )
    let trustRecords = [
        try DeviceTrustRecord(
            recordDigest: digest(byte &+ 1),
            credentialDigest: entryDigester.digest(
                canonicalBytes: activeCredential.canonicalBytes()
            ),
            deviceID: activeCredential.deviceID,
            credentialID: credentialID,
            trustState: .trusted,
            effectivePolicyEpoch: 1
        ),
        try DeviceTrustRecord(
            recordDigest: digest(byte &+ 6),
            credentialDigest: entryDigester.digest(
                canonicalBytes: revokedCredential.canonicalBytes()
            ),
            deviceID: revokedCredential.deviceID,
            credentialID: revokedCredential.credentialID,
            trustState: .revoked,
            effectivePolicyEpoch: 1
        ),
    ]
    return try SecretPolicyStoreEntry(
        commit: commit,
        records: records,
        credentials: [activeCredential, revokedCredential],
        trustRecords: trustRecords,
        digester: entryDigester
    )
}

private func policyEntryCredential(
    deviceID: TrustedDeviceID,
    credentialID: DeviceCredentialID,
    byte: UInt8,
    status: TrustedDeviceCredentialStatus = .active
) throws -> TrustedDeviceCredential {
    try TrustedDeviceCredential(
        deviceID: deviceID,
        credentialID: credentialID,
        credentialVersion: 1,
        status: status,
        signingPublicKey: signingDescriptor(byte),
        keyAgreementPublicKey: agreementDescriptor(byte),
        enrollmentProof: DeviceCredentialEnrollmentProof(
            challengeID: fixtureUUID(990 + Int(byte)),
            challengeBytes: Data([byte &+ 2]),
            signingProofBytes: Data([byte &+ 3]),
            keyAgreementProofBytes: Data([byte &+ 4]),
            provenance: .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: fixtureCredentialID(99),
                    signature: Data([byte &+ 5])
                )
            )
        )
    )
}

private struct ProtocolEntryDigester: SecretSyncDigesting {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        var bytes = [UInt8](repeating: 0, count: SecretRecordDigest.byteCount)
        for (index, byte) in canonicalBytes.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return try SecretRecordDigest(bytes: Data(bytes))
    }
}

private func authoritativeSnapshotFixture(
    for entry: SecretPolicyStoreEntry
) throws -> SecretControlSnapshot {
    try SecretControlSnapshot(
        commit: entry.commit,
        records: entry.records.committedCopy(),
        trustedDeviceRecords: entry.trustRecords
    )
}

private func recoveryRecipient(
    _ suffix: Int
) throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
        recoveryRecipientID: fixtureUUID(500 + suffix),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .agreementAlgorithmIdentifier,
            keyIdentifier: Data([UInt8(80 + suffix)]),
            publicKeyBytes: Data([0x04])
                + Data(repeating: UInt8(81 + suffix), count: 64)
        ),
        authorizationSigningPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: RecoveryRecipientDescriptor
                .authorizationSigningAlgorithmIdentifier,
            keyIdentifier: Data([UInt8(82 + suffix)]),
            publicKeyBytes: Data([0x04])
                + Data(repeating: UInt8(83 + suffix), count: 64)
        )
    )
}
