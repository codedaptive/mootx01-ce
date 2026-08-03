import ConvergenceKit
import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync recovery rotation and break-glass")
struct SecretSyncRecoveryRotationTests {
  @Test("ordinary rotation uses normal evidence and replaces active custody")
  func ordinaryRotation() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let enrolled = try await enroll(custody, fixture: fixture)
    let handle = try await custody.beginRotation(
      requestID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: enrolled.recoveryRecipientID,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try await custody.revealPhrase(for: handle)
    let rotationBranch = SecretSyncRecoveryBranch.rotation(
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: enrolled.recoveryRecipientID,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      freshness: fixture.freshness
    )
    let transcript = try SecretSyncRecoveryKeyCustody.transcript(
      handle: handle,
      branch: rotationBranch,
      descriptor: handle.recoveryRecipient
    )
    #expect(transcript.count == 813)
    #expect(
      Data(SHA256.hash(data: transcript))
        == u6Hex("d12cd9c9708313efb5af9ac63d2d17bf0963d00ebf2e89a0ab4cdb863f8c50fd")
    )
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryRotationRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: enrolled.recoveryRecipientID,
      replacementRecoveryRecipient: handle.recoveryRecipient,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmation
    )
    let output = try await custody.stageRotation(
      request,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
    let outputFields = try SecretSyncRecoveryFrame.decode(output.evidenceBytes)
    #expect(outputFields.map(\.tag) == [1, 2, 3, 4, 5])
    #expect(try await custody.globalRecoveryRecipient() == handle.recoveryRecipient)
  }

  @Test("protocol break-glass evidence is unsigned custody material")
  func breakGlassCustodyEvidence() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let phrase = try SecretSyncRecoveryMnemonic(masterSeed: Data(0..<32)).canonicalPhrase
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    // The pre-confirmation transcript: what `beginBreakGlass` commits to,
    // before any intent exists to bind. Its framing is unchanged, so the
    // frozen length and digest still hold.
    let breakGlassBranch = SecretSyncRecoveryBranch.breakGlass(
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      freshness: fixture.freshness,
      intentDigest: nil
    )
    let transcript = try SecretSyncRecoveryKeyCustody.transcript(
      handle: handle,
      branch: breakGlassBranch,
      descriptor: current
    )
    #expect(transcript.count == 794)
    #expect(
      Data(SHA256.hash(data: transcript))
        == u6Hex("eec3b1352c7d17d4b60da2858b86d863d7a84eb674e9cd48498513934c87019d")
    )
    let intent = try makeU6BIntent(
      fixture: fixture,
      handle: handle,
      current: current
    )
    let intentDigest = Data(SHA256.hash(data: try intent.canonicalBytes()))
    // The bound transcript adds tag 13: two bytes of tag, four of length, and
    // the 32-byte digest. A bound confirmation and an unbound one are
    // therefore different transcripts, which is what stops either standing in
    // for the other.
    let boundTranscript = try SecretSyncRecoveryKeyCustody.transcript(
      handle: handle,
      branch: SecretSyncRecoveryBranch.breakGlass(
        scopeID: fixture.scopeID,
        currentRecoveryRecipientID: current.recoveryRecipientID,
        sealedGenerationID: fixture.currentGenerationID,
        freshness: fixture.freshness,
        intentDigest: intentDigest
      ),
      descriptor: current
    )
    #expect(boundTranscript.count == transcript.count + 38)
    #expect(boundTranscript.count == 832)
    #expect(boundTranscript != transcript)
    #expect(boundTranscript.suffix(32) == intentDigest)
    let confirmation = try await custody.confirmBreakGlass(
      handle,
      phrase: phrase,
      intent: intent
    )
    let request = try BreakGlassRecoveryRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmation
    )
    let output = try await custody.stageBreakGlass(
      request,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
    let outputFields = try SecretSyncRecoveryFrame.decode(output.evidenceBytes)
    #expect(outputFields.map(\.tag) == [1, 2, 3, 4, 5])
    #expect(try await custody.globalRecoveryRecipient() == current)
  }

  @Test("explicit break-glass signs only the exact U6A intent")
  func breakGlassAuthorization() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let phrase = try SecretSyncRecoveryMnemonic(
      masterSeed: Data(0..<32)
    ).canonicalPhrase
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(uuidString: "61000000-0000-0000-0000-000000000006")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let intent = try makeU6BIntent(
      fixture: fixture,
      handle: handle,
      current: current
    )
    let confirmation = try await custody.confirmBreakGlass(
      handle,
      phrase: phrase,
      intent: intent
    )
    let request = try BreakGlassRecoveryRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmation
    )
    let evidence = try await custody.stageBreakGlassAuthorization(
      request,
      intent: intent,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )

    #expect(evidence.intent == intent)
    #expect(evidence.signature.count == 64)
    let signature = try P256.Signing.ECDSASignature(
      rawRepresentation: evidence.signature
    )
    let publicKey = try P256.Signing.PublicKey(
      x963Representation: current.authorizationSigningPublicKey.publicKeyBytes
    )
    #expect(
      publicKey.isValidSignature(
        signature,
        for: try intent.canonicalBytes()
      )
    )
    let alteredIntent = try makeU6BIntent(
      fixture: fixture,
      handle: handle,
      current: current,
      estateID: UUID(
        uuidString: "63000000-0000-0000-0000-000000000007"
      )!
    )
    #expect(
      !publicKey.isValidSignature(
        signature,
        for: try alteredIntent.canonicalBytes()
      )
    )
    let authorization = try FullLossRecoveryAuthorization(
      recordDigest: SecretRecordDigest(bytes: Data(repeating: 0xee, count: 32)),
      intent: evidence.intent,
      signature: evidence.signature
    )
    #expect(try authorization.signingBytes() == intent.canonicalBytes())
  }

  @Test("stale external freshness rejects without consuming confirmation")
  func staleFreshness() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let handle = try await custody.beginRotation(
      requestID: UUID(),
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try await custody.revealPhrase(for: handle)
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryRotationRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      replacementRecoveryRecipient: handle.recoveryRecipient,
      currentGenerationID: fixture.currentGenerationID,
      replacementGenerationID: fixture.replacementGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmation
    )
    let stale = try SecretBootstrapFreshnessCommitment(
      scopeID: fixture.scopeID,
      latestPolicyEpoch: 10,
      headCommitDigest: fixture.freshness.headCommitDigest,
      policyDigest: fixture.freshness.policyDigest
    )
    await #expect(throws: SecretSyncRecoveryError.freshnessMismatch) {
      _ = try await custody.stageRotation(
        request,
        freshnessAnchor: U6BFreshnessAnchor(commitment: stale)
      )
    }
    _ = try await custody.stageRotation(
      request,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
  }

  @Test("break-glass intent bindings reject substitution before consumption")
  func breakGlassIntentBindings() async throws {
    for mutation in U6BIntentMutation.allCases {
      let fixture = U6BFixture()
      let custody = fixture.custody()
      let current = try await enroll(custody, fixture: fixture)
      let handle = try await custody.beginBreakGlass(
        requestID: UUID(
          uuidString: "66000000-0000-0000-0000-000000000006"
        )!,
        scopeID: fixture.scopeID,
        currentRecoveryRecipient: current,
        sealedGenerationID: fixture.currentGenerationID,
        expectedFreshnessCommitment: fixture.freshness
      )
      let phrase = try SecretSyncRecoveryMnemonic(
        masterSeed: Data(0..<32)
      ).canonicalPhrase
      // The user confirms this exact intent, and nothing else may be signed.
      let exactIntent = try makeU6BIntent(
        fixture: fixture,
        handle: handle,
        current: current
      )
      let confirmation = try await custody.confirmBreakGlass(
        handle,
        phrase: phrase,
        intent: exactIntent
      )
      let request = try BreakGlassRecoveryRequest(
        requestID: handle.requestID,
        scopeID: fixture.scopeID,
        recoveryRecipientID: current.recoveryRecipientID,
        sealedGenerationID: fixture.currentGenerationID,
        expectedFreshnessCommitment: fixture.freshness,
        blindConfirmation: confirmation
      )
      let alternateDescriptor = try SecretSyncRecoverySeedDerivation().derive(
        masterSeed: Data((1...32).map(UInt8.init)),
        recoveryRecipientID: current.recoveryRecipientID
      ).descriptor
      let changedDigest = try SecretRecordDigest(
        bytes: Data(repeating: 0x99, count: 32)
      )
      let changedIntent: GlobalRecoveryTransitionIntent
      switch mutation {
      case .request:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          challengeRequestID: UUID()
        )
      case .challenge:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          challengeID: UUID()
        )
      case .session:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          sessionID: UUID()
        )
      case .scope:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          scopeID: SecretScopeID(UUID())
        )
      case .generation:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          currentGenerationID: SecretGenerationID(UUID())
        )
      case .descriptor:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          currentRecoveryRecipient: alternateDescriptor
        )
      case .epoch:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          currentPolicyEpoch: fixture.freshness.latestPolicyEpoch + 1
        )
      case .commit:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          currentCommitDigest: changedDigest
        )
      case .policy:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          currentPolicyDigest: changedDigest
        )
      case .appNamespace:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          appNamespace: "com.codedaptive.mootx01.attacker"
        )
      case .estateID:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          estateID: UUID()
        )
      case .replacementDeviceID:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          replacementDeviceID: TrustedDeviceID(UUID())
        )
      case .replacementCredentialID:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          replacementCredentialID: DeviceCredentialID(UUID())
        )
      case .replacementSigningPublicKey:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          replacementSigningPublicKey: SigningPublicKeyDescriptor(
            algorithmIdentifier: "mootx01.test.replacement-signing.v1",
            keyIdentifier: Data(repeating: 0x81, count: 32),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x82, count: 64)
          )
        )
      case .replacementAgreementPublicKey:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          replacementAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "mootx01.test.replacement-agreement.v1",
            keyIdentifier: Data(repeating: 0x91, count: 32),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x92, count: 64)
          )
        )
      case .signingPossessionProof:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          signingPossessionProof: Data([0x7A])
        )
      case .agreementPossessionProof:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          agreementPossessionProof: Data([0x7B])
        )
      case .candidateGenerationID:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          candidateGenerationID: SecretGenerationID(UUID())
        )
      case .replacementRecoveryRecipient:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          replacementRecoveryRecipient: alternateDescriptor
        )
      case .candidateSignedPolicyDigest:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          candidateSignedPolicyDigest: changedDigest
        )
      case .recoveryEnvelopeDigest:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          recoveryEnvelopeDigest: changedDigest
        )
      case .candidateSemantics:
        changedIntent = try makeU6BIntent(
          fixture: fixture, handle: handle, current: current,
          candidateScopeSnapshotDigest: changedDigest
        )
      }
      #expect(changedIntent != exactIntent)
      await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
        _ = try await custody.stageBreakGlassAuthorization(
          request,
          intent: changedIntent,
          freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
        )
      }
      // Rejection is non-consuming: the intent the user actually confirmed
      // still signs, and the signature verifies against the current recovery
      // authorization key over exactly those bytes.
      let evidence = try await custody.stageBreakGlassAuthorization(
        request,
        intent: exactIntent,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
      #expect(evidence.intent == exactIntent)
      let publicKey = try P256.Signing.PublicKey(
        x963Representation: current.authorizationSigningPublicKey.publicKeyBytes
      )
      #expect(
        publicKey.isValidSignature(
          try P256.Signing.ECDSASignature(
            rawRepresentation: evidence.signature
          ),
          for: try exactIntent.canonicalBytes()
        )
      )
      #expect(
        !publicKey.isValidSignature(
          try P256.Signing.ECDSASignature(
            rawRepresentation: evidence.signature
          ),
          for: try changedIntent.canonicalBytes()
        )
      )
    }
  }

  @Test("the warning acknowledgement is not a substitutable field")
  func warningAcknowledgementIsNotSubstitutable() throws {
    // `warning` is listed as substitution-sensitive, but all three of its
    // components are pinned by the contract, so a substituted warning is not
    // constructible in the first place — there is no mutated intent for the
    // digest to reject. This records that fact where the other substitution
    // cases live, so its absence from `U6BIntentMutation` reads as covered
    // rather than missed.
    #expect(throws: FullLossRecoveryContractError.invalidWarningAcknowledgement) {
      _ = try FullLossRecoveryWarningAcknowledgement(
        acknowledgement: "acknowledged-nothing-at-all"
      )
    }
    #expect(throws: FullLossRecoveryContractError.invalidWarningAcknowledgement) {
      _ = try FullLossRecoveryWarningAcknowledgement(
        semanticIdentifier: "mootx01.attacker.warning",
        acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
      )
    }
    #expect(throws: FullLossRecoveryContractError.invalidWarningAcknowledgement) {
      _ = try FullLossRecoveryWarningAcknowledgement(
        version: 0xFFFF,
        acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
      )
    }
  }

  @Test("break-glass cannot be confirmed without binding an intent")
  func breakGlassRefusesUnboundConfirmation() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(uuidString: "69000000-0000-0000-0000-000000000006")!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try SecretSyncRecoveryMnemonic(
      masterSeed: Data(0..<32)
    ).canonicalPhrase
    // There is no intent-free way to confirm a break-glass ceremony, so an
    // unbound confirmation cannot be produced and then laundered onto either
    // stage path.
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.confirm(handle, phrase: phrase)
    }
    // Nor can the break-glass entry point admit a ceremony of another branch.
    let enrollment = try await custody.beginEnrollment(requestID: UUID())
    let enrollmentPhrase = try await custody.revealPhrase(for: enrollment)
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.confirmBreakGlass(
        enrollment,
        phrase: enrollmentPhrase,
        intent: makeU6BIntent(
          fixture: fixture,
          handle: handle,
          current: current
        )
      )
    }
    // The refused confirmation did not spend the ceremony: it still confirms
    // and stages normally once an intent is bound to it.
    let intent = try makeU6BIntent(
      fixture: fixture,
      handle: handle,
      current: current
    )
    let confirmation = try await custody.confirmBreakGlass(
      handle,
      phrase: phrase,
      intent: intent
    )
    let request = try BreakGlassRecoveryRequest(
      requestID: handle.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmation
    )
    let evidence = try await custody.stageBreakGlassAuthorization(
      request,
      intent: intent,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
    #expect(evidence.intent == intent)
  }

  @Test("unsigned and authorization break-glass paths share one terminal token")
  func breakGlassCrossMethodReplay() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let handle = try await confirmedBreakGlass(
      custody,
      fixture: fixture,
      current: current
    )
    let request = try breakGlassRequest(
      handle,
      fixture: fixture,
      current: current
    )
    _ = try await custody.stageBreakGlassAuthorization(
      request,
      intent: handle.intent,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.stageBreakGlass(
        request,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }

    let second = fixture.custody()
    let secondCurrent = try await enroll(second, fixture: fixture)
    let secondHandle = try await confirmedBreakGlass(
      second,
      fixture: fixture,
      current: secondCurrent
    )
    let secondRequest = try breakGlassRequest(
      secondHandle,
      fixture: fixture,
      current: secondCurrent
    )
    _ = try await second.stageBreakGlass(
      secondRequest,
      freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
    )
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await second.stageBreakGlassAuthorization(
        secondRequest,
        intent: secondHandle.intent,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
  }

  @Test("coordinated request and intent substitutions fail at live custody")
  func coordinatedBreakGlassSubstitutions() async throws {
    for mutation in U6BCoordinatedMutation.allCases {
      let fixture = U6BFixture()
      let custody = fixture.custody()
      let current = try await enroll(custody, fixture: fixture)
      let confirmed = try await confirmedBreakGlass(
        custody,
        fixture: fixture,
        current: current
      )
      let exactRequest = try breakGlassRequest(
        confirmed,
        fixture: fixture,
        current: current
      )
      let exactIntent = confirmed.intent

      var changedRequestID = exactRequest.requestID
      var changedScope = exactRequest.scopeID
      var changedRecoveryID = exactRequest.recoveryRecipientID
      var changedGeneration = exactRequest.sealedGenerationID
      var changedFreshness = exactRequest.expectedFreshnessCommitment
      var changedEvidence = exactRequest.blindConfirmation
      var changedIntent = exactIntent

      switch mutation {
      case .request:
        changedRequestID = UUID()
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          challengeRequestID: changedRequestID
        )
      case .scope:
        changedScope = SecretScopeID(UUID())
        changedFreshness = try SecretBootstrapFreshnessCommitment(
          scopeID: changedScope,
          latestPolicyEpoch: fixture.freshness.latestPolicyEpoch,
          headCommitDigest: fixture.freshness.headCommitDigest,
          policyDigest: fixture.freshness.policyDigest
        )
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          scopeID: changedScope
        )
      case .generation:
        changedGeneration = SecretGenerationID(UUID())
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          currentGenerationID: changedGeneration
        )
      case .freshnessEpoch:
        changedFreshness = try changedU6BFreshness(
          fixture.freshness,
          epoch: fixture.freshness.latestPolicyEpoch + 1
        )
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          currentPolicyEpoch: changedFreshness.latestPolicyEpoch
        )
      case .freshnessHead:
        let digest = try SecretRecordDigest(
          bytes: Data(repeating: 0xa1, count: 32)
        )
        changedFreshness = try changedU6BFreshness(
          fixture.freshness,
          head: digest
        )
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          currentCommitDigest: digest
        )
      case .freshnessPolicy:
        let digest = try SecretRecordDigest(
          bytes: Data(repeating: 0xa2, count: 32)
        )
        changedFreshness = try changedU6BFreshness(
          fixture.freshness,
          policy: digest
        )
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          currentPolicyDigest: digest
        )
      case .recoveryIdentity:
        changedRecoveryID = UUID()
        let changedDescriptor = try RecoveryRecipientDescriptor(
          recoveryRecipientID: changedRecoveryID,
          keyAgreementPublicKey: current.keyAgreementPublicKey,
          authorizationSigningPublicKey:
            current.authorizationSigningPublicKey
        )
        changedEvidence = try BlindRecoveryConfirmationEvidence(
          recoveryRecipientID: changedRecoveryID,
          challengeID: confirmed.evidence.challengeID,
          evidenceBytes: confirmed.evidence.evidenceBytes
        )
        changedIntent = try makeU6BIntent(
          fixture: fixture,
          handle: confirmed.handle,
          current: current,
          currentRecoveryRecipient: changedDescriptor
        )
      }
      let changedRequest = try BreakGlassRecoveryRequest(
        requestID: changedRequestID,
        scopeID: changedScope,
        recoveryRecipientID: changedRecoveryID,
        sealedGenerationID: changedGeneration,
        expectedFreshnessCommitment: changedFreshness,
        blindConfirmation: changedEvidence
      )
      await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
        _ = try await custody.stageBreakGlassAuthorization(
          changedRequest,
          intent: changedIntent,
          freshnessAnchor: U6BFreshnessAnchor(commitment: changedFreshness)
        )
      }
      _ = try await custody.stageBreakGlassAuthorization(
        exactRequest,
        intent: exactIntent,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
  }

  @Test("concurrent break-glass paths admit exactly one terminal operation")
  func breakGlassConcurrentCrossMethod() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let current = try await enroll(custody, fixture: fixture)
    let confirmed = try await confirmedBreakGlass(
      custody,
      fixture: fixture,
      current: current
    )
    let request = try breakGlassRequest(
      confirmed,
      fixture: fixture,
      current: current
    )
    let intent = confirmed.intent
    let successes = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        do {
          _ = try await custody.stageBreakGlass(
            request,
            freshnessAnchor: U6BFreshnessAnchor(
              commitment: fixture.freshness
            )
          )
          return true
        } catch {
          return false
        }
      }
      group.addTask {
        do {
          _ = try await custody.stageBreakGlassAuthorization(
            request,
            intent: intent,
            freshnessAnchor: U6BFreshnessAnchor(
              commitment: fixture.freshness
            )
          )
          return true
        } catch {
          return false
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }
    #expect(successes == 1)
  }

  @Test("authorization output failure occurs after irreversible consumption")
  func breakGlassAuthorizationOutputFailure() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody(failOutput: true)
    let current = try SecretSyncRecoverySeedDerivation().derive(
      masterSeed: Data(0..<32),
      recoveryRecipientID: UUID(
        uuidString: "67000000-0000-0000-0000-000000000006"
      )!
    ).descriptor
    let confirmed = try await confirmedBreakGlass(
      custody,
      fixture: fixture,
      current: current
    )
    let request = try breakGlassRequest(
      confirmed,
      fixture: fixture,
      current: current
    )
    let intent = confirmed.intent
    await #expect(throws: SecretSyncRecoveryError.outputFailure) {
      _ = try await custody.stageBreakGlassAuthorization(
        request,
        intent: intent,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.stageBreakGlassAuthorization(
        request,
        intent: intent,
        freshnessAnchor: U6BFreshnessAnchor(commitment: fixture.freshness)
      )
    }
  }

  private func enroll(
    _ custody: SecretSyncRecoveryKeyCustody,
    fixture: U6BFixture
  ) async throws -> RecoveryRecipientDescriptor {
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    _ = try await custody.stageEnrollment(
      RecoveryEnrollmentRequest(
        requestID: handle.requestID,
        recoveryRecipient: handle.recoveryRecipient,
        blindConfirmation: confirmation
      )
    )
    return handle.recoveryRecipient
  }

  private func confirmedBreakGlass(
    _ custody: SecretSyncRecoveryKeyCustody,
    fixture: U6BFixture,
    current: RecoveryRecipientDescriptor
  ) async throws -> U6BConfirmedBreakGlass {
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(
        uuidString: "68000000-0000-0000-0000-000000000006"
      )!,
      scopeID: fixture.scopeID,
      currentRecoveryRecipient: current,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness
    )
    let phrase = try SecretSyncRecoveryMnemonic(
      masterSeed: Data(0..<32)
    ).canonicalPhrase
    // The confirmed intent travels with the confirmation so callers stage the
    // intent that was actually bound rather than rebuilding an equal-looking
    // one. Any caller that needs a different intent must confirm a different
    // ceremony.
    let intent = try makeU6BIntent(
      fixture: fixture,
      handle: handle,
      current: current
    )
    return U6BConfirmedBreakGlass(
      handle: handle,
      evidence: try await custody.confirmBreakGlass(
        handle,
        phrase: phrase,
        intent: intent
      ),
      intent: intent
    )
  }

  private func breakGlassRequest(
    _ confirmed: U6BConfirmedBreakGlass,
    fixture: U6BFixture,
    current: RecoveryRecipientDescriptor
  ) throws -> BreakGlassRecoveryRequest {
    try BreakGlassRecoveryRequest(
      requestID: confirmed.handle.requestID,
      scopeID: fixture.scopeID,
      recoveryRecipientID: current.recoveryRecipientID,
      sealedGenerationID: fixture.currentGenerationID,
      expectedFreshnessCommitment: fixture.freshness,
      blindConfirmation: confirmed.evidence
    )
  }
}

