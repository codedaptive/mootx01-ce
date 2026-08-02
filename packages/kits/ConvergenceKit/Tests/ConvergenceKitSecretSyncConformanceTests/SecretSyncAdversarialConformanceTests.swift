@testable import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync adversarial conformance")
struct SecretSyncAdversarialConformanceTests {
  @Test("rollback replay fork predecessor and generation reuse fail closed")
  // One shared current head is intentional: changing it between rows would stop
  // this from being a controlled production-validator rejection matrix.
  func monotonicHeadMatrix() throws {
    let current = try U7TransitionFixture.commit(epoch: 2, marker: 0x20)

    #expect(throws: SecretPolicyValidationError.lowerEpoch) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: U7TransitionFixture.commit(
          epoch: 1,
          marker: 0x10,
          predecessor: nil
        ),
        knownCompetingChildDigests: []
      )
    }
    #expect(throws: SecretPolicyValidationError.replayedHead) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: current,
        knownCompetingChildDigests: []
      )
    }
    #expect(throws: SecretPolicyValidationError.sameEpochFork) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: U7TransitionFixture.commit(epoch: 2, marker: 0x21),
        knownCompetingChildDigests: []
      )
    }
    #expect(throws: SecretPolicyValidationError.wrongPredecessor) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: U7TransitionFixture.commit(
          epoch: 3,
          marker: 0x30,
          predecessor: try U7GoldenVectors.digest(0xEE)
        ),
        knownCompetingChildDigests: []
      )
    }
    #expect(throws: SecretPolicyValidationError.generationNotRotated) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: U7TransitionFixture.commit(
          epoch: 3,
          marker: 0x30,
          predecessor: current.recordDigest,
          generationID: current.generationID
        ),
        knownCompetingChildDigests: []
      )
    }
    #expect(throws: SecretPolicyValidationError.samePredecessorForkDecisionRequired) {
      try SecretPolicyValidator.validateMonotonicTransition(
        currentHead: current,
        candidate: U7TransitionFixture.commit(
          epoch: 3,
          marker: 0x31,
          predecessor: current.recordDigest
        ),
        knownCompetingChildDigests: [try U7GoldenVectors.digest(0x32)]
      )
    }
  }

  @Test("scope snapshot policy generation recipient and ciphertext mutations reject")
  // The matrix reuses one HPKE envelope so every rejection differs only in the
  // named authenticated field, keeping cross-row evidence directly comparable.
  func authenticatedBindingMatrix() throws {
    let provider = try SecretSyncV1CryptoProvider(suite: U7GoldenVectors.suite())
    let privateKey = P256.KeyAgreement.PrivateKey()
    let credentialID = DeviceCredentialID(U7UUID.byte(0xD1))
    let base = try U7GoldenVectors.boundContext()
    let generationKey = SecretSyncGenerationKey.generate()
    let envelope = try provider.hpkeEnvelopeProvider.sealGenerationKey(
      generationKey,
      for: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data("adversarial-recipient".utf8),
        publicKeyBytes: privateKey.publicKey.x963Representation
      ),
      context: try U7GoldenVectors.recipientContext(
        credentialID: credentialID,
        boundContext: base
      )
    )
    let mutations = [
      try U7GoldenVectors.boundContext(
        scopeID: SecretScopeID(U7UUID.byte(0x41))
      ),
      try U7GoldenVectors.boundContext(
        snapshotDigest: U7GoldenVectors.digest(0x42)
      ),
      try U7GoldenVectors.boundContext(policyEpoch: 43),
      try U7GoldenVectors.boundContext(
        policyDigest: U7GoldenVectors.digest(0x43)
      ),
      try U7GoldenVectors.boundContext(
        generationID: SecretGenerationID(U7UUID.byte(0x44))
      ),
    ]

    for mutated in mutations {
      #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
        _ = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
          envelope,
          using: privateKey,
          context: try U7GoldenVectors.recipientContext(
            credentialID: credentialID,
            boundContext: mutated
          )
        )
      }
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        envelope,
        using: privateKey,
        context: try U7GoldenVectors.recipientContext(
          credentialID: DeviceCredentialID(U7UUID.byte(0xD2)),
          boundContext: base
        )
      )
    }
    var tampered = envelope
    tampered[tampered.count - 1] ^= 1
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        tampered,
        using: privateKey,
        context: try U7GoldenVectors.recipientContext(
          credentialID: credentialID,
          boundContext: base
        )
      )
    }
  }

  @Test("replacement purge and recovery keys cannot attest or open old work")
  func lostAuthorityRemainsLost() throws {
    let provider = try SecretSyncHPKEEnvelopeProvider(suite: U7GoldenVectors.suite())
    let oldKey = P256.KeyAgreement.PrivateKey()
    let replacementKey = P256.KeyAgreement.PrivateKey()
    let generationKey = SecretSyncGenerationKey.generate()
    let recoveryContext = try U7GoldenVectors.recoveryContext()
    let oldEnvelope = try provider.sealRecoveryGenerationKey(
      generationKey,
      for: try U7GoldenVectors.recoveryDescriptor(
        bytes: oldKey.publicKey.x963Representation
      ),
      context: recoveryContext
    )

    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecoveryGenerationKey(
        oldEnvelope,
        using: replacementKey,
        context: recoveryContext
      )
    }
    try verifyPurgeReceiptBoundary()
  }

  @Test("production purge seam admits only verified complete category receipts")
  func productionPurgeAdmission() async throws {
    let signer = P256.Signing.PrivateKey()
    let verifier = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    let target = DeviceCredentialID(U7UUID.byte(0xE1))
    let publicKey = try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("u7-purge-target".utf8),
      publicKeyBytes: signer.publicKey.x963Representation
    )
    let requirement = try purgeRequirement(target: target)
    let store = U7ProductionPurgeAdmissionStore(
      requirement: requirement, targetPublicKey: publicKey, verifier: verifier
    )
    #expect(try await store.admissionSnapshot(for: target).status == .blocked)

    let signed = try signedPurgeReceipt(
      requirement: requirement, signer: signer, verifier: verifier
    )
    for category in requirement.requiredCategories {
      let categoryReceipt = try PurgeArtifactCategoryReceipt(
        requirement: requirement, category: category, signedReceipt: signed
      )
      #expect(try await store.recordArtifactReceipt(categoryReceipt) == .recorded)
      #expect(
        try await store.recordArtifactReceipt(categoryReceipt)
          == .alreadyRecorded(categoryReceipt)
      )
    }
    #expect(try await store.pendingRequirements(for: target).isEmpty)
    #expect(try await store.admissionSnapshot(for: target).status == .admitted)
  }

  @Test("prompt-free recovery confirmation is fresh exact and one shot")
  func promptFreeRecoveryCustody() async throws {
    let custody = SecretSyncRecoveryKeyCustody()
    let requestID = UUID()
    let handle = try await custody.beginEnrollment(requestID: requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryEnrollmentRequest(
      requestID: requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: confirmation
    )
    let evidence = try await custody.stageEnrollment(request)
    #expect(evidence.requestID == requestID)
    #expect(try await custody.globalRecoveryRecipient() == handle.recoveryRecipient)
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.stageEnrollment(request)
    }

    let commit = try U7TransitionFixture.commit(epoch: 7, marker: 0xA8)
    let exact = try SecretBootstrapFreshnessCommitment(
      scopeID: commit.scopeID, latestPolicyEpoch: commit.policyEpoch,
      headCommitDigest: commit.recordDigest, policyDigest: commit.policyDigest
    )
    let breakGlass = try BreakGlassRecoveryRequest(
      requestID: UUID(), scopeID: commit.scopeID,
      recoveryRecipientID: handle.recoveryRecipient.recoveryRecipientID,
      sealedGenerationID: commit.generationID,
      expectedFreshnessCommitment: exact,
      blindConfirmation: try BlindRecoveryConfirmationEvidence(
        recoveryRecipientID: handle.recoveryRecipient.recoveryRecipientID,
        challengeID: UUID(), evidenceBytes: Data("fresh-confirmation".utf8)
      )
    )
    #expect(breakGlass.expectedFreshnessCommitment == exact)
    #expect(throws: SecretPolicyValidationError.externalFreshnessFork) {
      try SecretPolicyValidator.validateBootstrapFreshness(
        localCommit: commit,
        against: SecretBootstrapFreshnessCommitment(
          scopeID: exact.scopeID, latestPolicyEpoch: exact.latestPolicyEpoch,
          headCommitDigest: U7GoldenVectors.digest(0xA9),
          policyDigest: exact.policyDigest
        )
      )
    }
  }

  @Test("full-loss validator admits the exact fresh signed replacement graph")
  func fullLossRecoveryValidator() throws {
    let fixture = try U7FullLossFixture.make()
    let committed = try fixture.validate()
    #expect(committed.commit.policyEpoch == 2)
    #expect(
      committed.records.signedPolicy.policy.authorizedRecipientCredentialIDs
        == [fixture.replacementCredentialID]
    )
    #expect(
      committed.trustedDeviceRecords.first {
        $0.credentialID == fixture.oldCredentialID
      }?.trustState == .revoked
    )
    #expect(throws: SecretPolicyValidationError.fullLossRecoveryChallengeExpired) {
      _ = try fixture.validate(nowMilliseconds: 2_001)
    }
  }

  @Test("zero trusted devices deny normal admission and require break-glass binding")
  func zeroTrustedDeviceBoundary() throws {
    let fixture = try U7PolicyFixture.make()
    let commit = fixture.entry.commit
    let freshness = try SecretBootstrapFreshnessCommitment(
      scopeID: commit.scopeID,
      latestPolicyEpoch: commit.policyEpoch,
      headCommitDigest: commit.recordDigest,
      policyDigest: commit.policyDigest
    )
    #expect(throws: (any Error).self) {
      _ = try SecretPolicyValidator.validateTransition(
        currentSnapshot: nil,
        stagedRecords: fixture.entry.records,
        commit: commit,
        trustedCredentials: [],
        trustedDeviceRecords: [],
        knownCompetingChildDigests: [],
        externalFreshness: freshness,
        digester: SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite()),
        signatureVerifier: U7RejectingSignatureVerifier()
      )
    }
    try verifyBreakGlassRequestBinding(commit: commit, freshness: freshness)
  }

  private func verifyPurgeReceiptBoundary() throws {
    let target = DeviceCredentialID(U7UUID.byte(0xE1))
    let requirement = try PurgeRequirement(
      recordDigest: U7GoldenVectors.digest(0xE2),
      scopeID: U7GoldenVectors.scopeID,
      policyEpoch: 2,
      policyDigest: U7GoldenVectors.digest(0xE3),
      supersededGenerationID: SecretGenerationID(U7UUID.byte(0xE4)),
      replacementGenerationID: SecretGenerationID(U7UUID.byte(0xE5)),
      targetCredentialID: target,
      requiredCategories: PurgeArtifactCategory.allCases
    )
    let partial = try purgeReceipt(requirement: requirement, status: .partial)
    #expect(throws: SecretSyncInterfaceError.invalidPurgeReceipt) {
      _ = try PurgeArtifactCategoryReceipt(
        requirement: requirement, category: .plaintext, signedReceipt: partial
      )
    }
    let wrongSigner = try purgeReceipt(
      requirement: requirement,
      status: .completed,
      signer: DeviceCredentialID(U7UUID.byte(0xE6))
    )
    #expect(throws: SecretSyncInterfaceError.invalidPurgeReceipt) {
      _ = try PurgeArtifactCategoryReceipt(
        requirement: requirement, category: .plaintext, signedReceipt: wrongSigner
      )
    }
  }

  private func purgeReceipt(
    requirement: PurgeRequirement,
    status: PurgeReceiptStatus,
    signer: DeviceCredentialID? = nil
  ) throws -> SignedPurgeReceipt {
    try SignedPurgeReceipt(
      recordDigest: U7GoldenVectors.digest(0xE7),
      requirementDigest: requirement.recordDigest,
      scopeID: requirement.scopeID,
      policyEpoch: requirement.policyEpoch,
      policyDigest: requirement.policyDigest,
      supersededGenerationID: requirement.supersededGenerationID,
      replacementGenerationID: requirement.replacementGenerationID,
      respondingCredentialID: requirement.targetCredentialID,
      coveredCategories: requirement.requiredCategories,
      status: status,
      signerCredentialID: signer ?? requirement.targetCredentialID,
      signature: Data([0xA1])
    )
  }

  private func purgeRequirement(
    target: DeviceCredentialID
  ) throws -> PurgeRequirement {
    try PurgeRequirement(
      recordDigest: U7GoldenVectors.digest(0xE2), scopeID: U7GoldenVectors.scopeID,
      policyEpoch: 2, policyDigest: U7GoldenVectors.digest(0xE3),
      supersededGenerationID: SecretGenerationID(U7UUID.byte(0xE4)),
      replacementGenerationID: SecretGenerationID(U7UUID.byte(0xE5)),
      targetCredentialID: target, requiredCategories: PurgeArtifactCategory.allCases
    )
  }

  private func signedPurgeReceipt(
    requirement: PurgeRequirement,
    signer: P256.Signing.PrivateKey,
    verifier: SecretSyncP256SignatureProvider
  ) throws -> SignedPurgeReceipt {
    func build(_ digest: SecretRecordDigest, _ signature: Data) throws -> SignedPurgeReceipt {
      try SignedPurgeReceipt(
        recordDigest: digest, requirementDigest: requirement.recordDigest,
        scopeID: requirement.scopeID, policyEpoch: requirement.policyEpoch,
        policyDigest: requirement.policyDigest,
        supersededGenerationID: requirement.supersededGenerationID,
        replacementGenerationID: requirement.replacementGenerationID,
        respondingCredentialID: requirement.targetCredentialID,
        coveredCategories: requirement.requiredCategories, status: .completed,
        signerCredentialID: requirement.targetCredentialID, signature: signature
      )
    }
    let provisional = try build(U7GoldenVectors.digest(0), Data([0]))
    let signature = try verifier.sign(
      canonicalBytes: provisional.signingBytes(), using: signer
    )
    let signed = try build(U7GoldenVectors.digest(0), signature)
    let digest = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
      .digest(canonicalBytes: signed.canonicalBytes())
    return try build(digest, signature)
  }

  private func verifyBreakGlassRequestBinding(
    commit: SecretTransitionCommit,
    freshness: SecretBootstrapFreshnessCommitment
  ) throws {
    let recipientID = U7UUID.byte(0xE8)
    let confirmation = try BlindRecoveryConfirmationEvidence(
      recoveryRecipientID: recipientID,
      challengeID: U7UUID.byte(0xE9),
      evidenceBytes: Data([0xEA])
    )
    _ = try BreakGlassRecoveryRequest(
      requestID: U7UUID.byte(0xEB),
      scopeID: commit.scopeID,
      recoveryRecipientID: recipientID,
      sealedGenerationID: commit.generationID,
      expectedFreshnessCommitment: freshness,
      blindConfirmation: confirmation
    )
    #expect(throws: SecretSyncInterfaceError.recoveryRecipientMismatch) {
      _ = try BreakGlassRecoveryRequest(
        requestID: U7UUID.byte(0xEC),
        scopeID: SecretScopeID(U7UUID.byte(0xED)),
        recoveryRecipientID: recipientID,
        sealedGenerationID: commit.generationID,
        expectedFreshnessCommitment: freshness,
        blindConfirmation: confirmation
      )
    }
  }
}

