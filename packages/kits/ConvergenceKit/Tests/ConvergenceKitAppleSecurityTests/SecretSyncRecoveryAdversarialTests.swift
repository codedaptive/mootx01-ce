import ConvergenceKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync recovery adversarial confirmation")
struct SecretSyncRecoveryAdversarialTests {
  @Test("canonical frame rejects duplicate, reordered, truncated, and trailing fields")
  func malformedFrames() throws {
    let valid = try SecretSyncRecoveryFrame.encode([
      .init(tag: 1, value: Data("a".utf8)),
      .init(tag: 2, value: Data("b".utf8)),
    ])
    for mutated in [
      valid + Data([0]),
      Data(valid.dropLast()),
      try frameWithoutSorting(tags: [2, 1]),
      try frameWithoutSorting(tags: [1, 1]),
    ] {
      #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
        _ = try SecretSyncRecoveryFrame.decode(mutated)
      }
    }
  }

  @Test("descriptor, branch, request, challenge, session and token are committed")
  func commitmentBindings() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)

    let wrongRequest = try RecoveryEnrollmentRequest(
      requestID: UUID(),
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: evidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageEnrollment(wrongRequest)
    }

    let mutatedEvidence = try BlindRecoveryConfirmationEvidence(
      recoveryRecipientID: evidence.recoveryRecipientID,
      challengeID: UUID(),
      evidenceBytes: evidence.evidenceBytes
    )
    let wrongChallenge = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: mutatedEvidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageEnrollment(wrongChallenge)
    }
  }

  @Test("every descriptor field is bound even when the recovery UUID is unchanged")
  func descriptorMutations() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let original = handle.recoveryRecipient

    #expect(throws: SecretSyncContractError.self) {
      _ = try RecoveryRecipientDescriptor(
        recoveryRecipientID: original.recoveryRecipientID,
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
          algorithmIdentifier: "changed-agreement",
          keyIdentifier: original.keyAgreementPublicKey.keyIdentifier,
          publicKeyBytes: original.keyAgreementPublicKey.publicKeyBytes
        ),
        authorizationSigningPublicKey: original.authorizationSigningPublicKey
      )
    }

    let variants = try [
      descriptor(
        original,
        agreementID: original.keyAgreementPublicKey.keyIdentifier + Data([1])
      ),
      descriptor(
        original,
        agreementPublic: flipped(original.keyAgreementPublicKey.publicKeyBytes)
      ),
      descriptor(
        original,
        authorizationID:
          original.authorizationSigningPublicKey.keyIdentifier + Data([1])
      ),
      descriptor(
        original,
        authorizationPublic:
          flipped(original.authorizationSigningPublicKey.publicKeyBytes)
      ),
    ]
    for variant in variants {
      let request = try RecoveryEnrollmentRequest(
        requestID: handle.requestID,
        recoveryRecipient: variant,
        blindConfirmation: evidence
      )
      await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
        _ = try await custody.stageEnrollment(request)
      }
    }
  }

  @Test("rotation binds scope, current ID, both generations, and every freshness field")
  func rotationSemanticMutations() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let handle = try await custody.beginRotation(
      requestID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let otherScope = SecretScopeID(UUID())
    let scopeFreshness = try freshness(fixture.freshness, scopeID: otherScope)
    let epochFreshness = try freshness(
      fixture.freshness,
      epoch: fixture.freshness.latestPolicyEpoch + 1
    )
    let headFreshness = try freshness(
      fixture.freshness,
      head: SecretRecordDigest(bytes: Data(repeating: 0x33, count: 32))
    )
    let policyFreshness = try freshness(
      fixture.freshness,
      policy: SecretRecordDigest(bytes: Data(repeating: 0x44, count: 32))
    )
    let cases: [(
      SecretScopeID,
      UUID,
      SecretGenerationID,
      SecretGenerationID,
      SecretBootstrapFreshnessCommitment
    )] = [
      (otherScope, current.recoveryRecipientID, fixture.currentGenerationID, fixture.replacementGenerationID, scopeFreshness),
      (fixture.scopeID, UUID(), fixture.currentGenerationID, fixture.replacementGenerationID, fixture.freshness),
      (fixture.scopeID, current.recoveryRecipientID, SecretGenerationID(UUID()), fixture.replacementGenerationID, fixture.freshness),
      (fixture.scopeID, current.recoveryRecipientID, fixture.currentGenerationID, SecretGenerationID(UUID()), fixture.freshness),
      (fixture.scopeID, current.recoveryRecipientID, fixture.currentGenerationID, fixture.replacementGenerationID, epochFreshness),
      (fixture.scopeID, current.recoveryRecipientID, fixture.currentGenerationID, fixture.replacementGenerationID, headFreshness),
      (fixture.scopeID, current.recoveryRecipientID, fixture.currentGenerationID, fixture.replacementGenerationID, policyFreshness),
    ]
    for (scope, currentID, currentGeneration, replacementGeneration, freshness) in cases {
      let request = try RecoveryRotationRequest(
        requestID: handle.requestID,
        scopeID: scope,
        currentRecoveryRecipientID: currentID,
        replacementRecoveryRecipient: handle.recoveryRecipient,
        currentGenerationID: currentGeneration,
        replacementGenerationID: replacementGeneration,
        expectedFreshnessCommitment: freshness,
        blindConfirmation: evidence
      )
      await #expect(throws: (any Error).self) {
        _ = try await custody.stageRotation(
          request,
          freshnessAnchor: U6BFreshnessAnchor(commitment: freshness)
        )
      }
    }
  }

  @Test("break-glass binds sealed generation and every freshness field")
  func breakGlassSemanticMutations() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try SecretSyncRecoveryMnemonic(masterSeed: Data(0..<32)).canonicalPhrase
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let freshnessVariants = try [
      freshness(fixture.freshness, epoch: 10),
      freshness(
        fixture.freshness,
        head: SecretRecordDigest(bytes: Data(repeating: 0x33, count: 32))
      ),
      freshness(
        fixture.freshness,
        policy: SecretRecordDigest(bytes: Data(repeating: 0x44, count: 32))
      ),
    ]
    for changed in freshnessVariants {
      let request = try BreakGlassRecoveryRequest(
        requestID: handle.requestID,
        scopeID: fixture.scopeID,
        recoveryRecipientID: current.recoveryRecipientID,
        sealedGenerationID: fixture.currentGenerationID,
        expectedFreshnessCommitment: changed,
        blindConfirmation: evidence
      )
      await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
        _ = try await custody.stageBreakGlass(
          request,
          freshnessAnchor: U6BFreshnessAnchor(commitment: changed)
        )
      }
    }
    let wrongGeneration = try BreakGlassRecoveryRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: SecretGenerationID(UUID()),
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: evidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageBreakGlass(
        wrongGeneration,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
  }

  @Test("concurrent duplicate staging yields exactly one success")
  func concurrentDuplicate() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: evidence
    )
    let successes = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 {
        group.addTask {
          do {
            _ = try await custody.stageEnrollment(request)
            return true
          } catch {
            return false
          }
        }
      }
      var values = [Bool]()
      for await value in group { values.append(value) }
      return values.filter { $0 }.count
    }
    #expect(successes == 1)
  }

  @Test("evidence schema, session, token, commitment, tag, and trailing bytes fail closed")
  func evidenceMutations() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let fields = try SecretSyncRecoveryFrame.decode(evidence.evidenceBytes)
    var changedCommitment = fields[3].value
    changedCommitment[0] ^= 1
    let mutations = try [
      SecretSyncRecoveryFrame.encode([
        .init(tag: 1, value: Data("wrong-schema".utf8)),
        fields[1], fields[2], fields[3],
      ]),
      SecretSyncRecoveryFrame.encode([
        fields[0],
        .init(tag: 2, value: SecretSyncRecoveryFrame.uuid(UUID())),
        fields[2], fields[3],
      ]),
      SecretSyncRecoveryFrame.encode([
        fields[0], fields[1],
        .init(tag: 3, value: SecretSyncRecoveryFrame.uuid(UUID())),
        fields[3],
      ]),
      SecretSyncRecoveryFrame.encode([
        fields[0], fields[1], fields[2],
        .init(tag: 4, value: changedCommitment),
      ]),
      SecretSyncRecoveryFrame.encode([
        fields[0], fields[1], fields[2],
        .init(tag: 5, value: fields[3].value),
      ]),
      evidence.evidenceBytes + Data([0]),
    ]
    for bytes in mutations {
      let altered = try BlindRecoveryConfirmationEvidence(
        recoveryRecipientID: evidence.recoveryRecipientID,
        challengeID: evidence.challengeID,
        evidenceBytes: bytes
      )
      let request = try RecoveryEnrollmentRequest(
        requestID: handle.requestID,
        recoveryRecipient: handle.recoveryRecipient,
        blindConfirmation: altered
      )
      await #expect(throws: (any Error).self) {
        _ = try await custody.stageEnrollment(request)
      }
    }
    _ = try await custody.stageEnrollment(
      RecoveryEnrollmentRequest(
        requestID: handle.requestID,
        recoveryRecipient: handle.recoveryRecipient,
        blindConfirmation: evidence
      )
    )
  }

  @Test("confirmation evidence cannot cross enrollment, rotation, or break-glass")
  func crossBranchUse() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)

    let enrollment = try await custody.beginEnrollment(requestID: UUID())
    let enrollmentPhrase = try await custody.revealPhrase(for: enrollment)
    let enrollmentEvidence = try await custody.confirm(
      enrollment,
      phrase: enrollmentPhrase
    )
    let enrollmentAsRotation = try RecoveryRotationRequest(
      requestID: enrollment.requestID,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      replacementRecoveryRecipient: enrollment.recoveryRecipient,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: enrollmentEvidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageRotation(
        enrollmentAsRotation,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }

    let rotation = try await custody.beginRotation(
      requestID: UUID(),
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let rotationPhrase = try await custody.revealPhrase(for: rotation)
    let rotationEvidence = try await custody.confirm(
      rotation,
      phrase: rotationPhrase
    )
    let rotationAsBreakGlass = try BreakGlassRecoveryRequest(
      requestID: rotation.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: rotation.recoveryRecipient.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: rotationEvidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageBreakGlass(
        rotationAsBreakGlass,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }

    let breakGlass = try await custody.beginBreakGlass(
      requestID: UUID(),
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let currentPhrase = try SecretSyncRecoveryMnemonic(
      masterSeed: Data(0..<32)
    ).canonicalPhrase
    let breakGlassEvidence = try await custody.confirm(
      breakGlass,
      phrase: currentPhrase
    )
    let breakGlassAsRotation = try RecoveryRotationRequest(
      requestID: breakGlass.requestID,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      replacementRecoveryRecipient: current,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: breakGlassEvidence
    )
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.stageRotation(
        breakGlassAsRotation,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
  }

  @Test("output failure occurs after irreversible consumption")
  func consumeBeforeOutput() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody(failOutput: true)
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: evidence
    )
    await #expect(throws: SecretSyncRecoveryError.outputFailure) {
      _ = try await custody.stageEnrollment(request)
    }
    #expect(try await custody.globalRecoveryRecipient() == nil)
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.stageEnrollment(request)
    }
  }

  @Test("constant-time equality covers every byte and rejects other lengths")
  func fixedLengthEquality() {
    let original = Data(repeating: 0x5a, count: 32)
    #expect(SecretSyncRecoveryFrame.constantTimeEqual32(original, original))
    for index in 0..<32 {
      var mutated = original
      mutated[index] ^= 1
      #expect(!SecretSyncRecoveryFrame.constantTimeEqual32(original, mutated))
    }
    #expect(!SecretSyncRecoveryFrame.constantTimeEqual32(original, Data(original.dropLast())))
  }

  private func frameWithoutSorting(tags: [UInt16]) throws -> Data {
    var bytes = SecretSyncRecoveryFrame.uint16(UInt16(tags.count))
    for tag in tags {
      bytes.append(SecretSyncRecoveryFrame.uint16(tag))
      bytes.append(SecretSyncRecoveryFrame.uint32(1))
      bytes.append(0)
    }
    return bytes
  }

  private func descriptor(
    _ original: RecoveryRecipientDescriptor,
    agreementID: Data? = nil,
    agreementPublic: Data? = nil,
    authorizationID: Data? = nil,
    authorizationPublic: Data? = nil
  ) throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
      recoveryRecipientID: original.recoveryRecipientID,
      keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: original.keyAgreementPublicKey.algorithmIdentifier,
        keyIdentifier: agreementID ?? original.keyAgreementPublicKey.keyIdentifier,
        publicKeyBytes: agreementPublic ?? original.keyAgreementPublicKey.publicKeyBytes
      ),
      authorizationSigningPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: original.authorizationSigningPublicKey.algorithmIdentifier,
        keyIdentifier: authorizationID ?? original.authorizationSigningPublicKey.keyIdentifier,
        publicKeyBytes: authorizationPublic ?? original.authorizationSigningPublicKey.publicKeyBytes
      )
    )
  }

  private func flipped(_ data: Data) -> Data {
    var data = data
    data[data.count - 1] ^= 1
    return data
  }

  private func freshness(
    _ original: SecretBootstrapFreshnessCommitment,
    scopeID: SecretScopeID? = nil,
    epoch: UInt64? = nil,
    head: SecretRecordDigest? = nil,
    policy: SecretRecordDigest? = nil
  ) throws -> SecretBootstrapFreshnessCommitment {
    try SecretBootstrapFreshnessCommitment(
      scopeID: scopeID ?? original.scopeID,
      latestPolicyEpoch: epoch ?? original.latestPolicyEpoch,
      headCommitDigest: head ?? original.headCommitDigest,
      policyDigest: policy ?? original.policyDigest
    )
  }

  private func enroll(
    _ custody: SecretSyncRecoveryKeyCustody,
    fixture: U6BFixture
  ) async throws -> RecoveryRecipientDescriptor {
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    _ = try await custody.stageEnrollment(
      RecoveryEnrollmentRequest(
        requestID: handle.requestID,
        recoveryRecipient: handle.recoveryRecipient,
        blindConfirmation: evidence
      )
    )
    return handle.recoveryRecipient
  }
}