private struct U6BConfirmedBreakGlass: Sendable {
  let handle: SecretSyncRecoveryConfirmationHandle
  let evidence: BlindRecoveryConfirmationEvidence
  /// The exact intent this confirmation is bound to. Staging anything else
  /// through the signing path is refused.
  let intent: GlobalRecoveryTransitionIntent
}

/// Every field of `GlobalRecoveryTransitionIntent` an attacker could swap
/// between the moment the user confirms and the moment the recovery key signs.
///
/// The first nine were already covered by the pre-signing current-state guard.
/// The rest describe the replacement and candidate halves, which no guard
/// touched — they are the substitution surface the intent digest closes.
///
/// Two fields of the intent are absent, both because they cannot vary:
/// - `warning` — all three of its components are pinned by
///   `FullLossRecoveryWarningAcknowledgement.init`
///   (SecretSyncRecoveryAuthorityContracts.swift:109-116); any other value
///   throws rather than producing a substituted intent. Covered instead by
///   `warningAcknowledgementIsNotSubstitutable`.
/// - `candidatePolicyEpoch` — pinned to `currentPolicyEpoch + 1`
///   (:487-491), so it cannot move on its own. `epoch` moves the pair.
private enum U6BIntentMutation: CaseIterable {
  case request
  case challenge
  case session
  case scope
  case generation
  case descriptor
  case epoch
  case commit
  case policy
  case appNamespace
  case estateID
  case replacementDeviceID
  case replacementCredentialID
  case replacementSigningPublicKey
  case replacementAgreementPublicKey
  case signingPossessionProof
  case agreementPossessionProof
  case candidateGenerationID
  case candidateSignedPolicyDigest
  case replacementRecoveryRecipient
  case recoveryEnvelopeDigest
  case candidateSemantics
}

