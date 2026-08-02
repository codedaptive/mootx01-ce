import ConvergenceKit
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