private actor U7ProductionPurgeAdmissionStore: SecretSyncPurgeStore {
  let requirement: PurgeRequirement
  let targetPublicKey: SigningPublicKeyDescriptor
  let verifier: SecretSyncP256SignatureProvider
  var receipts: [PurgeArtifactReceiptKey: PurgeArtifactCategoryReceipt] = [:]

  init(
    requirement: PurgeRequirement,
    targetPublicKey: SigningPublicKeyDescriptor,
    verifier: SecretSyncP256SignatureProvider
  ) {
    self.requirement = requirement
    self.targetPublicKey = targetPublicKey
    self.verifier = verifier
  }

  func pendingRequirements(
    for credentialID: DeviceCredentialID
  ) async throws -> [PurgeRequirement] {
    guard credentialID == requirement.targetCredentialID else { return [] }
    return hasEveryCategory ? [] : [requirement]
  }

  func recordArtifactReceipt(
    _ receipt: PurgeArtifactCategoryReceipt
  ) async throws -> PurgeArtifactReceiptRecordingResult {
    guard receipt.key.requirementDigest == requirement.recordDigest,
      try verifier.verify(
        signature: receipt.signedReceipt.signature,
        canonicalBytes: receipt.signedReceipt.signingBytes(),
        signingPublicKey: targetPublicKey
      )
    else { throw SecretSyncInterfaceError.invalidPurgeReceipt }
    if let existing = receipts[receipt.key] { return .alreadyRecorded(existing) }
    receipts[receipt.key] = receipt
    return .recorded
  }

  func admissionSnapshot(
    for credentialID: DeviceCredentialID
  ) async throws -> PurgeAdmissionSnapshot {
    guard credentialID == requirement.targetCredentialID else {
      return try PurgeAdmissionSnapshot()
    }
    return try PurgeAdmissionSnapshot(
      status: hasEveryCategory ? .admitted : .blocked,
      pendingRequirementDigests: hasEveryCategory ? [] : [requirement.recordDigest]
    )
  }

  private var hasEveryCategory: Bool {
    Set(receipts.keys.map(\.category)) == Set(requirement.requiredCategories)
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

private struct U7FullLossFixture {
    static let appNamespace = "com.codedaptive.fulcrum.tests"
    static let estateID = u7RecoveryUUID(400)

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
    ) throws -> U7FullLossFixture {
        // Full-loss admission is one atomic transcript spanning the current
        // graph, replacement graph, purge tombstones, and authorization. This
        // deliberately mirrors that closure in one fixture constructor so a
        // test cannot accidentally validate pieces from different attempts.
        let digester = U7RecoveryAuthorityDigester()
        let scopeID = SecretScopeID(u7RecoveryUUID(401))
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
        let currentGeneration = SecretGenerationID(u7RecoveryUUID(405))
        let currentScope = try addressed(digester) { snapshotDigest in
            try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: u7RecoveryUUID(406),
                memberRecordIDs: [u7RecoveryUUID(406)],
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
            requestID: u7RecoveryUUID(410),
            challengeID: u7RecoveryUUID(411),
            sessionID: u7RecoveryUUID(412),
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
            : SecretGenerationID(u7RecoveryUUID(414))
        let candidateScope = try addressed(digester) { snapshotDigest in
            try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: u7RecoveryUUID(406),
                memberRecordIDs: [u7RecoveryUUID(406)],
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
        return try U7FullLossFixture(
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
        recoveryVerifier: U7RecoveryAuthorityVerifier? = nil
    ) throws -> SecretControlSnapshot {
        try SecretPolicyValidator.validateFullLossRecoveryTransition(
            currentSnapshot: currentSnapshot ?? self.currentSnapshot,
            preparedTransition: prepared,
            knownCompetingChildDigests: knownCompetingChildDigests,
            externalFreshness: externalFreshness,
            appNamespace: Self.appNamespace,
            estateID: Self.estateID,
            nowMilliseconds: nowMilliseconds,
            digester: U7RecoveryAuthorityDigester(),
            signatureVerifier: U7ReplacementSignatureVerifier(),
            recoveryVerifier: recoveryVerifier
                ?? U7RecoveryAuthorityVerifier(
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
        deviceID: TrustedDeviceID(u7RecoveryUUID(device)),
        credentialID: DeviceCredentialID(u7RecoveryUUID(credential)),
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
            challengeID: u7RecoveryUUID(credential + 100),
            challengeBytes: Data([byte &+ 2]),
            signingProofBytes: Data([byte &+ 3]),
            keyAgreementProofBytes: Data([byte &+ 4]),
            provenance: .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: DeviceCredentialID(u7RecoveryUUID(499)),
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
        : TrustedDeviceID(u7RecoveryUUID(415))
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
        credentialID: DeviceCredentialID(u7RecoveryUUID(416)),
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
                    recoveryRecipientID: u7RecoveryUUID(404)
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
        : u7RecoveryUUID(413)
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
        recoveryRecipientID: u7RecoveryUUID(id),
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
    _ digester: U7RecoveryAuthorityDigester,
    build: (SecretRecordDigest) throws -> T
) throws -> T {
    let zero = try digest(0)
    let provisional = try build(zero)
    return try build(
        digester.digest(canonicalBytes: provisional.canonicalBytes())
    )
}

private struct U7RecoveryAuthorityDigester: SecretSyncDigesting {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        var bytes = [UInt8](repeating: 0, count: SecretRecordDigest.byteCount)
        for (index, byte) in canonicalBytes.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return try SecretRecordDigest(bytes: Data(bytes))
    }
}

private struct U7ReplacementSignatureVerifier: SecretSignatureVerifying {
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

private struct U7RecoveryAuthorityVerifier: FullLossRecoveryProofVerifying {
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

private func u7RecoveryUUID(_ suffix: Int) -> UUID {
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



private struct U7RejectingSignatureVerifier: SecretSignatureVerifying {
  func verify(
    signature: Data,
    canonicalBytes: Data,
    signingPublicKey: SigningPublicKeyDescriptor
  ) throws -> Bool { false }
}

enum U7TransitionFixture {
  static func commit(
    epoch: UInt64,
    marker: UInt8,
    predecessor: SecretRecordDigest? = nil,
    generationID: SecretGenerationID? = nil
  ) throws -> SecretTransitionCommit {
    try SecretTransitionCommit(
      recordDigest: U7GoldenVectors.digest(marker),
      scopeID: U7GoldenVectors.scopeID,
      policyEpoch: epoch,
      predecessorCommitDigest: epoch == 1 ? nil : predecessor ?? U7GoldenVectors.digest(0x10),
      policyDigest: U7GoldenVectors.digest(marker &+ 1),
      scopeSnapshotDigest: U7GoldenVectors.snapshotDigest,
      generationID: generationID ?? SecretGenerationID(U7UUID.byte(marker)),
      sealedPayloadDigest: U7GoldenVectors.digest(marker &+ 2),
      recipientEnvelopeDigests: [U7GoldenVectors.digest(marker &+ 3)],
      recoveryEnvelopeDigest: U7GoldenVectors.digest(marker &+ 4),
      purgeRequirementDigests: [],
      purgeReceiptDigests: [],
      recoveryAuthorizationDigest: nil,
      signerCredentialID: U7GoldenVectors.recipientCredentialID,
      signature: Data([marker])
    )
  }
}