private enum U6BCoordinatedMutation: CaseIterable {
  case request
  case scope
  case generation
  case freshnessEpoch
  case freshnessHead
  case freshnessPolicy
  case recoveryIdentity
}

func makeU6BIntent(
  fixture: U6BFixture,
  handle: SecretSyncRecoveryConfirmationHandle,
  current: RecoveryRecipientDescriptor,
  estateID: UUID = UUID(
    uuidString: "63000000-0000-0000-0000-000000000006"
  )!,
  appNamespace: String = "com.codedaptive.mootx01.fulcrum",
  challengeRequestID: UUID? = nil,
  challengeID: UUID? = nil,
  sessionID: UUID? = nil,
  scopeID: SecretScopeID? = nil,
  currentGenerationID: SecretGenerationID? = nil,
  currentRecoveryRecipient: RecoveryRecipientDescriptor? = nil,
  currentPolicyEpoch: UInt64? = nil,
  currentCommitDigest: SecretRecordDigest? = nil,
  currentPolicyDigest: SecretRecordDigest? = nil,
  replacementDeviceID: TrustedDeviceID? = nil,
  replacementCredentialID: DeviceCredentialID? = nil,
  replacementSigningPublicKey: SigningPublicKeyDescriptor? = nil,
  replacementAgreementPublicKey: KeyAgreementPublicKeyDescriptor? = nil,
  signingPossessionProof: Data? = nil,
  agreementPossessionProof: Data? = nil,
  candidateGenerationID: SecretGenerationID? = nil,
  replacementRecoveryRecipient: RecoveryRecipientDescriptor? = nil,
  // The contract ties `candidateSignedPolicyDigest` and
  // `recoveryEnvelopeDigest` to the matching fields of `candidateSemantics`
  // (SecretSyncRecoveryAuthorityContracts.swift:500-501), so each of these
  // moves the semantics block with it. `scopeSnapshotDigest` is the semantics
  // field no top-level field mirrors, so it varies the semantics alone.
  candidateSignedPolicyDigest: SecretRecordDigest? = nil,
  recoveryEnvelopeDigest: SecretRecordDigest? = nil,
  candidateScopeSnapshotDigest: SecretRecordDigest? = nil
) throws -> GlobalRecoveryTransitionIntent {
  let digest: (UInt8) throws -> SecretRecordDigest = {
    try SecretRecordDigest(bytes: Data(repeating: $0, count: 32))
  }
  let candidateSignedPolicy = try candidateSignedPolicyDigest ?? digest(0x31)
  let recoveryEnvelope = try recoveryEnvelopeDigest ?? digest(0x32)
  let semantics = try FullLossRecoveryCandidateSemantics(
    scopeSnapshotDigest: candidateScopeSnapshotDigest ?? digest(0x30),
    signedPolicyDigest: candidateSignedPolicy,
    sealedPayloadDigest: digest(0x33),
    recipientEnvelopeDigests: [digest(0x34)],
    recoveryEnvelopeDigest: recoveryEnvelope,
    purgeRequirementDigests: [digest(0x35)],
    purgeReceiptDigests: [],
    credentialDigests: [digest(0x36)],
    trustRecordDigests: [digest(0x37)]
  )
  let replacement = try SecretSyncRecoverySeedDerivation().derive(
    masterSeed: Data((1...32).map(UInt8.init)),
    recoveryRecipientID: UUID(
      uuidString: "62000000-0000-0000-0000-000000000006"
    )!
  ).descriptor
  let replacementSigning = try replacementSigningPublicKey
    ?? SigningPublicKeyDescriptor(
      algorithmIdentifier: "mootx01.test.replacement-signing.v1",
      keyIdentifier: Data(repeating: 0x41, count: 32),
      publicKeyBytes: Data([0x04]) + Data(repeating: 0x42, count: 64)
    )
  let replacementAgreement = try replacementAgreementPublicKey
    ?? KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: "mootx01.test.replacement-agreement.v1",
      keyIdentifier: Data(repeating: 0x51, count: 32),
      publicKeyBytes: Data([0x04]) + Data(repeating: 0x52, count: 64)
    )
  return try GlobalRecoveryTransitionIntent(
    appNamespace: appNamespace,
    estateID: estateID,
    scopeID: scopeID ?? fixture.scopeID,
    challenge: FullLossRecoveryChallenge(
      requestID: challengeRequestID ?? handle.requestID,
      challengeID: challengeID ?? handle.challengeID,
      sessionID: sessionID ?? handle.sessionID,
      nonce: Data(repeating: 0x61, count: 16),
      issuedAtMilliseconds: 10_000,
      expiresAtMilliseconds: 20_000
    ),
    warning: FullLossRecoveryWarningAcknowledgement(
      acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
    ),
    currentCommitDigest:
      currentCommitDigest ?? fixture.freshness.headCommitDigest,
    currentPolicyDigest:
      currentPolicyDigest ?? fixture.freshness.policyDigest,
    currentPolicyEpoch:
      currentPolicyEpoch ?? fixture.freshness.latestPolicyEpoch,
    currentGenerationID: currentGenerationID ?? fixture.currentGenerationID,
    currentRecoveryRecipient: currentRecoveryRecipient ?? current,
    replacementDeviceID: replacementDeviceID ?? TrustedDeviceID(
      UUID(uuidString: "64000000-0000-0000-0000-000000000006")!
    ),
    replacementCredentialID: replacementCredentialID ?? DeviceCredentialID(
      UUID(uuidString: "65000000-0000-0000-0000-000000000006")!
    ),
    replacementSigningPublicKey: replacementSigning,
    replacementAgreementPublicKey: replacementAgreement,
    signingPossessionProof: signingPossessionProof ?? Data([0x71]),
    agreementPossessionProof: agreementPossessionProof ?? Data([0x72]),
    candidatePolicyEpoch:
      (currentPolicyEpoch ?? fixture.freshness.latestPolicyEpoch) + 1,
    candidateGenerationID:
      candidateGenerationID ?? fixture.replacementGenerationID,
    candidateSignedPolicyDigest: candidateSignedPolicy,
    replacementRecoveryRecipient: replacementRecoveryRecipient ?? replacement,
    recoveryEnvelopeDigest: recoveryEnvelope,
    candidateSemantics: semantics
  )
}

private func changedU6BFreshness(
  _ original: SecretBootstrapFreshnessCommitment,
  epoch: UInt64? = nil,
  head: SecretRecordDigest? = nil,
  policy: SecretRecordDigest? = nil
) throws -> SecretBootstrapFreshnessCommitment {
  try SecretBootstrapFreshnessCommitment(
    scopeID: original.scopeID,
    latestPolicyEpoch: epoch ?? original.latestPolicyEpoch,
    headCommitDigest: head ?? original.headCommitDigest,
    policyDigest: policy ?? original.policyDigest
  )
}
