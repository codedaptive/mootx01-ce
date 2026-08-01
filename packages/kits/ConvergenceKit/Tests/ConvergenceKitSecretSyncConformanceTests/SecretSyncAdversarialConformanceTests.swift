import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync adversarial conformance")
struct SecretSyncAdversarialConformanceTests {
  @Test("rollback replay fork predecessor and generation reuse fail closed")
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
    #expect(try PurgeAdmissionSnapshot().status == .blocked)
  }
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
