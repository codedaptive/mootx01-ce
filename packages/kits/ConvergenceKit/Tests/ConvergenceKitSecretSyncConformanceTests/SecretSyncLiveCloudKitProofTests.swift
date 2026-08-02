import CloudKit
import ConvergenceKit
@_spi(SecretSyncPhysicalProof) @testable import ConvergenceKitAppleSecurity
@testable import ConvergenceKitCloudKit
import CryptoKit
import Foundation
import Testing

enum SecretSyncLiveAttestation {
  static let label = "u7-live-credential-attestation/v1"

  static func transcriptValue(
    _ transcript: SecretSyncProofOfPossessionTranscript
  ) -> SecretSyncLivePossessionTranscript {
    SecretSyncLivePossessionTranscript(
      challengeID: transcript.challengeID, sessionID: transcript.sessionID,
      issuedAt: transcript.issuedAt, expiresAt: transcript.expiresAt,
      deviceID: transcript.deviceID, credentialID: transcript.credentialID,
      signingPublicKey: transcript.signingPublicKey,
      agreementPublicKey: transcript.agreementPublicKey,
      authorityCredentialID: transcript.authorityCredentialID,
      freshnessCommitment: transcript.freshnessCommitment
    )
  }

  static func agreementChallenge(
    transcript: SecretSyncProofOfPossessionTranscript,
    verifierPublicKey: Data
  ) throws -> Data {
    try SecretSyncCanonicalEncoding.encode(
      domain: .deviceEnrollmentProof,
      fields: [
        .init(tag: 1, value: uint16(1)),
        .init(tag: 2, value: Data("secret-sync/agreement-possession/v1".utf8)),
        .init(tag: 3, value: try transcriptBytes(transcript)),
        .init(tag: 4, value: verifierPublicKey),
      ]
    )
  }

  static func verifyAgreement(
    proof: Data,
    challenge: Data,
    verifierPrivateKey: Data,
    credential: TrustedDeviceCredential,
    transcript: SecretSyncProofOfPossessionTranscript
  ) throws -> Bool {
    let verifier = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: verifierPrivateKey
    )
    let expectedChallenge = try agreementChallenge(
      transcript: transcript,
      verifierPublicKey: verifier.publicKey.x963Representation
    )
    guard challenge == expectedChallenge else { return false }
    let candidate = try P256.KeyAgreement.PublicKey(
      x963Representation: credential.keyAgreementPublicKey.publicKeyBytes
    )
    let shared = try verifier.sharedSecretFromKeyAgreement(with: candidate)
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(), sharedInfo: challenge,
      outputByteCount: 32
    )
    let expected = Data(
      HMAC<SHA256>.authenticationCode(for: challenge, using: key)
    )
    return constantTimeEqual(proof, expected)
  }

  static func agreementResponse(
    challenge: Data,
    credentialPrivateKey: P256.KeyAgreement.PrivateKey,
    verifierPublicKey: Data
  ) throws -> Data {
    let verifier = try P256.KeyAgreement.PublicKey(
      x963Representation: verifierPublicKey
    )
    let shared = try credentialPrivateKey.sharedSecretFromKeyAgreement(with: verifier)
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(), sharedInfo: challenge,
      outputByteCount: 32
    )
    return Data(HMAC<SHA256>.authenticationCode(for: challenge, using: key))
  }

  static func canonicalBody(
    namespace: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    launchGrantDigest: Data,
    credentialRecordName: String,
    verifierRecordName: String,
    credential: TrustedDeviceCredential,
    transcript: SecretSyncLivePossessionTranscript,
    signingChallenge: Data,
    signingProof: Data,
    agreementChallenge: Data,
    agreementProof: Data
  ) throws -> Data {
    try SecretSyncCanonicalEncoding.encode(
      domain: .deviceEnrollmentProof,
      fields: [
        .init(tag: 1, value: uint16(1)),
        .init(tag: 2, value: Data(label.utf8)),
        .init(tag: 3, value: Data(namespace.utf8)),
        .init(tag: 4, value: Data(role.rawValue.utf8)),
        .init(tag: 5, value: Data(credentialRecordName.utf8)),
        .init(tag: 6, value: Data(verifierRecordName.utf8)),
        .init(tag: 7, value: try credential.canonicalBytes()),
        .init(tag: 8, value: try transcriptBytes(transcript.productionValue())),
        .init(tag: 9, value: signingChallenge),
        .init(tag: 10, value: signingProof),
        .init(tag: 11, value: agreementChallenge),
        .init(tag: 12, value: agreementProof),
        .init(tag: 13, value: launchGrantDigest),
      ]
    )
  }

  static func verify(
    _ evidence: SecretSyncLiveCredentialEvidence,
    namespace: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    expectedLaunchGrantDigest: Data,
    credentialRecordName: String,
    verifierRecordName: String,
    agreementVerifierPrivateKey: Data
  ) throws -> Bool {
    let transcript = try evidence.possessionTranscript.productionValue()
    guard evidence.launchGrantDigest == expectedLaunchGrantDigest,
      transcript.deviceID == evidence.credential.deviceID,
      transcript.credentialID == evidence.credential.credentialID,
      transcript.signingPublicKey == evidence.credential.signingPublicKey,
      transcript.agreementPublicKey == evidence.credential.keyAgreementPublicKey
    else { return false }
    let signing = try SecretSyncSigningProofChallenge(transcript: transcript)
    let signatures = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    guard signing.canonicalBytes == evidence.signingChallenge,
      try signatures.verify(
        signature: evidence.signingProof,
        canonicalBytes: signing.canonicalBytes,
        signingPublicKey: evidence.credential.signingPublicKey
      ),
      try verifyAgreement(
        proof: evidence.agreementProof,
        challenge: evidence.agreementChallenge,
        verifierPrivateKey: agreementVerifierPrivateKey,
        credential: evidence.credential,
        transcript: transcript
      )
    else { return false }
    let body = try canonicalBody(
      namespace: namespace, role: role,
      launchGrantDigest: evidence.launchGrantDigest,
      credentialRecordName: credentialRecordName,
      verifierRecordName: verifierRecordName,
      credential: evidence.credential, transcript: evidence.possessionTranscript,
      signingChallenge: evidence.signingChallenge,
      signingProof: evidence.signingProof,
      agreementChallenge: evidence.agreementChallenge,
      agreementProof: evidence.agreementProof
    )
    let bodyDigest = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
      .digest(canonicalBytes: body)
    let attestation = try evidence.attestationTranscript.productionValue()
    guard attestation.deviceID == evidence.credential.deviceID,
      attestation.credentialID == evidence.credential.credentialID,
      attestation.signingPublicKey == evidence.credential.signingPublicKey,
      attestation.agreementPublicKey == evidence.credential.keyAgreementPublicKey,
      attestation.freshnessCommitment.scopeID.rawValue
        == UUID(uuidString: String(namespace.dropFirst(3))),
      attestation.freshnessCommitment.headCommitDigest == bodyDigest,
      attestation.freshnessCommitment.policyDigest == bodyDigest
    else { return false }
    let challenge = try SecretSyncSigningProofChallenge(transcript: attestation)
    guard challenge.canonicalBytes == evidence.attestationChallenge,
      try signatures.verify(
        signature: evidence.attestationProof,
        canonicalBytes: challenge.canonicalBytes,
        signingPublicKey: evidence.credential.signingPublicKey
      )
    else { return false }
    return evidence.evidenceID == evidenceID(
      body: body, challenge: challenge.canonicalBytes,
      proof: evidence.attestationProof
    )
  }

  static func evidenceID(body: Data, challenge: Data, proof: Data) -> String {
    var bytes = body
    bytes.append(challenge)
    bytes.append(proof)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func transcriptBytes(
    _ transcript: SecretSyncProofOfPossessionTranscript
  ) throws -> Data {
    try transcript.canonicalBytes
  }

  private static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

enum SecretSyncLiveImmutableArtifactStore {
  static func create(
    _ record: CKRecord,
    database: any CloudKitDatabaseProtocol
  ) async throws {
    try SecretSyncLiveArtifactRecordID.requireAuthorized(
      record.recordID, controlZoneID: SecretSyncCloudKitZones.controlZoneID
    )
    let result = try await database.modifyRecords(
      saving: [record], deleting: [],
      savePolicy: .ifServerRecordUnchanged, atomically: true
    )
    guard result.deleteResults.isEmpty,
      Set(result.saveResults.keys) == [record.recordID],
      case .success? = result.saveResults[record.recordID]
    else { throw SecretSyncCloudKitError.incompleteModifyResults }
  }
}

enum SecretSyncLiveArtifactRecordID {
  static func make(
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> CKRecord.ID {
    let recordID = CKRecord.ID(
      recordName: "\(values.runNamespace)-\(kind)-\(role.rawValue)",
      zoneID: values.controlZoneID
    )
    try requireAuthorized(recordID, values: values)
    guard values.signedRunManifest.manifest.artifactRecordNames.contains(
      recordID.recordName
    ) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedRunRecord
    }
    return recordID
  }

  static func requireAuthorized(
    _ recordID: CKRecord.ID,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws {
    try requireAuthorized(recordID, controlZoneID: values.controlZoneID)
  }

  static func requireAuthorized(
    _ recordID: CKRecord.ID,
    controlZoneID: CKRecordZone.ID
  ) throws {
    guard recordID.zoneID == controlZoneID,
      recordID.zoneID != CKRecordZone.default().zoneID
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone
    }
  }
}

enum SecretSyncLiveZoneAdmission {
  static func requirePreexisting(
    observed: [CKRecordZone.ID],
    control: CKRecordZone.ID,
    payload: CKRecordZone.ID
  ) throws {
    let observed = Set(observed)
    guard control.zoneName == "moot-secret-control-v1",
      payload.zoneName == "moot-secret-payload-v1",
      observed.contains(control), observed.contains(payload)
    else { throw SecretSyncLiveCloudKitProofConfigurationError.requiredZoneMissing }
  }
}

enum SecretSyncLiveCleanupPlan {
  static func authorizedRecordIDs(
    authorization: SecretSyncLiveSignedCleanupAuthorization,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> [CKRecord.ID] {
    let recordIDs = authorization.manifest.records.map {
      CKRecord.ID(
        recordName: $0.recordName,
        zoneID: CKRecordZone.ID(
          zoneName: $0.zoneName, ownerName: CKCurrentUserDefaultName
        )
      )
    }
    try requireAuthorized(recordIDs, authorization: authorization, values: values)
    return recordIDs
  }

  static func requireAuthorized(
    _ recordIDs: [CKRecord.ID],
    authorization: SecretSyncLiveSignedCleanupAuthorization,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws {
    let allowed = Set([values.controlZoneID, values.payloadZoneID])
    let signed = Set(authorization.manifest.records)
    guard recordIDs.count == Set(recordIDs).count,
      recordIDs.allSatisfy({ allowed.contains($0.zoneID) }) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone
    }
    for recordID in recordIDs {
      let reference = SecretSyncLiveRecordReference(
        recordName: recordID.recordName, zoneName: recordID.zoneID.zoneName
      )
      guard signed.contains(reference) else {
        throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedRunRecord
      }
      try SecretSyncLiveRunOwnedRecordGrammar.requireCleanup(
        reference, namespace: values.runNamespace
      )
    }
  }

  static func deleteAndVerify(
    _ recordIDs: [CKRecord.ID],
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    database: any CloudKitDatabaseProtocol,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    guard let authorization = values.cleanupAuthorization else {
      throw SecretSyncLiveCloudKitProofConfigurationError.cleanupAuthorizationMissing
    }
    try requireAuthorized(recordIDs, authorization: authorization, values: values)
    guard !recordIDs.isEmpty else {
      try await ledger.retainUnresolved([])
      return
    }
    var unresolved = Set(recordIDs)
    for ids in Dictionary(grouping: recordIDs, by: \.zoneID).values {
      try requireAuthorized(ids, authorization: authorization, values: values)
      do {
        let result = try await database.modifyRecords(
          saving: [], deleting: ids,
          savePolicy: .ifServerRecordUnchanged, atomically: false
        )
        guard result.saveResults.isEmpty else {
          try await ledger.retainUnresolved(recordIDs)
          throw SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
        }
        for id in ids {
          switch result.deleteResults[id] {
          case .success?: unresolved.remove(id)
          case .failure(let error)?:
            if isUnknownItem(error) { unresolved.remove(id) }
          case nil: break
          }
        }
      } catch {
        try await ledger.retainUnresolved(recordIDs)
        throw SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
      }
    }
    try requireAuthorized(recordIDs, authorization: authorization, values: values)
    let fetched: [CKRecord.ID: Result<CKRecord, any Error>]
    do {
      fetched = try await database.fetch(withRecordIDs: recordIDs)
    } catch {
      // A delete response is not absence proof. If verification is lost, the
      // complete exact attempt remains retryable; already-absent deletes are
      // harmless on the next pass.
      try await ledger.retainUnresolved(recordIDs)
      throw SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    }
    for id in recordIDs {
      if case .failure(let error)? = fetched[id], isUnknownItem(error) {
        unresolved.remove(id)
      } else {
        unresolved.insert(id)
      }
    }
    let orderedUnresolved = recordIDs.filter { unresolved.contains($0) }
    try await ledger.retainUnresolved(orderedUnresolved)
    guard unresolved.isEmpty else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    }
  }

  private static func isUnknownItem(_ error: any Error) -> Bool {
    (error as? CKError)?.code == .unknownItem
  }
}

enum SecretSyncLiveCleanupMarkerStore {
  static func publishOrValidate(
    _ envelope: SecretSyncLiveSignedArtifactEnvelope,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    database: any CloudKitDatabaseProtocol,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let kind = "phase-cleanup"
    let recordID = try SecretSyncLiveArtifactRecordID.make(
      kind: kind, role: values.deviceRole, values: values
    )
    let payload = try JSONEncoder().encode(envelope)
    let record = CKRecord(recordType: "U7SecretSyncProof", recordID: recordID)
    record["namespace"] = values.runNamespace as CKRecordValue
    record["kind"] = kind as CKRecordValue
    record["role"] = values.deviceRole.rawValue as CKRecordValue
    record["payload"] = payload as CKRecordValue
    try await ledger.recordBeforeSave(recordID)
    do {
      try await SecretSyncLiveImmutableArtifactStore.create(
        record, database: database
      )
    } catch {
      let fetched = try await database.fetch(withRecordIDs: [recordID])
      guard case .success(let existing)? = fetched[recordID],
        existing["namespace"] as? String == values.runNamespace,
        existing["kind"] as? String == kind,
        existing["role"] as? String == values.deviceRole.rawValue,
        let existingPayload = existing["payload"] as? Data,
        try JSONDecoder().decode(
          SecretSyncLiveSignedArtifactEnvelope.self, from: existingPayload
        ) == envelope
      else { throw error }
    }
  }
}

enum SecretSyncLiveCredentialPublicationBoundary {
  static func run<T: Sendable>(
    generation: SecretSyncCustodyCredentialGeneration,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    ledger: SecretSyncLiveCleanupLedger,
    removeBothHandles: (DeviceCredentialID) async throws -> Void,
    clearCheckpoint: () async throws -> Void,
    publish: () async throws -> T,
    reconcilePublication: () async throws -> T?
  ) async throws -> T {
    do {
      let result = try await publish()
      try await ledger.markCredentialPublished(role: role)
      return result
    } catch {
      let publicationFailure = error
      do {
        if let existing = try await reconcilePublication() {
          try await ledger.markCredentialPublished(role: role)
          return existing
        }
      } catch {
        // Mismatch or observation uncertainty preserves both exact handles and
        // the durable checkpoint for a later exact reconciliation.
        throw error
      }
      // Only definitive remote absence permits strict local rollback. Cleanup
      // and checkpoint-clear failures take precedence and preserve the marker.
      try await removeBothHandles(generation.credentialID)
      try await clearCheckpoint()
      throw publicationFailure
    }
  }

  static func removeInterruptedProvisional(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    ledger: SecretSyncLiveCleanupLedger,
    removeBothHandles: (DeviceCredentialID) async throws -> Void
  ) async throws {
    guard let checkpoint = try await ledger.credentialCheckpoint(role: role),
      !checkpoint.published
    else { return }
    do {
      try await removeBothHandles(checkpoint.credentialID)
    } catch SecretSyncCustodyError.missingHandle {
      // A crash after deletion but before checkpoint clearing is idempotent.
    }
    try await ledger.clearCredentialCheckpoint(role: role)
  }
}

enum SecretSyncLiveAuditCompletionBoundary {
  static func run(
    envelope: SecretSyncLiveSignedArtifactEnvelope,
    evidence: SecretSyncLiveEvidence,
    stage: (SecretSyncLiveSignedArtifactEnvelope) async throws -> Void,
    publishOrValidate: (SecretSyncLiveSignedArtifactEnvelope) async throws -> Void,
    commitCompletionAndErase: (SecretSyncLiveEvidence) async throws -> Void
  ) async throws {
    try await stage(envelope)
    try await publishOrValidate(envelope)
    try await commitCompletionAndErase(evidence)
  }
}

/// The production cleanup entry boundary. Its ordering is the contract: A
/// checkpoints prerequisites plus the frozen set before any deletion; retries
/// resume that exact unresolved set without reloading CloudKit prerequisites.
enum SecretSyncLiveCleanupEntryPoint {
  static func requiresInitialZoneAdmission(
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws -> Bool {
    guard values.phase == .cleanup, values.deviceRole == .a else { return true }
    return try await ledger.preparedCleanupRecordIDs() == nil
  }

  static func run(
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger,
    database: any CloudKitDatabaseProtocol,
    expectedRecordIDs: () throws -> [CKRecord.ID],
    verifyAPrerequisites: () async throws -> Void,
    removeCredential: (DeviceCredentialID) async throws -> Void,
    publishOrValidateMarker: (SecretSyncLiveEvidence) async throws -> Void
  ) async throws {
    guard !(try await ledger.localCleanupCompleted(role: values.deviceRole)) else {
      return
    }

    var aRecordIDs: [CKRecord.ID] = []
    if values.deviceRole == .a {
      if let prepared = try await ledger.preparedCleanupRecordIDs() {
        aRecordIDs = prepared
      } else {
        try await verifyAPrerequisites()
        let expected = try expectedRecordIDs()
        guard let authorization = values.cleanupAuthorization else {
          throw SecretSyncLiveCloudKitProofConfigurationError.cleanupAuthorizationMissing
        }
        try SecretSyncLiveCleanupPlan.requireAuthorized(
          expected, authorization: authorization, values: values
        )
        aRecordIDs = try await ledger.checkpointCleanupPrerequisites(
          including: expected, cleanupAuthorization: authorization
        )
      }
    }

    if let credentialID = try await ledger.credentialIDForCleanup(
      role: values.deviceRole
    ) {
      do {
        try await removeCredential(credentialID)
      } catch SecretSyncCustodyError.missingHandle {
        // Strict deletion reports missingHandle when both role records are
        // already absent. For cleanup retry that is the desired end state.
      }
      try await ledger.markCredentialRemoved(role: values.deviceRole)
    }

    let marker = try await ledger.cleanupMarker(role: values.deviceRole)
    if values.deviceRole == .a {
      guard let authorization = values.cleanupAuthorization else {
        throw SecretSyncLiveCloudKitProofConfigurationError.cleanupAuthorizationMissing
      }
      try SecretSyncLiveCleanupPlan.requireAuthorized(
        aRecordIDs, authorization: authorization, values: values
      )
      try await SecretSyncLiveCleanupPlan.deleteAndVerify(
        aRecordIDs, values: values, database: database, ledger: ledger
      )
    } else {
      try await publishOrValidateMarker(marker)
    }
    try await ledger.checkpointLocalCleanupCompletion(
      role: values.deviceRole, evidence: marker
    )
  }
}

enum SecretSyncLiveCredentialDistinctness {
  static func require(_ evidence: [SecretSyncLiveCredentialEvidence]) throws {
    guard evidence.count == 3,
      Set(evidence.map(\.evidenceID)).count == 3,
      Set(evidence.map(\.launchGrantDigest)).count == 3,
      Set(evidence.map { $0.credential.credentialID }).count == 3,
      Set(evidence.map { $0.credential.signingPublicKey }).count == 3,
      Set(evidence.map { $0.credential.signingPublicKey.keyIdentifier }).count == 3,
      Set(evidence.map { $0.credential.signingPublicKey.publicKeyBytes }).count == 3,
      Set(evidence.map { $0.credential.keyAgreementPublicKey }).count == 3,
      Set(evidence.map { $0.credential.keyAgreementPublicKey.keyIdentifier }).count == 3,
      Set(evidence.map { $0.credential.keyAgreementPublicKey.publicKeyBytes }).count == 3
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
  }
}

private struct SecretSyncLiveProtectedFloor: SecretSyncProtectedHeadProviding {
  let commitment: SecretBootstrapFreshnessCommitment

  func protectedHead(
    for scopeID: SecretScopeID
  ) async throws -> SecretBootstrapFreshnessCommitment {
    guard commitment.scopeID == scopeID else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return commitment
  }
}

private struct SecretSyncLiveExactFreshnessAnchor: ExternalBootstrapFreshnessAnchor {
  let commitment: SecretBootstrapFreshnessCommitment

  func latestCommitment(
    for scopeID: SecretScopeID
  ) async throws -> SecretBootstrapFreshnessCommitment {
    guard commitment.scopeID == scopeID else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return commitment
  }
}

enum SecretSyncLiveRecoveryExercise {
  struct Outcome: Sendable, Equatable {
    let seam: String
    let requestID: UUID
    let evidenceBytes: Data
    let digest: Data
  }

  static func stageBreakGlass(
    commitment: SecretBootstrapFreshnessCommitment,
    generationID: SecretGenerationID
  ) async throws -> Outcome {
    let custody = SecretSyncRecoveryKeyCustody()
    let enrolled = try await enroll(custody)
    let handle = try await custody.beginBreakGlass(
      requestID: UUID(), scopeID: commitment.scopeID,
      currentRecoveryRecipient: enrolled.descriptor,
      sealedGenerationID: generationID,
      expectedFreshnessCommitment: commitment
    )
    let confirmation = try await custody.confirm(handle, phrase: enrolled.phrase)
    let request = try BreakGlassRecoveryRequest(
      requestID: handle.requestID, scopeID: commitment.scopeID,
      recoveryRecipientID: enrolled.descriptor.recoveryRecipientID,
      sealedGenerationID: generationID,
      expectedFreshnessCommitment: commitment,
      blindConfirmation: confirmation
    )
    let evidence = try await custody.stageBreakGlass(
      request, freshnessAnchor: SecretSyncLiveExactFreshnessAnchor(
        commitment: commitment
      )
    )
    return try validatedOutcome(
      evidence, operation: .breakGlass,
      seam: "SecretSyncRecoveryKeyCustody.stageBreakGlass"
    )
  }

  static func stageRotation(
    commitment: SecretBootstrapFreshnessCommitment,
    currentGenerationID: SecretGenerationID
  ) async throws -> Outcome {
    let custody = SecretSyncRecoveryKeyCustody()
    let enrolled = try await enroll(custody)
    let replacementGenerationID = SecretGenerationID(UUID())
    let handle = try await custody.beginRotation(
      requestID: UUID(), scopeID: commitment.scopeID,
      currentRecoveryRecipientID: enrolled.descriptor.recoveryRecipientID,
      currentGenerationID: currentGenerationID,
      replacementGenerationID: replacementGenerationID,
      expectedFreshnessCommitment: commitment
    )
    let phrase = try await custody.revealPhrase(for: handle)
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryRotationRequest(
      requestID: handle.requestID, scopeID: commitment.scopeID,
      currentRecoveryRecipientID: enrolled.descriptor.recoveryRecipientID,
      replacementRecoveryRecipient: handle.recoveryRecipient,
      currentGenerationID: currentGenerationID,
      replacementGenerationID: replacementGenerationID,
      expectedFreshnessCommitment: commitment,
      blindConfirmation: confirmation
    )
    let evidence = try await custody.stageRotation(
      request, freshnessAnchor: SecretSyncLiveExactFreshnessAnchor(
        commitment: commitment
      )
    )
    guard try await custody.globalRecoveryRecipient() == handle.recoveryRecipient else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return try validatedOutcome(
      evidence, operation: .rotation,
      seam: "SecretSyncRecoveryKeyCustody.stageRotation"
    )
  }

  static func validateStored(
    _ bytes: Data,
    operation: SecretSyncRecoveryConfirmationOperation,
    seam: String
  ) throws -> Outcome {
    let fields = try SecretSyncRecoveryFrame.decode(bytes)
    guard fields.map(\.tag) == [1, 2, 3, 4, 5],
      fields[0].value == Data("mootx01.secret-recovery.operation-evidence.v1".utf8),
      fields[1].value == Data(operation.rawValue.utf8)
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return Outcome(
      seam: seam,
      requestID: try SecretSyncRecoveryFrame.uuid(from: fields[2].value),
      evidenceBytes: bytes,
      digest: Data(SHA256.hash(data: bytes))
    )
  }

  private static func enroll(
    _ custody: SecretSyncRecoveryKeyCustody
  ) async throws -> (descriptor: RecoveryRecipientDescriptor, phrase: String) {
    let handle = try await custody.beginEnrollment(requestID: UUID())
    let phrase = try await custody.revealPhrase(for: handle)
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: confirmation
    )
    _ = try await custody.stageEnrollment(request)
    guard try await custody.globalRecoveryRecipient() == handle.recoveryRecipient else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return (handle.recoveryRecipient, phrase)
  }

  private static func validatedOutcome(
    _ evidence: RecoveryOperationEvidence,
    operation: SecretSyncRecoveryConfirmationOperation,
    seam: String
  ) throws -> Outcome {
    let outcome = try validateStored(
      evidence.evidenceBytes, operation: operation, seam: seam
    )
    guard outcome.requestID == evidence.requestID else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return outcome
  }
}

private func u7TestManifestDigest(namespace: String) -> Data {
  let manifest = SecretSyncLiveSignedRunManifest.Manifest(
    version: 2, runNamespace: namespace,
    ledgerIdentifier: SecretSyncLiveSignedRunManifestVerifier
      .expectedLedgerIdentifier(namespace: namespace),
    artifactRecordNames: u7ExactArtifactNames(namespace: namespace)
  )
  let bytes = try! SecretSyncLiveSignedRunManifestVerifier
    .canonicalManifestBytes(manifest)
  return SecretSyncLiveSignedRunManifestVerifier.digest(
    manifestBytes: bytes, signature: Data()
  )
}

private func u7ExactArtifactNames(namespace: String) -> [String] {
  let pairs: [(String, SecretSyncLiveCloudKitProofConfiguration.DeviceRole)] = [
    ("agreement-verifier", .a), ("agreement-verifier", .b),
    ("agreement-verifier", .c), ("credential", .a), ("credential", .b),
    ("credential", .c), ("phase-credential", .a), ("phase-credential", .b),
    ("phase-credential", .c), ("phase-backgroundDenied", .a),
    ("candidate", .a), ("candidate", .b), ("manifest", .a),
    ("phase-stage", .a), ("cas", .a), ("cas", .b),
    ("phase-conditionalHead", .a), ("phase-conditionalHead", .b),
    ("phase-verify", .a), ("phase-verify", .b), ("phase-verify", .c),
    ("phase-revoke", .c), ("phase-offline", .a), ("phase-recovery", .a),
    ("phase-rotation", .a), ("phase-restart", .a), ("phase-audit", .a),
    ("phase-cleanup", .b), ("phase-cleanup", .c),
  ]
  return pairs.map { "\(namespace)-\($0.0)-\($0.1.rawValue)" }
}

private func u7TestLedgerURL(
  applicationSupportRoot: URL,
  namespace: String,
  role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole = .a
) -> URL {
  SecretSyncLiveCleanupLedger.derivedURLForDeterministicTesting(
    applicationSupportRoot: applicationSupportRoot, namespace: namespace,
    logicalLedgerIdentifier: SecretSyncLiveSignedRunManifestVerifier
      .expectedLedgerIdentifier(namespace: namespace),
    role: role
  )
}

private func u7TestLedger(
  applicationSupportRoot: URL,
  namespace: String,
  role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole = .a,
  runManifestDigest: Data? = nil
) throws -> SecretSyncLiveCleanupLedger {
  let identifier = SecretSyncLiveSignedRunManifestVerifier
    .expectedLedgerIdentifier(namespace: namespace)
  return try SecretSyncLiveCleanupLedger(
    url: u7TestLedgerURL(
      applicationSupportRoot: applicationSupportRoot,
      namespace: namespace, role: role
    ),
    namespace: namespace, logicalLedgerIdentifier: identifier, role: role,
    signedRunManifestDigest: runManifestDigest
      ?? u7TestManifestDigest(namespace: namespace)
  )
}

@Suite("SecretSync live proof configuration contract")
struct SecretSyncLiveCloudKitProofConfigurationTests {
  @Test("standalone host initializes resumable private authority and signed state")
  func standaloneHostInitializesAndResumes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-host-control-red-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hostSource = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("U7LiveProofHost/main.swift")
    let executable = root.appendingPathComponent("u7-host")
    let compile = try u7RunProcess(
      executable: "/usr/bin/xcrun",
      arguments: ["swiftc", hostSource.path, "-o", executable.path]
    )
    #expect(compile.status == 0)
    let runDirectory = root.appendingPathComponent("private")
    let initialize = try u7RunProcess(
      executable: executable.path,
      arguments: [
        "self-test", "init", "--run-dir", runDirectory.path,
        "--namespace", "u7-00112233-4455-6677-8899-aabbccddeeff",
        "--now", "1100",
      ]
    )
    #expect(initialize.status == 0)
    #expect(initialize.stdout == "U7_HOST_INIT_OK\n")
    #expect(FileManager.default.fileExists(
      atPath: runDirectory.appendingPathComponent("host-state.json").path
    ))
    #expect(FileManager.default.fileExists(
      atPath: runDirectory.appendingPathComponent("run-manifest.json").path
    ))
    let resume = try u7RunProcess(
      executable: executable.path,
      arguments: [
        "self-test", "init", "--run-dir", runDirectory.path,
        "--namespace", "u7-00112233-4455-6677-8899-aabbccddeeff",
        "--now", "1100",
      ]
    )
    #expect(resume.status == 0)
    #expect(resume.stdout == "U7_HOST_RESUME_OK\n")
    let privateKey = runDirectory.appendingPathComponent("authority-private.bin")
    try FileManager.default.removeItem(at: privateKey)
    try FileManager.default.createSymbolicLink(
      at: privateKey, withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )
    let unsafeResume = try u7RunProcess(
      executable: executable.path,
      arguments: [
        "self-test", "init", "--run-dir", runDirectory.path,
        "--namespace", "u7-00112233-4455-6677-8899-aabbccddeeff",
        "--now", "1100",
      ]
    )
    #expect(unsafeResume.status != 0)
    #expect(unsafeResume.stderr == "U7_HOST_ERROR\n")
  }

  @Test("standalone host advances only from exact probe and receipt evidence")
  func standaloneHostEvidenceControlPlane() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-host-evidence-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let executable = root.appendingPathComponent("u7-host")
    #expect(try u7RunProcess(
      executable: "/usr/bin/xcrun",
      arguments: [
        "swiftc", packageRoot.appendingPathComponent("U7LiveProofHost/main.swift").path,
        "-o", executable.path,
      ]
    ).status == 0)
    let runDirectory = root.appendingPathComponent("private")
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    #expect(try u7RunProcess(
      executable: executable.path,
      arguments: [
        "self-test", "init", "--run-dir", runDirectory.path,
        "--namespace", namespace, "--now", "1100",
      ]
    ).status == 0)
    let signedManifest = try JSONDecoder().decode(
      SecretSyncLiveSignedRunManifest.self,
      from: Data(contentsOf: runDirectory.appendingPathComponent("run-manifest.json"))
    )
    let authorityText = try String(
      contentsOf: runDirectory.appendingPathComponent("authority-public.b64"),
      encoding: .utf8
    )
    let authority = try #require(Data(base64Encoded: authorityText))
    let manifestDigest = try SecretSyncLiveSignedRunManifestVerifier.verify(
      signedManifest, trustedAuthorityPublicKey: authority, namespace: namespace
    )
    #expect(!signedManifest.manifest.artifactRecordNames.contains(
      "\(namespace)-phase-cleanup-A"
    ))
    let destinationDigest = Data(repeating: 9, count: SHA256.byteCount)
    let allSteps: [(
      SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
      SecretSyncLiveCloudKitProofConfiguration.Phase,
      SecretSyncLiveRuntimePlatform
    )] = [
      (.a, .credential, .mac), (.b, .credential, .iPhone),
      (.c, .credential, .iPad), (.a, .backgroundDenied, .mac),
      (.a, .stage, .mac), (.a, .conditionalHead, .mac),
      (.b, .conditionalHead, .iPhone), (.a, .verify, .mac),
      (.b, .verify, .iPhone), (.c, .verify, .iPad), (.a, .offline, .mac),
      (.c, .revoke, .iPad), (.a, .recovery, .mac), (.a, .rotation, .mac),
      (.a, .restart, .mac), (.a, .audit, .mac), (.b, .cleanup, .iPhone),
      (.c, .cleanup, .iPad), (.a, .cleanup, .mac),
    ]
    let prerequisiteIndicesByStep = [
      3: [0], 4: [3], 5: [4], 6: [4], 12: [10], 13: [12],
      14: [13], 15: [14], 18: [15, 16, 17],
    ]
    var stageInventory: SecretSyncLiveStageInventoryAttachment?
    var acceptedArtifactDigests: [Data] = []

    // This intentionally executes the first complete authority transaction:
    // three credential bindings, background denial, stage inventory, then the
    // cleanup capability. Keeping it in one test proves durable ordering.
    for (index, step) in allSteps.enumerated() {
      let probeURL = root.appendingPathComponent("probe-\(index).json")
      try SecretSyncLiveExactJSON.encode(SecretSyncLiveLedgerProbeAttachment(
        version: 1, namespace: namespace,
        ledgerIdentifier: signedManifest.manifest.ledgerIdentifier,
        role: step.0, contentDigest: Data(repeating: UInt8(index), count: 32)
      )).write(to: probeURL)
      let grantName = "grant-\(String(format: "%02d", index)).json"
      let issue = try u7RunProcess(
        executable: executable.path,
        arguments: [
          "self-test", "issue-grant", "--run-dir", runDirectory.path,
          "--role", step.0.rawValue, "--phase", step.1.rawValue,
          "--platform", step.2.rawValue, "--destination-digest",
          destinationDigest.base64EncodedString(), "--probe", probeURL.path,
          "--output", grantName, "--now", "1100",
        ]
      )
      #expect(issue.status == 0)
      let grant = try JSONDecoder().decode(
        SecretSyncLiveHostLaunchGrant.self,
        from: Data(contentsOf: runDirectory.appendingPathComponent(grantName))
      )
      let grantDigest = try SecretSyncLiveHostLaunchGrantVerifier.verify(
        grant, trustedAuthorityPublicKey: authority,
        expectedRunManifestDigest: manifestDigest, namespace: namespace,
        role: step.0, phase: step.1, runtimePlatform: step.2,
        now: Date(timeIntervalSince1970: 1_100)
      )
      let expectedPrerequisites = (prerequisiteIndicesByStep[index] ?? [])
        .map { acceptedArtifactDigests[$0] }
      #expect(grant.manifest.prerequisiteArtifactDigests == expectedPrerequisites)
      if step.1 == .stage {
        stageInventory = SecretSyncLiveStageInventoryAttachment(
          version: 1, namespace: namespace, role: .a,
          runManifestDigest: manifestDigest, launchGrantDigest: grantDigest,
          destinationBindingDigest: destinationDigest,
          records: [SecretSyncLiveRecordReference(
            recordName: String(repeating: "1", count: 64),
            zoneName: SecretSyncCloudKitZones.payloadZoneID.zoneName
          )]
        )
      }
      let artifactDigest = Data(repeating: UInt8(index + 1), count: 32)
      let receiptURL = root.appendingPathComponent("receipt-\(index).json")
      try SecretSyncLiveExactJSON.encode(SecretSyncLivePhaseReceiptAttachment(
        version: 1, namespace: namespace, role: step.0, phase: step.1,
        runManifestDigest: manifestDigest, launchGrantDigest: grantDigest,
        destinationBindingDigest: destinationDigest,
        artifactDigest: artifactDigest,
        inventoryDigest: step.1 == .stage
          ? try stageInventory?.canonicalDigest() : nil,
        credentialBindingDigest: step.1 == .credential
          ? Data(repeating: UInt8(index + 20), count: 32) : nil
      )).write(to: receiptURL)
      #expect(try u7RunProcess(
        executable: executable.path,
        arguments: [
          "accept-receipt", "--run-dir", runDirectory.path,
          "--receipt", receiptURL.path, "--result-id", "result-\(index)",
        ]
      ).status == 0)
      acceptedArtifactDigests.append(artifactDigest)
      if step.1 == .stage {
        let inventoryURL = root.appendingPathComponent("inventory.json")
        try SecretSyncLiveExactJSON.encode(try #require(stageInventory))
          .write(to: inventoryURL)
        let authorize = try u7RunProcess(
          executable: executable.path,
          arguments: [
            "self-test", "authorize-cleanup", "--run-dir", runDirectory.path,
            "--inventory", inventoryURL.path,
            "--output", "cleanup-authorization.json", "--now", "1100",
          ]
        )
        #expect(authorize.status == 0)
      }
    }
  }

  @Test("runner rejects zero-exit commands that produce no protocol evidence")
  func runnerRejectsMissingEvidence() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-runner-evidence-red-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("fake-command.sh")
    try Data("#!/bin/bash\nexit 0\n".utf8).write(to: fake)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: fake.path
    )
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let runner = packageRoot.appendingPathComponent(
      "U7LiveProofHost/run-u7-live-proof.sh"
    )
    let result = try u7RunProcess(
      executable: runner.path,
      arguments: [],
      environment: [
        "U7_RUN_DIR": root.appendingPathComponent("private").path,
        "U7_HOST_TOOL": fake.path, "U7_XCODEBUILD": fake.path,
        "U7_XCRESULTTOOL": fake.path, "U7_PACKAGE_DIR": packageRoot.path,
        "U7_DEST_A": "A-RAW-CANARY",
        "U7_DEST_B": "B-RAW-CANARY", "U7_DEST_C": "C-RAW-CANARY",
      ]
    )
    #expect(result.status != 0)
    #expect(result.stderr == "U7_RUNNER_EVIDENCE_MISSING\n")
    #expect(!result.stdout.contains("RAW-CANARY"))
    #expect(!result.stderr.contains("RAW-CANARY"))
    let retained = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("private").path
    )
    #expect(!retained.contains(where: { $0.hasPrefix("transient.") }))
    #expect(!retained.contains("command.log"))
  }

  @Test("runner accepts only explicit Swift-package xctestrun mode")
  func runnerSourceRejectsLegacyContainerMode() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let runner = packageRoot.appendingPathComponent(
      "U7LiveProofHost/run-u7-live-proof.sh"
    )
    let source = try String(contentsOf: runner, encoding: .utf8)
    #expect(source.contains("U7_PACKAGE_DIR"))
    #expect(source.contains("ConvergenceKit-Package"))
    #expect(source.contains("-xctestrun"))
    #expect(!source.contains("-project"))
    #expect(!source.contains("-workspace"))
  }

  @Test("host inspect authenticates state manifest and retained authority bindings")
  func hostInspectRejectsEveryDurableBindingMutation() throws {
    let mutations = [
      "version", "namespace", "manifestDigest", "publicKey",
      "manifest", "privateKey",
    ]
    for mutation in mutations {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-host-inspect-\(mutation)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let runDirectory = root.appendingPathComponent("private")
      let initialize = try u7RunProcess(
        executable: host.path,
        arguments: [
          "self-test", "init", "--run-dir", runDirectory.path,
          "--namespace", "u7-00112233-4455-6677-8899-aabbccddeeff",
          "--now", "1100",
        ]
      )
      #expect(initialize.status == 0)
      let inspect = try u7RunProcess(
        executable: host.path,
        arguments: ["inspect", "--run-dir", runDirectory.path]
      )
      #expect(inspect.status == 0)
      #expect(inspect.stdout.hasPrefix("U7_HOST_INSPECT:"))

      if mutation == "privateKey" {
        var replacement = Data(repeating: 0, count: 32)
        replacement[31] = 8
        try replacement.write(
          to: runDirectory.appendingPathComponent("authority-private.bin")
        )
      } else if mutation == "manifest" {
        let manifestURL = runDirectory.appendingPathComponent("run-manifest.json")
        var outer = try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
        )
        var manifest = try #require(outer["manifest"] as? [String: Any])
        manifest["ledgerIdentifier"] = "u7-ledger-mismatch"
        outer["manifest"] = manifest
        try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
          .write(to: manifestURL)
      } else {
        let stateURL = runDirectory.appendingPathComponent("host-state.json")
        var outer = try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
            as? [String: Any]
        )
        var state = try #require(outer["state"] as? [String: Any])
        switch mutation {
        case "version": state["version"] = 99
        case "namespace":
          state["namespace"] = "u7-ffffffff-ffff-ffff-ffff-ffffffffffff"
        case "manifestDigest":
          state["runManifestDigest"] = Data(repeating: 0, count: 32)
            .base64EncodedString()
        case "publicKey":
          state["authorityPublicKey"] = Data(repeating: 0, count: 65)
            .base64EncodedString()
        default: Issue.record("unhandled mutation")
        }
        outer["state"] = state
        try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
          .write(to: stateURL)
      }
      let rejected = try u7RunProcess(
        executable: host.path,
        arguments: ["inspect", "--run-dir", runDirectory.path]
      )
      #expect(rejected.status != 0)
      #expect(rejected.stderr == "U7_HOST_ERROR\n")
    }
  }

  @Test("runner completes the exact 19-step fake proof and terminally sanitizes")
  func runnerCompletesAndFinalizesFakeProof() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-runner-success-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let host = try u7CompileStandaloneHost(root: root)
    let fake = try u7WriteFakeRunnerTool(root: root)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let runner = packageRoot.appendingPathComponent(
      "U7LiveProofHost/run-u7-live-proof.sh"
    )
    let result = try u7RunProcess(
      executable: runner.path, arguments: ["--self-test"],
      environment: u7RunnerEnvironment(
        root: root, host: host, fake: fake,
        additions: ["MOOT_SECRET_SYNC_INHERITED_CANARY": "must-not-reach-xctest"]
      )
    )
    #expect(result.status == 0)
    #expect(result.stdout.components(separatedBy: "U7_PHASE_OK:").count - 1 == 19)
    #expect(result.stdout.hasSuffix("U7_RUNNER_OK\n"))
    #expect(!result.stdout.contains("RAW-CANARY"))
    #expect(!result.stderr.contains("RAW-CANARY"))
    let retained = Set(try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("private").path
    ))
    #expect(retained == Set([
      ".host.lock", "authority-public.b64", "host-state.json", "run-manifest.json",
    ]))
    let commands = try String(
      contentsOf: root.appendingPathComponent("fake.log"), encoding: .utf8
    ).split(separator: "\n")
    #expect(Array(commands.prefix(2)) == [
      "build:mac:scheme=ConvergenceKit-Package:cwd=package",
      "build:iOS:scheme=ConvergenceKit-Package:cwd=package",
    ])
    #expect(commands.dropFirst(2).allSatisfy {
      $0.hasPrefix("probe:") || $0.hasPrefix("phase:")
    })
    let probes = commands.filter { $0.hasPrefix("probe:") }
    #expect(probes.count == 19)
    let phases = commands.filter { $0.hasPrefix("phase:") }
    #expect(phases.count == 19)
    #expect(Set(phases).count == 19)
    let copies = try String(
      contentsOf: root.appendingPathComponent("fake.copies"), encoding: .utf8
    ).split(separator: "\n")
    #expect(copies.count == 38)
    #expect(Set(copies).count == 38)
    #expect(copies.allSatisfy {
      $0.contains("/private/derived-data/")
        && $0.hasSuffix(".xctestrun")
    })
    #expect(commands.filter { $0.hasPrefix("probe:A:") }.allSatisfy {
      $0.contains("platform=MacOSX")
    })
    #expect(commands.filter {
      $0.hasPrefix("probe:B:") || $0.hasPrefix("probe:C:")
    }.allSatisfy { $0.contains("platform=iPhoneOS") })
    let recoveryArtifactDigest = Data(SHA256.hash(data: Data("recoveryA".utf8)))
      .base64EncodedString()
    #expect(phases.contains {
      $0.hasPrefix("phase:rotation:A:platform=MacOSX:private-xctestrun:")
        && $0.hasSuffix("prerequisites=\(recoveryArtifactDigest)")
    })
    let terminalResume = try u7RunProcess(
      executable: runner.path, arguments: ["--self-test"],
      environment: u7RunnerEnvironment(root: root, host: host, fake: fake)
    )
    #expect(terminalResume.status == 0)
    #expect(terminalResume.stdout == "U7_RUNNER_OK\n")
  }

  @Test("fake xcodebuild rejects missing or wrong-platform build matrices")
  func fakeRunnerRejectsInvalidBuildMatrix() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-runner-build-matrix-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = try u7WriteFakeRunnerTool(root: root)
    let environment = [
      "U7_FAKE_LOG": root.appendingPathComponent("fake.log").path,
      "U7_DEST_A": "A-RAW-CANARY", "U7_DEST_B": "B-RAW-CANARY",
      "U7_DEST_C": "C-RAW-CANARY",
    ]
    let missing = try u7RunProcess(
      executable: fake.path,
      arguments: ["test-without-building"], environment: environment
    )
    #expect(missing.status != 0)
    let wrongOrder = try u7RunProcess(
      executable: fake.path,
      arguments: [
        "build-for-testing", "-destination", "B-RAW-CANARY",
      ],
      environment: environment
    )
    #expect(wrongOrder.status != 0)
    let wrongPlatform = try u7RunProcess(
      executable: fake.path,
      arguments: [
        "build-for-testing", "-destination", "C-RAW-CANARY",
      ],
      environment: environment
    )
    #expect(wrongPlatform.status != 0)
  }

  @Test("runner rejects legacy container inputs before invoking fake Xcode")
  func runnerRejectsLegacyContainerInputs() throws {
    for key in ["U7_PROJECT", "U7_WORKSPACE", "U7_SCHEME"] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-legacy-\(key)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let result = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: [key: "forbidden"]
        )
      )
      #expect(result.status != 0)
      #expect(result.stderr == "U7_RUNNER_CONTAINER_MODE_FORBIDDEN\n")
      #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fake.log").path
      ))
    }
  }

  @Test("self-test requires explicit entry and an attested fake Xcode tool")
  func runnerRequiresAttestedSelfTestTool() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-runner-attestation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let unattested = root.appendingPathComponent("unattested-tool.sh")
    try Data("#!/bin/bash\nexit 0\n".utf8).write(to: unattested)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: unattested.path
    )
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let runner = packageRoot.appendingPathComponent(
      "U7LiveProofHost/run-u7-live-proof.sh"
    )
    let result = try u7RunProcess(
      executable: runner.path, arguments: ["--self-test"],
      environment: [
        "U7_RUN_DIR": root.appendingPathComponent("private").path,
        "U7_HOST_TOOL": unattested.path,
        "U7_XCODEBUILD": unattested.path,
        "U7_XCRESULTTOOL": unattested.path,
        "U7_PACKAGE_DIR": packageRoot.path,
        "U7_DEST_A": "A-RAW-CANARY", "U7_DEST_B": "B-RAW-CANARY",
        "U7_DEST_C": "C-RAW-CANARY",
      ]
    )
    #expect(result.status != 0)
    #expect(result.stderr == "U7_RUNNER_SELF_TEST_TOOL_INVALID\n")

    let host = try u7CompileStandaloneHost(root: root)
    let fake = try u7WriteFakeRunnerTool(root: root)
    let inheritedMode = try u7RunProcess(
      executable: runner.path, arguments: [],
      environment: u7RunnerEnvironment(
        root: root, host: host, fake: fake,
        additions: [
          "U7_RUNNER_SELF_TEST_MODE": "1",
          "U7_SELF_TEST_XCTESTRUN_ATTACK": "forbidden-inherited-hook",
        ]
      )
    )
    #expect(inheritedMode.status == 0)
    #expect(inheritedMode.stdout.hasSuffix("U7_RUNNER_OK\n"))
  }

  @Test("runner rejects ambiguous target platform and bundle-anchor products")
  func runnerRejectsInvalidXCTestrunProducts() throws {
    let modes = [
      "zero-xctestrun", "duplicate-xctestrun", "missing-target",
      "duplicate-target", "missing-anchor", "wrong-anchor",
      "wrong-platform", "simulator-platform", "ios-wrong-platform",
      "ios-missing-anchor", "ios-wrong-anchor",
    ]
    for mode in modes {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-product-\(mode)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let result = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: ["U7_FAKE_MODE": mode]
        )
      )
      #expect(result.status != 0)
      #expect(result.stderr == "U7_RUNNER_PRODUCT_INVALID\n")
      let trace = (try? String(
        contentsOf: root.appendingPathComponent("fake.log"), encoding: .utf8
      )) ?? ""
      #expect(!trace.contains("probe:"))
      #expect(!trace.contains("phase:"))
    }
  }

  @Test("runner rejects private-copy or canonical-source replacement before launch")
  func runnerRejectsXCTestrunReplacement() throws {
    for attack in [
      "replace", "symlink", "source-replace", "copy-mode", "source-mode",
    ] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-attack-\(attack)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let result = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: ["U7_SELF_TEST_XCTESTRUN_ATTACK": attack]
        )
      )
      #expect(result.status != 0)
      #expect(result.stderr == "U7_RUNNER_XCTESTRUN_INVALID\n")
      let trace = (try? String(
        contentsOf: root.appendingPathComponent("fake.log"), encoding: .utf8
      )) ?? ""
      #expect(!trace.contains("probe:"))
      #expect(!trace.contains("phase:"))
    }
  }

  @Test("private copies use the descriptor-validated bytes across an in-place source race")
  func runnerCopiesOnlyDescriptorValidatedBytes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-runner-source-window-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let host = try u7CompileStandaloneHost(root: root)
    let fake = try u7WriteFakeRunnerTool(root: root)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let runner = packageRoot.appendingPathComponent(
      "U7LiveProofHost/run-u7-live-proof.sh"
    )
    let result = try u7RunProcess(
      executable: runner.path, arguments: ["--self-test"],
      environment: u7RunnerEnvironment(
        root: root, host: host, fake: fake,
        additions: ["U7_SELF_TEST_XCTESTRUN_ATTACK": "source-window"]
      )
    )
    #expect(result.status == 0)
    #expect(result.stdout.hasSuffix("U7_RUNNER_OK\n"))
    let trace = try String(
      contentsOf: root.appendingPathComponent("fake.log"), encoding: .utf8
    )
    #expect(trace.split(separator: "\n").filter { $0.hasPrefix("probe:") }.count == 19)
    #expect(trace.split(separator: "\n").filter { $0.hasPrefix("phase:") }.count == 19)
  }

  @Test("fake launch boundary rejects non-exact phase environment dictionaries")
  func runnerRejectsInvalidXCTestrunEnvironment() throws {
    let modes = [
      "missing-environment", "extra-environment", "authority-environment",
      "cleanup-missing-authorization", "cleanup-missing-inventory",
      "cleanup-missing-receipt", "ordinary-cleanup-key",
      "cleanup-extra-environment", "cleanup-wrong-inventory",
      "cleanup-wrong-receipt",
    ]
    for mode in modes {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-environment-\(mode)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let result = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: ["U7_FAKE_MODE": mode]
        )
      )
      #expect(result.status != 0)
      #expect(
        result.stderr == "U7_RUNNER_PROBE_FAILED\n"
          || result.stderr == "U7_RUNNER_PHASE_FAILED\n"
      )
      #expect(!result.stdout.contains("RAW-CANARY"))
      #expect(!result.stderr.contains("RAW-CANARY"))
    }
  }

  @Test("runner resumes pending grant and accepted receipt without replay")
  func runnerResumesAuthorityBoundaries() throws {
    let hooks = [
      "U7_SELF_TEST_INTERRUPT_BEFORE_GRANT_INDEX",
      "U7_SELF_TEST_INTERRUPT_AFTER_GRANT_INDEX",
      "U7_SELF_TEST_INTERRUPT_AFTER_RESULT_INDEX",
      "U7_SELF_TEST_INTERRUPT_AFTER_RECEIPT_INDEX",
      "U7_SELF_TEST_INTERRUPT_AFTER_AUTHORIZATION_INDEX",
    ]
    for hook in hooks {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-resume-\(hook)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let interruptIndex = hook.contains("AUTHORIZATION") ? "4" : "7"
      let interrupted = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: [hook: interruptIndex]
        )
      )
      #expect(interrupted.status != 0)
      #expect(interrupted.stderr == "U7_RUNNER_SELF_TEST_INTERRUPT\n")
      let resumed = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(root: root, host: host, fake: fake)
      )
      #expect(resumed.status == 0)
      let phases = try String(
        contentsOf: root.appendingPathComponent("fake.log"), encoding: .utf8
      ).split(separator: "\n").filter { $0.hasPrefix("phase:") }
      #expect(phases.count == 19)
      #expect(Set(phases).count == 19)
    }
  }

  @Test("runner fails closed for skip nonzero missing wrong stale and mismatch evidence")
  func runnerRejectsFakeFailureMatrix() throws {
    let modes = [
      "skip-phase", "nonzero-probe", "nonzero-phase", "missing-receipt",
      "wrong-receipt", "stale-receipt", "mismatch-probe", "mismatch-receipt",
    ]
    for mode in modes {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-runner-failure-\(mode)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let host = try u7CompileStandaloneHost(root: root)
      let fake = try u7WriteFakeRunnerTool(root: root)
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      let runner = packageRoot.appendingPathComponent(
        "U7LiveProofHost/run-u7-live-proof.sh"
      )
      let result = try u7RunProcess(
        executable: runner.path, arguments: ["--self-test"],
        environment: u7RunnerEnvironment(
          root: root, host: host, fake: fake,
          additions: ["U7_FAKE_MODE": mode]
        )
      )
      #expect(result.status != 0)
      #expect(!result.stdout.contains("RAW-CANARY"))
      #expect(!result.stderr.contains("RAW-CANARY"))
      let retained = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("private").path
      )
      #expect(!retained.contains(where: { $0.hasPrefix("transient.") }))
      #expect(retained.filter({ $0.hasPrefix("grant-") }).count <= 1)
    }
  }

  @Test("manifest v2 derives distinct role-local ledgers from one logical identity")
  func logicalLedgerIdentityIsRoleLocal() throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let logicalIdentity = SecretSyncLiveSignedRunManifestVerifier
      .expectedLedgerIdentifier(namespace: namespace)
    let manifest = SecretSyncLiveSignedRunManifest.Manifest(
      version: 2,
      runNamespace: namespace,
      ledgerIdentifier: logicalIdentity,
      artifactRecordNames: ["\(namespace)-credential-A"]
    )
    let encoded = try JSONEncoder().encode(manifest)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("ledgerDirectoryPath"))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("cleanupRecords"))

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-role-local-ledgers-\(UUID().uuidString)")
    let a = SecretSyncLiveCleanupLedger.derivedURLForDeterministicTesting(
      applicationSupportRoot: root, namespace: namespace,
      logicalLedgerIdentifier: logicalIdentity, role: .a
    )
    let b = SecretSyncLiveCleanupLedger.derivedURLForDeterministicTesting(
      applicationSupportRoot: root, namespace: namespace,
      logicalLedgerIdentifier: logicalIdentity, role: .b
    )
    #expect(a != b)
    #expect(!a.path.contains(namespace))
    #expect(!b.path.contains(namespace))
  }

  @Test("normal prompt-free runs remain explicitly non-proof")
  func disabledIsNotProof() {
    #expect(loadConfiguration(environment: [:], runtimePlatform: .mac) == .disabled)
  }

  @Test("partial live opt-in fails closed instead of becoming a skip")
  func partialOptInIsInvalid() {
    let configuration = loadConfiguration(
      environment: [SecretSyncLiveCloudKitProofConfiguration.optInKey: "1"],
      runtimePlatform: .mac
    )
    #expect(configuration == .invalid(.operatorAttestationMissing))
  }

  @Test("role phase and distinct device evidence are mandatory")
  func externalRolePhaseBoundary() {
    var environment = completeEnvironment(role: "B", phase: "stage")
    #expect(
      loadConfiguration(
        environment: environment, runtimePlatform: .iPhone
      )
        == .invalid(.rolePhaseMismatch)
    )
    environment = completeEnvironment(role: "B", phase: "verify")
    if case .configured(let values) =
      loadConfiguration(
        environment: environment, runtimePlatform: .iPhone
      )
    {
      #expect(values.databaseScope == .private)
      #expect(values.deviceRole == .b)
    } else {
      Issue.record("complete role-specific configuration must load")
    }
  }

  @Test("independent ledger clients reload under the transaction lock")
  func localLedgerTransactionsReload() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let url = ledgerURL(directory: directory, namespace: namespace)
    let first = try u7TestLedger(applicationSupportRoot: directory, namespace: namespace)
    let second = try u7TestLedger(applicationSupportRoot: directory, namespace: namespace)
    let firstName = String(repeating: "1", count: 64)
    let secondName = String(repeating: "2", count: 64)
    let headName = String(repeating: "3", count: 32)
    try await first.recordBeforeSave(
      CKRecord.ID(recordName: firstName, zoneID: SecretSyncCloudKitZones.payloadZoneID)
    )
    try await second.recordBeforeSave(
      CKRecord.ID(recordName: secondName, zoneID: SecretSyncCloudKitZones.payloadZoneID)
    )
    try await first.recordBeforeSave(
      CKRecord.ID(recordName: headName, zoneID: SecretSyncCloudKitZones.controlZoneID)
    )
    #expect(
      Set(try await first.exactRecordIDs().map(\.recordName))
        == [firstName, secondName, headName]
    )
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }

  @Test("proof artifacts are create-only and reject overwrite")
  func immutableArtifactSemantics() async throws {
    let database = SecretSyncLiveArtifactDatabaseFake()
    let recordID = CKRecord.ID(
      recordName: "immutable-proof",
      zoneID: SecretSyncCloudKitZones.controlZoneID
    )
    let record = CKRecord(recordType: "U7SecretSyncProof", recordID: recordID)
    record["payload"] = Data("first".utf8) as CKRecordValue
    try await SecretSyncLiveImmutableArtifactStore.create(record, database: database)

    let replacement = CKRecord(recordType: "U7SecretSyncProof", recordID: recordID)
    replacement["payload"] = Data("replacement".utf8) as CKRecordValue
    await #expect(throws: SecretSyncCloudKitError.incompleteModifyResults) {
      try await SecretSyncLiveImmutableArtifactStore.create(
        replacement, database: database
      )
    }
    #expect(await database.savePolicies == [.ifServerRecordUnchanged, .ifServerRecordUnchanged])
    #expect(await database.zoneMutationCount == 0)

    let unauthorized = CKRecord(
      recordType: "U7SecretSyncProof",
      recordID: CKRecord.ID(
        recordName: "unauthorized-default-zone",
        zoneID: CKRecordZone.default().zoneID
      )
    )
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone
    ) {
      try await SecretSyncLiveImmutableArtifactStore.create(
        unauthorized, database: database
      )
    }
    #expect(await database.savePolicies.count == 2)
  }

  @Test("every proof artifact ID uses only the authorized canonical control zone")
  func authorizedArtifactZones() throws {
    guard case .configured(let values) =
      loadConfiguration(
        environment: completeEnvironment(role: "A", phase: "credential"),
        runtimePlatform: .mac
      )
    else {
      Issue.record("complete proof configuration must load")
      return
    }
    for recordName in values.signedRunManifest.manifest.artifactRecordNames {
      try SecretSyncLiveRunOwnedRecordGrammar.requireArtifact(
        recordName: recordName, namespace: values.runNamespace
      )
      let recordID = CKRecord.ID(
        recordName: recordName, zoneID: values.controlZoneID
      )
      #expect(recordID.zoneID == SecretSyncCloudKitZones.controlZoneID)
      #expect(recordID.zoneID != CKRecordZone.default().zoneID)
    }
    #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone) {
      try SecretSyncLiveArtifactRecordID.requireAuthorized(
        CKRecord.ID(
          recordName: "unauthorized-default-zone",
          zoneID: CKRecordZone.default().zoneID
        ),
        values: values
      )
    }
  }

  @Test("signed host launch grants reject platform substitution expiry and wrong keys")
  func hostLaunchGrantAdmission() {
    let cases: [(
      SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
      SecretSyncLiveRuntimePlatform
    )] = [(.a, .mac), (.b, .iPhone), (.c, .iPad)]
    var digests = Set<Data>()
    for (role, platform) in cases {
      let environment = completeEnvironment(
        role: role.rawValue, phase: "credential"
      )
      guard case .configured(let values) =
        loadConfiguration(
          environment: environment, runtimePlatform: platform
        )
      else {
        Issue.record("authorized matrix role must load: \(role)")
        continue
      }
      #expect(values.launchGrant.manifest.role == role)
      #expect(values.launchGrant.manifest.platform == platform)
      digests.insert(values.launchGrantDigest)
      #expect(
        loadConfiguration(
          environment: environment, runtimePlatform: .unsupported
        ) == .invalid(.matrixPlatformMismatch)
      )
      var substituted = environment
      substituted[SecretSyncLiveCloudKitProofConfiguration.roleKey]
        = role == .a ? "B" : "A"
      #expect(
        loadConfiguration(
          environment: substituted,
          runtimePlatform: role == .a ? .iPhone : .mac
        ) == .invalid(.hostLaunchGrantBindingMismatch)
      )
    }
    #expect(digests.count == 3)

    var callerSubstitution = completeEnvironment(role: "A", phase: "credential")
    callerSubstitution["MOOT_SECRET_SYNC_HOST_AUTHORITY_PUBLIC_KEY"]
      = hostAuthority(seed: 2).publicKey.x963Representation.base64EncodedString()
    guard case .configured = loadConfiguration(
      environment: callerSubstitution, runtimePlatform: .mac
    ) else {
      Issue.record("caller-provided verifier key must not replace the pinned anchor")
      return
    }
    let wrongKey = completeEnvironment(
      role: "A", phase: "credential", authoritySeed: 2
    )
    #expect(
      loadConfiguration(
        environment: wrongKey, runtimePlatform: .mac
      ) == .invalid(.signedRunManifestSignatureInvalid)
    )
    let expired = completeEnvironment(
      role: "A", phase: "credential", expiresAtUnixSeconds: 100
    )
    #expect(
      loadConfiguration(
        environment: expired, runtimePlatform: .mac,
        now: Date(timeIntervalSince1970: 101)
      ) == .invalid(.hostLaunchGrantExpired)
    )

    var mutatedManifest = completeEnvironment(role: "A", phase: "credential")
    let manifestKey = SecretSyncLiveCloudKitProofConfiguration.signedRunManifestKey
    var signedManifest = try! JSONDecoder().decode(
      SecretSyncLiveSignedRunManifest.self,
      from: Data(base64Encoded: mutatedManifest[manifestKey]!)!
    )
    var changedSignature = signedManifest.signature
    changedSignature[changedSignature.index(before: changedSignature.endIndex)] ^= 1
    signedManifest = SecretSyncLiveSignedRunManifest(
      manifest: signedManifest.manifest, signature: changedSignature
    )
    mutatedManifest[manifestKey] = try! JSONEncoder().encode(signedManifest)
      .base64EncodedString()
    #expect(
      loadConfiguration(environment: mutatedManifest, runtimePlatform: .mac)
        == .invalid(.signedRunManifestSignatureInvalid)
    )
  }

  @Test("launch grant ledger rejects nonce replay and wrong credential binding")
  func launchGrantReplayAndCredentialBinding() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-grant-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let nonce = UUID()
    let credentialEnvironment = completeEnvironment(
      role: "A", phase: "credential", nonce: nonce,
      expiresAtUnixSeconds: 1_200
    )
    let credentialValues = try #require(configured(
      credentialEnvironment, runtimePlatform: .mac,
      applicationSupportRoot: directory
    ))
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: namespace,
      runManifestDigest: credentialValues.runManifestDigest
    )
    let signedRunManifestText = try #require(
      credentialEnvironment[SecretSyncLiveCloudKitProofConfiguration.signedRunManifestKey]
    )
    try await ledger.admitLaunchGrant(values: credentialValues)
    await #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay) {
      try await ledger.admitLaunchGrant(values: credentialValues)
    }

    let replayEnvironment = completeEnvironment(
      role: "A", phase: "credential", nonce: nonce,
      signedRunManifestText: signedRunManifestText,
      expiresAtUnixSeconds: 1_201
    )
    let replayValues = try #require(configured(
      replayEnvironment, runtimePlatform: .mac,
      applicationSupportRoot: directory
    ))
    await #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay) {
      try await ledger.admitLaunchGrant(values: replayValues)
    }

    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await ledger.storeCredentialForCleanup(credential, role: .a)
    #expect(try await ledger.credentialIDForCleanup(role: .a) == credential.credentialID)
    let postCredentialDigest = try await ledger.currentContentDigest()
    let wrongBinding = try #require(configured(
      completeEnvironment(
        role: "A", phase: "stage",
        signedRunManifestText: signedRunManifestText,
        credentialBindingDigest: Data(repeating: 0xFE, count: 32),
        expectedLedgerContentDigest: postCredentialDigest
      ), runtimePlatform: .mac, applicationSupportRoot: directory
    ))
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantCredentialMismatch
    ) {
      try await ledger.admitLaunchGrant(values: wrongBinding)
    }
    let correctBinding = try #require(configured(
      completeEnvironment(
        role: "A", phase: "stage",
        signedRunManifestText: signedRunManifestText,
        credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(credential),
        expectedLedgerContentDigest: postCredentialDigest
      ), runtimePlatform: .mac, applicationSupportRoot: directory
    ))
    try await ledger.admitLaunchGrant(values: correctBinding)
    try await ledger.markCredentialRemoved(role: .a)
    #expect(try await ledger.credentialIDForCleanup(role: .a) == nil)
  }

  @Test("final audit rejects reused credential signing and agreement identities")
  func finalAuditCredentialDistinctness() throws {
    let distinct = try SecretSyncLiveDistinctnessFixtures.make()
    try SecretSyncLiveCredentialDistinctness.require(distinct)
    for reuse in [
      SecretSyncLiveDistinctnessFixtures.Reuse.credentialID,
      .signingDescriptor, .signingKeyID, .signingKeyBytes,
      .agreementDescriptor, .agreementKeyID, .agreementKeyBytes,
    ] {
      var candidate = distinct
      candidate[1] = try SecretSyncLiveDistinctnessFixtures.reusing(
        reuse, from: distinct[0], in: distinct[1]
      )
      #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit) {
        try SecretSyncLiveCredentialDistinctness.require(candidate)
      }
    }
  }

  @Test("zone admission requires both exact pre-existing canonical zones")
  func preexistingZoneAdmission() throws {
    let control = SecretSyncCloudKitZones.controlZoneID
    let payload = SecretSyncCloudKitZones.payloadZoneID
    try SecretSyncLiveZoneAdmission.requirePreexisting(
      observed: [control, payload], control: control, payload: payload
    )
    #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.requiredZoneMissing) {
      try SecretSyncLiveZoneAdmission.requirePreexisting(
        observed: [control], control: control, payload: payload
      )
    }
    #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.requiredZoneMissing) {
      try SecretSyncLiveZoneAdmission.requirePreexisting(
        observed: [control, CKRecordZone.ID(zoneName: "wrong-payload")],
        control: control, payload: payload
      )
    }
    #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.requiredZoneMissing) {
      try SecretSyncLiveZoneAdmission.requirePreexisting(
        observed: [
          control,
          CKRecordZone.ID(zoneName: payload.zoneName, ownerName: "wrong-owner"),
        ],
        control: control, payload: payload
      )
    }
  }

  @Test("cleanup includes and verifies the production head under an exact two-zone allowlist")
  func authorizedCleanupIncludesHead() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-cleanup-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let headID = SecretSyncHeadCAS.recordID(for: SecretScopeID(
      UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    ))
    let artifactID = CKRecord.ID(
      recordName: "\(namespace)-manifest-A",
      zoneID: SecretSyncCloudKitZones.controlZoneID
    )
    let payloadID = CKRecord.ID(
      recordName: String(repeating: "a", count: 64),
      zoneID: SecretSyncCloudKitZones.payloadZoneID
    )
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: namespace
    )
    try await ledger.storeCredentialForCleanup(credential, role: .a)
    let values = try cleanupValues(
      role: .a, directory: directory,
      recordIDs: [artifactID, payloadID, headID],
      expectedLedgerContentDigest: try await ledger.currentContentDigest(),
      credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(credential)
    )
    let authorization = try #require(values.cleanupAuthorization)
    let exact = try SecretSyncLiveCleanupPlan.authorizedRecordIDs(
      authorization: authorization, values: values
    )
    #expect(Set(exact) == Set([artifactID, payloadID, headID]))
    try await ledger.admitLaunchGrant(values: values)
    _ = try await ledger.checkpointCleanupPrerequisites(
      including: exact, cleanupAuthorization: authorization
    )
    let database = SecretSyncLiveArtifactDatabaseFake()
    await database.seed(recordIDs: exact)
    try await SecretSyncLiveCleanupPlan.deleteAndVerify(
      exact, values: values, database: database, ledger: ledger
    )
    #expect(await database.deletedRecordIDs == Set(exact))
    #expect(try await ledger.exactRecordIDs().isEmpty)

    for zoneName in [CKRecordZone.default().zoneID.zoneName, "preseeded-foreign-zone"] {
      let corrupted = [
        SecretSyncLiveRecordReference(recordName: "hostile", zoneName: zoneName)
      ]
      #expect(throws: (any Error).self) {
        let bad = SecretSyncLiveSignedCleanupAuthorization(
          manifest: .init(
            version: 1, namespace: values.runNamespace,
            runManifestDigest: values.runManifestDigest,
            records: corrupted,
            allowedZones: SecretSyncLiveCleanupAuthorizationVerifier.exactZones,
            inventoryDigest: Data(repeating: 1, count: 32),
            issuedAtUnixSeconds: 1_000, expiresAtUnixSeconds: 1_200,
            nonce: UUID()
          ), signature: Data()
        )
        _ = try SecretSyncLiveCleanupPlan.authorizedRecordIDs(
          authorization: bad, values: values
        )
      }
    }
    #expect(await database.deleteInvocationCount == 2)
  }

  @Test("cleanup retries only unresolved exact IDs after partial and verification loss")
  func cleanupRetrySemantics() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let control = CKRecord.ID(
      recordName: "\(namespace)-manifest-A",
      zoneID: SecretSyncCloudKitZones.controlZoneID
    )
    let payload = CKRecord.ID(
      recordName: String(repeating: "b", count: 64),
      zoneID: SecretSyncCloudKitZones.payloadZoneID
    )
    let alreadyAbsent = CKRecord.ID(
      recordName: String(repeating: "c", count: 64),
      zoneID: SecretSyncCloudKitZones.payloadZoneID
    )
    let exact = [control, payload, alreadyAbsent]

    let partialDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-partial-cleanup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: partialDirectory) }
    let partialLedger = try u7TestLedger(
      applicationSupportRoot: partialDirectory, namespace: namespace
    )
    let partialCredential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await partialLedger.storeCredentialForCleanup(partialCredential, role: .a)
    let values = try cleanupValues(
      role: .a, directory: partialDirectory, recordIDs: exact,
      expectedLedgerContentDigest: try await partialLedger.currentContentDigest(),
      credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(partialCredential)
    )
    try await partialLedger.admitLaunchGrant(values: values)
    let partialDatabase = SecretSyncLiveArtifactDatabaseFake()
    await partialDatabase.seed(recordIDs: [control, payload])
    await partialDatabase.setDeleteFailures([payload])
    let firstAttempt = try await partialLedger.checkpointCleanupPrerequisites(
      including: exact, cleanupAuthorization: try #require(values.cleanupAuthorization)
    )
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    ) {
      try await SecretSyncLiveCleanupPlan.deleteAndVerify(
        firstAttempt, values: values, database: partialDatabase,
        ledger: partialLedger
      )
    }
    #expect(try await partialLedger.exactRecordIDs() == [payload])
    await partialDatabase.setDeleteFailures([])
    let retry = try #require(try await partialLedger.preparedCleanupRecordIDs())
    #expect(retry == [payload])
    try await SecretSyncLiveCleanupPlan.deleteAndVerify(
      retry, values: values, database: partialDatabase, ledger: partialLedger
    )
    #expect(try await partialLedger.exactRecordIDs().isEmpty)

    let lossDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-verification-loss-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: lossDirectory) }
    let lossLedger = try u7TestLedger(
      applicationSupportRoot: lossDirectory, namespace: namespace
    )
    let lossCredential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await lossLedger.storeCredentialForCleanup(lossCredential, role: .a)
    let lossValues = try cleanupValues(
      role: .a, directory: lossDirectory, recordIDs: [control, payload],
      expectedLedgerContentDigest: try await lossLedger.currentContentDigest(),
      credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(lossCredential)
    )
    try await lossLedger.admitLaunchGrant(values: lossValues)
    let lossDatabase = SecretSyncLiveArtifactDatabaseFake()
    await lossDatabase.seed(recordIDs: [control, payload])
    await lossDatabase.failNextAbsenceVerification()
    let lossAttempt = try await lossLedger.checkpointCleanupPrerequisites(
      including: [control, payload],
      cleanupAuthorization: try #require(lossValues.cleanupAuthorization)
    )
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    ) {
      try await SecretSyncLiveCleanupPlan.deleteAndVerify(
        lossAttempt, values: lossValues, database: lossDatabase, ledger: lossLedger
      )
    }
    #expect(Set(try await lossLedger.exactRecordIDs()) == Set([control, payload]))
    let lossRetry = try #require(try await lossLedger.preparedCleanupRecordIDs())
    try await SecretSyncLiveCleanupPlan.deleteAndVerify(
      lossRetry, values: lossValues, database: lossDatabase, ledger: lossLedger
    )
    #expect(try await lossLedger.exactRecordIDs().isEmpty)
  }

  @Test("A cleanup entry retries from its frozen checkpoint without prerequisite reloads")
  func cleanupEntryPointResumesFrozenSet() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-entry-a-cleanup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: namespace
    )
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await ledger.storeCredentialForCleanup(credential, role: .a)
    let exact = [
      CKRecord.ID(
        recordName: "\(namespace)-manifest-A",
        zoneID: SecretSyncCloudKitZones.controlZoneID
      ),
      CKRecord.ID(
        recordName: String(repeating: "d", count: 64),
        zoneID: SecretSyncCloudKitZones.payloadZoneID
      ),
    ]
    let values = try cleanupValues(
      role: .a, directory: directory, recordIDs: exact,
      expectedLedgerContentDigest: try await ledger.currentContentDigest(),
      credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(credential)
    )
    try await ledger.admitLaunchGrant(values: values)
    let database = SecretSyncLiveArtifactDatabaseFake()
    await database.seed(recordIDs: exact)
    await database.failNextAbsenceVerification()
    let probe = SecretSyncLiveCleanupEntryProbe()
    #expect(try await SecretSyncLiveCleanupEntryPoint.requiresInitialZoneAdmission(
      values: values, ledger: ledger
    ))

    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    ) {
      try await SecretSyncLiveCleanupEntryPoint.run(
        values: values, ledger: ledger, database: database,
        expectedRecordIDs: { exact },
        verifyAPrerequisites: { await probe.recordPrerequisiteVerification() },
        removeCredential: { _ in await probe.recordCredentialRemoval() },
        publishOrValidateMarker: { _ in Issue.record("A never publishes a marker") }
      )
    }
    #expect(Set(try await ledger.frozenCleanupRecordIDs()) == Set(exact))
    #expect(Set(try #require(try await ledger.preparedCleanupRecordIDs())) == Set(exact))
    #expect(!(try await SecretSyncLiveCleanupEntryPoint.requiresInitialZoneAdmission(
      values: values, ledger: ledger
    )))

    try await SecretSyncLiveCleanupEntryPoint.run(
      values: values, ledger: ledger, database: database,
      expectedRecordIDs: {
        Issue.record("retry must not rebuild the frozen cleanup set")
        return []
      },
      verifyAPrerequisites: {
        Issue.record("retry must not reload CloudKit prerequisites")
      },
      removeCredential: { _ in
        Issue.record("retry must not remove an already-removed credential")
      },
      publishOrValidateMarker: { _ in Issue.record("A never publishes a marker") }
    )
    #expect(await probe.prerequisiteVerificationCount == 1)
    #expect(await probe.credentialRemovalCount == 1)
    #expect(try await ledger.localCleanupCompleted(role: .a))
    #expect(try await ledger.exactRecordIDs().isEmpty)
  }

  @Test("B cleanup entry accepts an absent key and validates an existing exact marker")
  func cleanupEntryPointRetriesExistingMarker() async throws {
    let values = try #require(configured(
      completeEnvironment(role: "B", phase: "cleanup"), runtimePlatform: .iPhone
    ))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-entry-b-cleanup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: values.runNamespace,
      role: .b, runManifestDigest: values.runManifestDigest
    )
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await ledger.storeCredentialForCleanup(credential, role: .b)
    let database = SecretSyncLiveArtifactDatabaseFake()
    let probe = SecretSyncLiveCleanupEntryProbe()

    await #expect(throws: SecretSyncLiveArtifactFakeError.postSaveCrash) {
      try await SecretSyncLiveCleanupEntryPoint.run(
        values: values, ledger: ledger, database: database,
        expectedRecordIDs: { [] }, verifyAPrerequisites: {},
        removeCredential: { _ in
          await probe.recordCredentialRemoval()
          throw SecretSyncCustodyError.missingHandle
        },
        publishOrValidateMarker: { marker in
          if await probe.shouldCrashAfterFirstMarkerSave() {
            throw SecretSyncLiveArtifactFakeError.postSaveCrash
          }
        }
      )
    }
    #expect(!(try await ledger.localCleanupCompleted(role: .b)))

    try await SecretSyncLiveCleanupEntryPoint.run(
      values: values, ledger: ledger, database: database,
      expectedRecordIDs: { [] }, verifyAPrerequisites: {},
      removeCredential: { _ in
        Issue.record("retry must accept the already-removed local credential")
      },
      publishOrValidateMarker: { marker in
        _ = await probe.shouldCrashAfterFirstMarkerSave()
      }
    )
    #expect(await probe.credentialRemovalCount == 1)
    #expect(await probe.markerSaveCount == 2)
    #expect(try await ledger.localCleanupCompleted(role: .b))
  }

  @Test("production recovery staging reports exact break-glass and rotation outcomes")
  func truthfulRecoveryStagingOutcomes() async throws {
    let commitment = try SecretBootstrapFreshnessCommitment(
      scopeID: U7GoldenVectors.scopeID, latestPolicyEpoch: 1,
      headCommitDigest: U7GoldenVectors.digest(0xD1),
      policyDigest: U7GoldenVectors.digest(0xD2)
    )
    let generationID = SecretGenerationID(U7UUID.byte(0xD3))
    let breakGlass = try await SecretSyncLiveRecoveryExercise.stageBreakGlass(
      commitment: commitment, generationID: generationID
    )
    let rotation = try await SecretSyncLiveRecoveryExercise.stageRotation(
      commitment: commitment, currentGenerationID: generationID
    )
    #expect(breakGlass.seam == "SecretSyncRecoveryKeyCustody.stageBreakGlass")
    #expect(rotation.seam == "SecretSyncRecoveryKeyCustody.stageRotation")
    #expect(breakGlass.digest != rotation.digest)
    #expect(
      try SecretSyncLiveRecoveryExercise.validateStored(
        breakGlass.evidenceBytes, operation: .breakGlass,
        seam: breakGlass.seam
      ) == breakGlass
    )
    #expect(
      try SecretSyncLiveRecoveryExercise.validateStored(
        rotation.evidenceBytes, operation: .rotation,
        seam: rotation.seam
      ) == rotation
    )
  }

  @Test("production freshness transport returns only the exact protected floor offline")
  func truthfulOfflineFallback() async throws {
    let floor = try SecretBootstrapFreshnessCommitment(
      scopeID: U7GoldenVectors.scopeID, latestPolicyEpoch: 7,
      headCommitDigest: U7GoldenVectors.digest(0xE1),
      policyDigest: U7GoldenVectors.digest(0xE2)
    )
    let database = SecretSyncLiveArtifactDatabaseFake()
    await database.setNetworkFailure(true)
    let returned = try await SecretSyncFreshnessTransport(database: database)
      .normalPathCommitment(
        for: floor.scopeID,
        authority: .protectedLocal(SecretSyncLiveProtectedFloor(commitment: floor))
      )
    #expect(returned == floor)
    #expect(await database.fetchInvocationCount == 1)
  }

  @Test("canonical credential attestation rejects every proof mutation")
  func completeAttestationVerification() throws {
    let fixture = try SecretSyncLiveAttestationFixture.make()
    #expect(
      try SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
        expectedLaunchGrantDigest: fixture.launchGrantDigest,
        credentialRecordName: fixture.credentialRecordName,
        verifierRecordName: fixture.verifierRecordName,
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
    for mutation in SecretSyncLiveAttestationFixture.Mutation.allCases {
      #expect(
        try !SecretSyncLiveAttestation.verify(
          fixture.mutated(mutation), namespace: fixture.namespace, role: .a,
          expectedLaunchGrantDigest: fixture.launchGrantDigest,
          credentialRecordName: fixture.credentialRecordName,
          verifierRecordName: fixture.verifierRecordName,
          agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
        ), "mutation must reject: \(mutation)"
      )
    }
    #expect(
      try !SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
          expectedLaunchGrantDigest: fixture.launchGrantDigest,
        credentialRecordName: fixture.credentialRecordName + "-tampered",
        verifierRecordName: fixture.verifierRecordName,
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
    #expect(
      try !SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
        expectedLaunchGrantDigest: fixture.launchGrantDigest,
        credentialRecordName: fixture.credentialRecordName,
        verifierRecordName: fixture.verifierRecordName + "-tampered",
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
  }

  @Test("ledger rejects symlinks and unsafe directory modes")
  func hardenedLedgerFilesystemBoundary() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-ledger-hardening-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let target = root.appendingPathComponent("attacker.json")
    _ = FileManager.default.createFile(atPath: target.path, contents: Data("{}".utf8))
    let ledgerPath = ledgerURL(directory: root, namespace: namespace)
    try FileManager.default.createDirectory(
      at: ledgerPath.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try FileManager.default.createSymbolicLink(at: ledgerPath, withDestinationURL: target)
    let ledger = try u7TestLedger(applicationSupportRoot: root, namespace: namespace)
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
    ) {
      try await ledger.recordBeforeSave(
        CKRecord.ID(
          recordName: "\(namespace)-manifest-A",
          zoneID: SecretSyncCloudKitZones.controlZoneID
        )
      )
    }

    try FileManager.default.removeItem(at: ledgerPath)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: ledgerPath.deletingLastPathComponent().path
    )
    let unsafeLedger = try u7TestLedger(
      applicationSupportRoot: root, namespace: namespace
    )
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
    ) {
      _ = try await unsafeLedger.currentContentDigest()
    }
  }

  @Test("credential publication reconciles exact ambiguity and fails closed otherwise")
  func crashSafeCredentialPublication() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-credential-rollback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: namespace
    )
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    let generation = SecretSyncCustodyCredentialGeneration(
      deviceID: credential.deviceID, credentialID: credential.credentialID,
      signingHandle: SigningPrivateKeyHandle(UUID()),
      agreementHandle: KeyAgreementPrivateKeyHandle(UUID()),
      signingPublicKey: credential.signingPublicKey,
      agreementPublicKey: credential.keyAgreementPublicKey
    )
    try await ledger.checkpointProvisionalCredential(generation, role: .a)
    let exact = try await SecretSyncLiveCredentialPublicationBoundary.run(
      generation: generation, role: .a, ledger: ledger,
      removeBothHandles: { _ in
        Issue.record("exact create-only reconciliation must not roll back")
      },
      clearCheckpoint: {
        try await ledger.clearCredentialCheckpoint(role: .a)
      },
      publish: { throw SecretSyncLiveArtifactFakeError.postSaveCrash },
      reconcilePublication: { Data("exact-existing-artifact".utf8) }
    )
    #expect(exact == Data("exact-existing-artifact".utf8))
    #expect(try await ledger.credentialCheckpoint(role: .a)?.published == true)

    let absentDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-credential-absent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: absentDirectory) }
    let absentLedger = try u7TestLedger(
      applicationSupportRoot: absentDirectory, namespace: namespace,
      role: .b
    )
    try await absentLedger.checkpointProvisionalCredential(generation, role: .b)
    let probe = SecretSyncLiveCleanupEntryProbe()
    await #expect(throws: SecretSyncLiveArtifactFakeError.postSaveCrash) {
      _ = try await SecretSyncLiveCredentialPublicationBoundary.run(
        generation: generation, role: .b, ledger: absentLedger,
        removeBothHandles: { removedID in
          #expect(removedID == generation.credentialID)
          await probe.recordCredentialRemoval()
        },
        clearCheckpoint: {
          try await absentLedger.clearCredentialCheckpoint(role: .b)
        },
        publish: { throw SecretSyncLiveArtifactFakeError.postSaveCrash },
        reconcilePublication: { nil }
      ) as Data
    }
    #expect(await probe.credentialRemovalCount == 1)
    #expect(try await absentLedger.credentialCheckpoint(role: .b) == nil)

    let uncertainDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-credential-uncertain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: uncertainDirectory) }
    let uncertainLedger = try u7TestLedger(
      applicationSupportRoot: uncertainDirectory, namespace: namespace,
      role: .c
    )
    try await uncertainLedger.checkpointProvisionalCredential(generation, role: .c)
    await #expect(throws: SecretSyncLiveArtifactFakeError.mismatch) {
      _ = try await SecretSyncLiveCredentialPublicationBoundary.run(
        generation: generation, role: .c, ledger: uncertainLedger,
        removeBothHandles: { _ in
          Issue.record("uncertain publication must preserve exact handles")
        },
        clearCheckpoint: {
          try await uncertainLedger.clearCredentialCheckpoint(role: .c)
        },
        publish: { throw SecretSyncLiveArtifactFakeError.postSaveCrash },
        reconcilePublication: { throw SecretSyncLiveArtifactFakeError.mismatch }
      ) as Data
    }
    #expect(try await uncertainLedger.credentialCheckpoint(role: .c)?.published == false)

    let clearFailureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-credential-clear-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: clearFailureDirectory) }
    let clearFailureLedger = try u7TestLedger(
      applicationSupportRoot: clearFailureDirectory, namespace: namespace
    )
    try await clearFailureLedger.checkpointProvisionalCredential(
      generation, role: .a
    )
    await #expect(throws: SecretSyncLiveArtifactFakeError.mismatch) {
      _ = try await SecretSyncLiveCredentialPublicationBoundary.run(
        generation: generation, role: .a, ledger: clearFailureLedger,
        removeBothHandles: { _ in await probe.recordCredentialRemoval() },
        clearCheckpoint: { throw SecretSyncLiveArtifactFakeError.mismatch },
        publish: { throw SecretSyncLiveArtifactFakeError.postSaveCrash },
        reconcilePublication: { nil }
      ) as Data
    }
    #expect(
      try await clearFailureLedger.credentialCheckpoint(role: .a) != nil
    )

    let removalFailureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-credential-removal-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: removalFailureDirectory) }
    let removalFailureLedger = try u7TestLedger(
      applicationSupportRoot: removalFailureDirectory, namespace: namespace,
      role: .b
    )
    try await removalFailureLedger.checkpointProvisionalCredential(
      generation, role: .b
    )
    await #expect(throws: SecretSyncCustodyError.missingEntitlement) {
      _ = try await SecretSyncLiveCredentialPublicationBoundary.run(
        generation: generation, role: .b, ledger: removalFailureLedger,
        removeBothHandles: { _ in
          throw SecretSyncCustodyError.missingEntitlement
        },
        clearCheckpoint: {
          Issue.record("failed strict removal must not clear the checkpoint")
        },
        publish: { throw SecretSyncLiveArtifactFakeError.postSaveCrash },
        reconcilePublication: { nil }
      ) as Data
    }
    #expect(
      try await removalFailureLedger.credentialCheckpoint(role: .b) != nil
    )
  }

  @Test("audit publication remains retryable until one completion-and-erasure transaction")
  func verifierPrivateKeyErasure() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-verifier-erasure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try u7TestLedger(
      applicationSupportRoot: directory, namespace: namespace
    )
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      try await ledger.storeAgreementVerifierPrivateKey(
        Data(repeating: UInt8(role.rawValue.utf8.first!), count: 32), role: role
      )
    }
    let fixture = try SecretSyncLiveSignedArtifactFixture.make()
    let evidence = SecretSyncLiveEvidence(
      timestamp: Date(timeIntervalSince1970: 1_000), deviceRole: .a,
      operation: .configuration, resultCode: .passed, headRelation: .exact,
      productionSeam: nil, outcomeDigest: nil
    )
    await #expect(throws: SecretSyncLiveArtifactFakeError.postSaveCrash) {
      try await SecretSyncLiveAuditCompletionBoundary.run(
        envelope: fixture.envelope, evidence: evidence,
        stage: { envelope in try await ledger.stageAuditEnvelope(envelope) },
        publishOrValidate: { _ in throw SecretSyncLiveArtifactFakeError.postSaveCrash },
        commitCompletionAndErase: { evidence in
          try await ledger.completeAuditAndEraseVerifierKeys(evidence: evidence)
        }
      )
    }
    #expect(try await ledger.stagedAuditEnvelope() == fixture.envelope)
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      _ = try await ledger.agreementVerifierPrivateKey(role: role)
    }

    await #expect(throws: SecretSyncLiveArtifactFakeError.mismatch) {
      try await SecretSyncLiveAuditCompletionBoundary.run(
        envelope: fixture.envelope, evidence: evidence,
        stage: { envelope in try await ledger.stageAuditEnvelope(envelope) },
        publishOrValidate: { _ in },
        commitCompletionAndErase: { _ in
          throw SecretSyncLiveArtifactFakeError.mismatch
        }
      )
    }
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      _ = try await ledger.agreementVerifierPrivateKey(role: role)
    }

    try await SecretSyncLiveAuditCompletionBoundary.run(
      envelope: fixture.envelope, evidence: evidence,
      stage: { envelope in try await ledger.stageAuditEnvelope(envelope) },
      publishOrValidate: { envelope in #expect(envelope == fixture.envelope) },
      commitCompletionAndErase: { evidence in
        try await ledger.completeAuditAndEraseVerifierKeys(evidence: evidence)
      }
    )
    try await ledger.require(.audit, role: .a)
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      await #expect(
        throws: SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      ) { _ = try await ledger.agreementVerifierPrivateKey(role: role) }
    }
  }

  /// This remains one cohesive table-driven recovery proof so every injected
  /// fault follows the same seed, fail, reload, verify, retry, and erase path.
  @Test("every reported audit ledger fault preserves keys and retryability")
  func auditLedgerFaultRecovery() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let fixture = try SecretSyncLiveSignedArtifactFixture.make()
    let evidence = SecretSyncLiveEvidence(
      timestamp: Date(timeIntervalSince1970: 1_000), deviceRole: .a,
      operation: .configuration, resultCode: .passed, headRelation: .exact,
      productionSeam: nil, outcomeDigest: nil
    )
    for fault in SecretSyncLiveAuditLedgerFault.allCases {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-audit-fault-\(fault)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: directory) }
      let ledger = try u7TestLedger(
        applicationSupportRoot: directory, namespace: namespace
      )
      for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
        try await ledger.storeAgreementVerifierPrivateKey(
          Data(repeating: UInt8(role.rawValue.utf8.first!), count: 32),
          role: role
        )
      }
      try await ledger.stageAuditEnvelope(fixture.envelope)

      await #expect(
        throws: SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
      ) {
        try await ledger.completeAuditAndEraseVerifierKeys(
          evidence: evidence, injecting: fault
        )
      }
      let reloaded = try u7TestLedger(
        applicationSupportRoot: directory, namespace: namespace
      )
      for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
        _ = try await reloaded.agreementVerifierPrivateKey(role: role)
      }
      await #expect(
        throws: SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      ) { try await reloaded.require(.audit, role: .a) }

      try await reloaded.completeAuditAndEraseVerifierKeys(evidence: evidence)
      try await reloaded.require(.audit, role: .a)
      for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
        await #expect(
          throws: SecretSyncLiveCloudKitProofConfigurationError
            .missingPrerequisitePhase
        ) { _ = try await reloaded.agreementVerifierPrivateKey(role: role) }
      }
      let residualAuditSlots = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains(".audit-") }
      #expect(residualAuditSlots.isEmpty)
    }
  }

  @Test("restart cleanup converges after zero one or two handle inserts")
  func provisionalRestartConvergence() async throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    let generation = SecretSyncCustodyCredentialGeneration(
      deviceID: credential.deviceID,
      credentialID: credential.credentialID,
      signingHandle: SigningPrivateKeyHandle(UUID()),
      agreementHandle: KeyAgreementPrivateKeyHandle(UUID()),
      signingPublicKey: credential.signingPublicKey,
      agreementPublicKey: credential.keyAgreementPublicKey
    )
    for insertedCount in 0...2 {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("u7-restart-\(insertedCount)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: directory) }
      let ledger = try u7TestLedger(
        applicationSupportRoot: directory, namespace: namespace
      )
      try await ledger.checkpointProvisionalCredential(generation, role: .a)
      let handles = SecretSyncRestartHandleProbe(insertedCount: insertedCount)
      try await SecretSyncLiveCredentialPublicationBoundary
        .removeInterruptedProvisional(
          role: .a,
          ledger: ledger,
          removeBothHandles: { credentialID in
            #expect(credentialID == generation.credentialID)
            try await handles.removeBoth()
          }
        )
      #expect(await handles.remainingCount == 0)
      #expect(await handles.removalAttemptCount == 2)
      #expect(try await ledger.credentialCheckpoint(role: .a) == nil)
    }
  }

  @Test("phase verifier rejects complete grant context credential and key substitution")
  func signedArtifactVerifierUsesIndependentAuthority() throws {
    let fixture = try SecretSyncLiveSignedArtifactFixture.make()
    #expect(try fixture.verify(fixture.envelope))
    for mutation in SecretSyncLiveSignedArtifactFixture.Mutation.allCases {
      #expect(
        try !fixture.verify(fixture.mutated(mutation)),
        "independently approved context must reject \(mutation)"
      )
    }
  }

  @Test("later phases accept only the exact non-nil credential binding")
  func laterPhaseCredentialBindingIsExact() throws {
    let accepted = try SecretSyncLiveSignedArtifactFixture.make(phase: .verify)
    let exactBinding = SecretSyncLiveCredentialBinding.digest(
      accepted.credential
    )
    #expect(accepted.grant.manifest.credentialBindingDigest == exactBinding)
    #expect(try accepted.verify(accepted.envelope))
    #expect(try !accepted.verify(accepted.mutated(.credentialBinding)))

    let wrongGrantBinding = try SecretSyncLiveSignedArtifactFixture.make(
      phase: .verify,
      grantCredentialBinding: Data(repeating: 0xEE, count: 32)
    )
    #expect(
      wrongGrantBinding.grant.manifest.credentialBindingDigest != exactBinding
    )
    #expect(try !wrongGrantBinding.verify(wrongGrantBinding.envelope))
  }

  private func completeEnvironment(
    role: String,
    phase: String,
    nonce: UUID = UUID(),
    authoritySeed: UInt8 = 1,
    signedRunManifestText: String? = nil,
    credentialBindingDigest: Data? = nil,
    expectedLedgerContentDigest: Data? = nil,
    prerequisiteArtifactDigests: [Data] = [],
    trustedCredentialGrantDigestsByRole: [String: Data] = [:],
    issuedAtUnixSeconds: Int64 = 1_000,
    expiresAtUnixSeconds: Int64 = 1_200,
    destinationBindingDigest: Data? = nil,
    cleanupAuthorizationDigest: Data? = nil,
    cleanupAuthorizationRecords: [SecretSyncLiveRecordReference] = []
  ) -> [String: String] {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let parsedRole = SecretSyncLiveCloudKitProofConfiguration.DeviceRole(rawValue: role) ?? .a
    let parsedPhase = SecretSyncLiveCloudKitProofConfiguration.Phase(rawValue: phase) ?? .credential
    let binding = parsedPhase == .credential
      ? nil
      : credentialBindingDigest ?? Data(repeating: parsedRole == .a ? 0xA1 : 0xB1, count: 32)
    let authority = hostAuthority(seed: authoritySeed)
    let signedRunManifest: SecretSyncLiveSignedRunManifest
    if let signedRunManifestText,
      let bytes = Data(base64Encoded: signedRunManifestText),
      let decoded = try? JSONDecoder().decode(
        SecretSyncLiveSignedRunManifest.self, from: bytes
      )
    {
      signedRunManifest = decoded
    } else {
      let artifactRecordNames = u7ExactArtifactNames(namespace: namespace)
      let runManifestBody = SecretSyncLiveSignedRunManifest.Manifest(
        version: 2, runNamespace: namespace,
        ledgerIdentifier: SecretSyncLiveSignedRunManifestVerifier
          .expectedLedgerIdentifier(namespace: namespace),
        artifactRecordNames: artifactRecordNames
      )
      let body = try! SecretSyncLiveSignedRunManifestVerifier
        .canonicalManifestBytes(runManifestBody)
      signedRunManifest = SecretSyncLiveSignedRunManifest(
        manifest: runManifestBody,
        signature: try! authority.signature(for: body).derRepresentation
      )
    }
    let runManifestBytes = try! SecretSyncLiveSignedRunManifestVerifier
      .canonicalManifestBytes(signedRunManifest.manifest)
    let runManifestDigest = SecretSyncLiveSignedRunManifestVerifier.digest(
      manifestBytes: runManifestBytes, signature: signedRunManifest.signature
    )
    let signedCleanupAuthorization: SecretSyncLiveSignedCleanupAuthorization?
    if parsedPhase == .cleanup {
      let cleanupManifest = SecretSyncLiveSignedCleanupAuthorization.Manifest(
        version: 1, namespace: namespace,
        runManifestDigest: runManifestDigest,
        records: cleanupAuthorizationRecords.sorted(
          by: SecretSyncLiveCleanupAuthorizationVerifier.recordOrder
        ),
        allowedZones: SecretSyncLiveCleanupAuthorizationVerifier.exactZones,
        inventoryDigest: Data(repeating: 0x1A, count: 32),
        issuedAtUnixSeconds: issuedAtUnixSeconds,
        expiresAtUnixSeconds: expiresAtUnixSeconds,
        nonce: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
      )
      let body = try! SecretSyncLiveCleanupAuthorizationVerifier
        .canonicalManifestBytes(cleanupManifest)
      signedCleanupAuthorization = SecretSyncLiveSignedCleanupAuthorization(
        manifest: cleanupManifest,
        signature: try! authority.signature(for: body).derRepresentation
      )
    } else {
      signedCleanupAuthorization = nil
    }
    let actualCleanupAuthorizationDigest = signedCleanupAuthorization.map {
      SecretSyncLiveCleanupAuthorizationVerifier.digest(
        manifestBytes: try! SecretSyncLiveCleanupAuthorizationVerifier
          .canonicalManifestBytes($0.manifest),
        signature: $0.signature
      )
    }
    let manifest = SecretSyncLiveHostLaunchGrant.Manifest(
      version: 2,
      runNamespace: namespace,
      role: parsedRole, phase: parsedPhase,
      platform: SecretSyncLivePlatformMatrix.expectedPlatform(for: parsedRole),
      nonce: nonce, issuedAtUnixSeconds: issuedAtUnixSeconds,
      expiresAtUnixSeconds: expiresAtUnixSeconds,
      runManifestDigest: runManifestDigest,
      destinationBindingDigest: destinationBindingDigest
        ?? Data(repeating: parsedRole == .a ? 0xDA : parsedRole == .b ? 0xDB : 0xDC, count: 32),
      expectedLedgerContentDigest: expectedLedgerContentDigest
        ?? SecretSyncLiveCleanupLedger.initialContentDigest(
          namespace: namespace,
          logicalLedgerIdentifier: signedRunManifest.manifest.ledgerIdentifier,
          role: parsedRole, signedRunManifestDigest: runManifestDigest
        ),
      prerequisiteArtifactDigests: prerequisiteArtifactDigests,
      trustedCredentialGrantDigestsByRole: trustedCredentialGrantDigestsByRole,
      credentialBindingDigest: binding,
      cleanupAuthorizationDigest: parsedPhase == .cleanup
        ? cleanupAuthorizationDigest ?? actualCleanupAuthorizationDigest
        : nil
    )
    let body = try! SecretSyncLiveHostLaunchGrantVerifier.canonicalManifestBytes(manifest)
    let signature = try! authority.signature(for: body).derRepresentation
    let grant = SecretSyncLiveHostLaunchGrant(
      manifest: manifest, signature: signature
    )
    let grantBytes = try! JSONEncoder().encode(grant)
    let signedRunManifestBytes = try! JSONEncoder().encode(signedRunManifest)
    var result = [
      SecretSyncLiveCloudKitProofConfiguration.optInKey: "1",
      SecretSyncLiveCloudKitProofConfiguration.attestationKey:
        "AUTHORIZED_U7_HOST_LAUNCH_GRANT",
      SecretSyncLiveCloudKitProofConfiguration.namespaceKey:
        "u7-00112233-4455-6677-8899-aabbccddeeff",
      SecretSyncLiveCloudKitProofConfiguration.roleKey: role,
      SecretSyncLiveCloudKitProofConfiguration.phaseKey: phase,
      SecretSyncLiveCloudKitProofConfiguration.signedRunManifestKey:
        signedRunManifestBytes.base64EncodedString(),
      SecretSyncLiveCloudKitProofConfiguration.hostLaunchGrantKey:
        grantBytes.base64EncodedString(),
    ]
    if let signedCleanupAuthorization {
      result[SecretSyncLiveCloudKitProofConfiguration.cleanupAuthorizationKey]
        = try! JSONEncoder().encode(signedCleanupAuthorization).base64EncodedString()
    }
    return result
  }

  private func cleanupValues(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    directory: URL,
    recordIDs: [CKRecord.ID],
    expectedLedgerContentDigest: Data? = nil,
    credentialBindingDigest: Data? = nil
  ) throws -> SecretSyncLiveCloudKitProofConfiguration.Values {
    return try #require(configured(
      completeEnvironment(
        role: role.rawValue, phase: "cleanup",
        credentialBindingDigest: credentialBindingDigest,
        expectedLedgerContentDigest: expectedLedgerContentDigest,
        cleanupAuthorizationRecords: recordIDs.map {
          SecretSyncLiveRecordReference(
            recordName: $0.recordName, zoneName: $0.zoneID.zoneName
          )
        }
      ),
      runtimePlatform: SecretSyncLivePlatformMatrix.expectedPlatform(for: role),
      applicationSupportRoot: directory
    ))
  }

  private func hostAuthority(seed: UInt8) -> P256.Signing.PrivateKey {
    var raw = Data(repeating: 0, count: 32)
    raw[31] = seed
    return try! P256.Signing.PrivateKey(rawRepresentation: raw)
  }

  private func ledgerURL(directory: URL, namespace: String) -> URL {
    u7TestLedgerURL(applicationSupportRoot: directory, namespace: namespace)
  }

  private func configured(
    _ environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    applicationSupportRoot: URL = URL(fileURLWithPath: "/tmp/u7-config-tests", isDirectory: true)
  ) -> SecretSyncLiveCloudKitProofConfiguration.Values? {
    guard case .configured(let values) = loadConfiguration(
      environment: environment, runtimePlatform: runtimePlatform,
      applicationSupportRoot: applicationSupportRoot
    ) else { return nil }
    return values
  }

  private func loadConfiguration(
    environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date = Date(timeIntervalSince1970: 1_100),
    applicationSupportRoot: URL = URL(fileURLWithPath: "/tmp/u7-config-tests", isDirectory: true)
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    SecretSyncLiveCloudKitProofConfiguration.loadForDeterministicTesting(
      environment: environment, runtimePlatform: runtimePlatform, now: now,
      independentlyAuthenticatedHostAuthorityPublicKey:
        hostAuthority(seed: 1).publicKey.x963Representation,
      applicationSupportRoot: applicationSupportRoot
    )
  }
}

private struct U7ProcessResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private func u7RunProcess(
  executable: String,
  arguments: [String],
  environment: [String: String] = [:]
) throws -> U7ProcessResult {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = ProcessInfo.processInfo.environment.merging(
    environment, uniquingKeysWith: { _, replacement in replacement }
  )
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()
  return U7ProcessResult(
    status: process.terminationStatus,
    stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
    stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  )
}

private func u7CompileStandaloneHost(root: URL) throws -> URL {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let executable = root.appendingPathComponent("u7-host")
  let result = try u7RunProcess(
    executable: "/usr/bin/xcrun",
    arguments: [
      "swiftc", packageRoot.appendingPathComponent("U7LiveProofHost/main.swift").path,
      "-o", executable.path,
    ]
  )
  guard result.status == 0 else {
    throw SecretSyncLiveCloudKitProofConfigurationError.attachmentMalformed
  }
  return executable
}

private func u7WriteFakeRunnerTool(root: URL) throws -> URL {
  let tool = root.appendingPathComponent("fake-runner-tool.py")
  let source = #"""
#!/usr/bin/python3
import base64, hashlib, json, os, pathlib, plistlib, shutil, stat, sys

TARGET = "ConvergenceKitSecretSyncConformanceTests"
PREFIX = "MOOT_SECRET_SYNC_"
PROBE_KEYS = {
    PREFIX + "LIVE_PROOF", PREFIX + "RUN_NAMESPACE",
    PREFIX + "DEVICE_ROLE", PREFIX + "SIGNED_RUN_MANIFEST",
}
ORDINARY_KEYS = PROBE_KEYS | {
    PREFIX + "PHASE", PREFIX + "OPERATOR_ATTESTATION",
    PREFIX + "HOST_LAUNCH_GRANT",
}
CLEANUP_KEYS = ORDINARY_KEYS | {
    PREFIX + "CLEANUP_AUTHORIZATION", PREFIX + "STAGE_INVENTORY",
    PREFIX + "STAGE_RECEIPT",
}

if sys.argv[1:] == ["--u7-self-test-attest"]:
    print("U7_FAKE_XCODEBUILD_V1")
    sys.exit(0)

def framed(domain, fields):
    value = domain.encode()
    for field in fields:
        value += len(field).to_bytes(8, "big") + field
    return hashlib.sha256(value).digest()

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def arg(name):
    return pathlib.Path(sys.argv[sys.argv.index(name) + 1])

def append_log(value):
    with open(log_path, "a") as log:
        log.write(value + "\n")

def write_plist(value, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_BINARY, sort_keys=True)

def make_products(derived, platform, authority, mode):
    products = derived / "Build" / "Products"
    shutil.rmtree(products, ignore_errors=True)
    products.mkdir(parents=True)
    if mode == "zero-xctestrun":
        return
    supported = platform
    if mode == "wrong-platform":
        supported = "iPhoneOS" if platform == "MacOSX" else "MacOSX"
    if mode == "simulator-platform" and platform == "iPhoneOS":
        supported = "iPhoneSimulator"
    configuration = "Debug" if platform == "MacOSX" else "Debug-iphoneos"
    bundle = products / configuration / (TARGET + ".xctest")
    info = {
        "CFBundleSupportedPlatforms": [supported],
        "DTPlatformName": {
            "MacOSX": "macosx", "iPhoneOS": "iphoneos",
            "iPhoneSimulator": "iphonesimulator",
        }[supported],
    }
    if mode != "missing-anchor":
        info["MOOTSecretSyncHostAuthorityPublicKey"] = (
            "WRONG-ANCHOR" if mode == "wrong-anchor" else authority
        )
    info_path = bundle / "Contents" / "Info.plist" if platform == "MacOSX" else bundle / "Info.plist"
    write_plist(info, info_path)
    target = {
        "BlueprintName": "WrongTarget" if mode == "missing-target" else TARGET,
        "TestBundlePath": "__TESTROOT__/" + str(bundle.relative_to(products)),
        "EnvironmentVariables": {
            "XCODE_GENERATED": "preserved",
            PREFIX + "STALE_CANONICAL": "removed",
        },
    }
    targets = [target]
    if mode == "duplicate-target":
        targets.append(dict(target))
    document = {
        "__xctestrun_metadata__": {"FormatVersion": 2},
        "TestConfigurations": [{"Name": "Test Scheme Action", "TestTargets": targets}],
    }
    source = products / ("ConvergenceKit-Package-" + platform + ".xctestrun")
    write_plist(document, source)
    if mode == "duplicate-xctestrun":
        write_plist(document, products / ("Duplicate-" + platform + ".xctestrun"))

if sys.argv[1:3] == ["export", "attachments"]:
    source = arg("--path")
    output = arg("--output-path")
    output.mkdir(parents=True, exist_ok=True)
    for candidate in source.rglob("*.json"):
        shutil.copy2(candidate, output / candidate.name)
    sys.exit(0)

log_path = pathlib.Path(os.environ["U7_FAKE_LOG"])
matrix_path = log_path.with_suffix(".matrix")
mode = os.environ.get("U7_FAKE_MODE", "success")

if any(key.startswith(PREFIX) for key in os.environ):
    sys.exit(40)
if any(flag in sys.argv for flag in ("-project", "-workspace")):
    sys.exit(41)

if "build-for-testing" in sys.argv:
    if pathlib.Path.cwd().resolve() != pathlib.Path(os.environ["U7_PACKAGE_DIR"]).resolve():
        sys.exit(42)
    if "-scheme" not in sys.argv or sys.argv[sys.argv.index("-scheme") + 1] != "ConvergenceKit-Package":
        sys.exit(43)
    derived = arg("-derivedDataPath")
    destination = sys.argv[sys.argv.index("-destination") + 1]
    authority_argument = next(
        (value for value in sys.argv if value.startswith(
            "INFOPLIST_KEY_MOOTSecretSyncHostAuthorityPublicKey="
        )), None
    )
    if authority_argument is None:
        sys.exit(44)
    authority = authority_argument.split("=", 1)[1]
    fixture_mode = mode if mode in {
        "zero-xctestrun", "duplicate-xctestrun", "missing-target",
        "duplicate-target", "missing-anchor", "wrong-anchor",
        "wrong-platform", "simulator-platform",
    } else "success"
    if mode.startswith("ios-"):
        fixture_mode = mode[4:] if destination == os.environ["U7_DEST_B"] else "success"
    if destination == os.environ["U7_DEST_A"]:
        matrix_path.write_text("mac\n")
        make_products(derived, "MacOSX", authority, fixture_mode)
        append_log("build:mac:scheme=ConvergenceKit-Package:cwd=package")
    elif destination == os.environ["U7_DEST_B"]:
        if not matrix_path.exists() or matrix_path.read_text() != "mac\n":
            sys.exit(11)
        with open(matrix_path, "a") as matrix:
            matrix.write("iOS\n")
        make_products(derived, "iPhoneOS", authority, fixture_mode)
        append_log("build:iOS:scheme=ConvergenceKit-Package:cwd=package")
    else:
        sys.exit(12)
    sys.exit(0)

if not matrix_path.exists() or matrix_path.read_text() != "mac\niOS\n":
    sys.exit(13)
if "test-without-building" not in sys.argv or "-xctestrun" not in sys.argv:
    sys.exit(45)
if "-scheme" in sys.argv:
    sys.exit(46)

xctestrun = arg("-xctestrun")
if xctestrun.name.startswith("ConvergenceKit-Package-"):
    sys.exit(47)
file_mode = stat.S_IMODE(os.lstat(xctestrun).st_mode)
if file_mode != 0o600 or xctestrun.is_symlink():
    sys.exit(48)
with open(xctestrun, "rb") as handle:
    document = plistlib.load(handle)
targets = [
    target
    for configuration in document.get("TestConfigurations", [])
    for target in configuration.get("TestTargets", [])
    if target.get("BlueprintName") == TARGET
]
if len(targets) != 1:
    sys.exit(49)
environment = targets[0].get("EnvironmentVariables", {})
if environment.get("XCODE_GENERATED") != "preserved":
    sys.exit(50)
moot_environment = {key: value for key, value in environment.items() if key.startswith(PREFIX)}
test_filter = next(value for value in sys.argv if value.startswith("-only-testing:"))
expected_keys = PROBE_KEYS if test_filter.endswith("/ledgerProbe") else (
    CLEANUP_KEYS if moot_environment.get(PREFIX + "PHASE") == "cleanup" else ORDINARY_KEYS
)
if mode == "missing-environment":
    moot_environment.pop(PREFIX + "LIVE_PROOF", None)
if mode == "extra-environment":
    moot_environment[PREFIX + "UNKNOWN"] = "forbidden"
if mode == "authority-environment":
    moot_environment[PREFIX + "HOST_AUTHORITY_PUBLIC_KEY"] = "forbidden"
if mode == "cleanup-missing-authorization" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment.pop(PREFIX + "CLEANUP_AUTHORIZATION", None)
if mode == "cleanup-missing-inventory" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment.pop(PREFIX + "STAGE_INVENTORY", None)
if mode == "cleanup-missing-receipt" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment.pop(PREFIX + "STAGE_RECEIPT", None)
if mode == "ordinary-cleanup-key" and moot_environment.get(PREFIX + "PHASE") != "cleanup":
    moot_environment[PREFIX + "STAGE_RECEIPT"] = "forbidden"
if mode == "cleanup-extra-environment" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment[PREFIX + "CLEANUP_UNKNOWN"] = "forbidden"
if mode == "cleanup-wrong-inventory" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment[PREFIX + "STAGE_INVENTORY"] = "wrong"
if mode == "cleanup-wrong-receipt" and moot_environment.get(PREFIX + "PHASE") == "cleanup":
    moot_environment[PREFIX + "STAGE_RECEIPT"] = "wrong"
if set(moot_environment) != expected_keys:
    sys.exit(51)
if moot_environment.get(PREFIX + "PHASE") == "cleanup":
    inventory_path = log_path.with_suffix(".stage-inventory")
    receipt_path = log_path.with_suffix(".stage-receipt")
    if (not inventory_path.exists() or not receipt_path.exists()
            or moot_environment[PREFIX + "STAGE_INVENTORY"] != inventory_path.read_text()
            or moot_environment[PREFIX + "STAGE_RECEIPT"] != receipt_path.read_text()):
        sys.exit(54)

copies_path = log_path.with_suffix(".copies")
used = set(copies_path.read_text().splitlines()) if copies_path.exists() else set()
resolved_copy = str(xctestrun.resolve())
if resolved_copy in used:
    sys.exit(52)
with open(copies_path, "a") as copies:
    copies.write(resolved_copy + "\n")

bundle = pathlib.Path(str(targets[0]["TestBundlePath"]).replace(
    "__TESTROOT__", str(xctestrun.parent), 1
)).resolve()
info_path = bundle / "Contents" / "Info.plist" if (bundle / "Contents").exists() else bundle / "Info.plist"
with open(info_path, "rb") as handle:
    platform = plistlib.load(handle)["CFBundleSupportedPlatforms"][0]
role = moot_environment[PREFIX + "DEVICE_ROLE"]
if (role == "A") != (platform == "MacOSX") or (role != "A" and platform != "iPhoneOS"):
    sys.exit(53)

result = arg("-resultBundlePath")
attachments = result / "Attachments"
attachments.mkdir(parents=True, exist_ok=True)
if mode == "nonzero-probe" and test_filter.endswith("/ledgerProbe"):
    sys.exit(9)
if mode == "nonzero-phase" and test_filter.endswith("/externalPhase"):
    sys.exit(9)

namespace = moot_environment[PREFIX + "RUN_NAMESPACE"]
if test_filter.endswith("/ledgerProbe"):
    manifest = json.loads(base64.b64decode(
        moot_environment[PREFIX + "SIGNED_RUN_MANIFEST"]
    ))["manifest"]
    probe = {
        "version": 1,
        "namespace": "u7-ffffffff-ffff-ffff-ffff-ffffffffffff"
            if mode == "mismatch-probe" else namespace,
        "ledgerIdentifier": manifest["ledgerIdentifier"],
        "role": role,
        "contentDigest": base64.b64encode(bytes([ord(role)]) * 32).decode(),
    }
    (attachments / "u7-ledger-probe-v1.json").write_bytes(canonical(probe))
    append_log("probe:" + role + ":platform=" + platform + ":private-xctestrun")
    sys.exit(0)

phase = moot_environment[PREFIX + "PHASE"]
grant = json.loads(base64.b64decode(moot_environment[PREFIX + "HOST_LAUNCH_GRANT"]))
manifest = grant["manifest"]
dependency_labels = {
    ("backgroundDenied", "A"): ["credentialA"],
    ("stage", "A"): ["backgroundDeniedA"],
    ("conditionalHead", "A"): ["stageA"],
    ("conditionalHead", "B"): ["stageA"],
    ("recovery", "A"): ["offlineA"],
    ("rotation", "A"): ["recoveryA"],
    ("restart", "A"): ["rotationA"],
    ("audit", "A"): ["restartA"],
    ("cleanup", "A"): ["auditA", "cleanupB", "cleanupC"],
}
expected_prerequisites = [
    base64.b64encode(hashlib.sha256(label.encode()).digest()).decode()
    for label in dependency_labels.get((phase, role), [])
]
if manifest["prerequisiteArtifactDigests"] != expected_prerequisites:
    sys.exit(10)
authority = base64.b64decode(
    (pathlib.Path(os.environ["U7_RUN_DIR"]) / "authority-public.b64").read_text()
)
grant_digest = framed(
    "mootx01.u7.host-launch-grant.v2",
    [authority, canonical(manifest), base64.b64decode(grant["signature"])],
)
inventory_digest = None
if phase == "stage":
    inventory = {
        "version": 1, "namespace": namespace, "role": "A",
        "runManifestDigest": manifest["runManifestDigest"],
        "launchGrantDigest": base64.b64encode(grant_digest).decode(),
        "destinationBindingDigest": manifest["destinationBindingDigest"],
        "records": [{"recordName": "1" * 64, "zoneName": "moot-secret-payload-v1"}],
    }
    inventory_bytes = canonical(inventory)
    inventory_digest = framed("mootx01.u7.stage-inventory.v1", [inventory_bytes])
    (attachments / "u7-stage-inventory-v1.json").write_bytes(inventory_bytes)
if mode in ("skip-phase", "missing-receipt"):
    sys.exit(0)
receipt = {
    "version": 1, "namespace": namespace,
    "role": "B" if mode == "wrong-receipt" and role != "B" else role,
    "phase": phase, "runManifestDigest": manifest["runManifestDigest"],
    "launchGrantDigest": base64.b64encode(
        bytes(32) if mode == "stale-receipt" else grant_digest
    ).decode(),
    "destinationBindingDigest": manifest["destinationBindingDigest"],
    "artifactDigest": base64.b64encode(hashlib.sha256((phase + role).encode()).digest()).decode(),
    "inventoryDigest": base64.b64encode(
        bytes(32) if mode == "mismatch-receipt" else inventory_digest
    ).decode() if inventory_digest is not None else None,
    "credentialBindingDigest": base64.b64encode(
        hashlib.sha256(("credential-" + role).encode()).digest()
    ).decode() if phase == "credential" else None,
}
receipt_bytes = canonical(receipt)
(attachments / "u7-phase-receipt-v1.json").write_bytes(receipt_bytes)
if phase == "stage":
    log_path.with_suffix(".stage-inventory").write_text(
        base64.b64encode(inventory_bytes).decode()
    )
    log_path.with_suffix(".stage-receipt").write_text(
        base64.b64encode(receipt_bytes).decode()
    )
append_log(
    "phase:" + phase + ":" + role + ":platform=" + platform
    + ":private-xctestrun:prerequisites="
    + ",".join(manifest["prerequisiteArtifactDigests"])
)
sys.exit(0)
"""#
  try Data(source.utf8).write(to: tool)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: tool.path
  )
  return tool
}

private func u7RunnerEnvironment(
  root: URL, host: URL, fake: URL,
  additions: [String: String] = [:]
) -> [String: String] {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let base = [
    "U7_RUN_DIR": root.appendingPathComponent("private").path,
    "U7_RUN_NAMESPACE": "u7-00112233-4455-6677-8899-aabbccddeeff",
    "U7_HOST_TOOL": host.path, "U7_XCODEBUILD": fake.path,
    "U7_XCRESULTTOOL": fake.path, "U7_PACKAGE_DIR": packageRoot.path,
    "U7_DEST_A": "A-RAW-CANARY",
    "U7_DEST_B": "B-RAW-CANARY", "U7_DEST_C": "C-RAW-CANARY",
    "U7_FAKE_LOG": root.appendingPathComponent("fake.log").path,
  ]
  return base.merging(additions, uniquingKeysWith: { _, replacement in replacement })
}

@Suite(
  "SecretSync authorized external-device private-CloudKit proof",
  .serialized,
  .enabled(
    if: SecretSyncLiveCloudKitProofConfiguration.isExplicitlyRequested,
    "Requires an explicitly authorized external A/B/C role and phase"
  )
)
struct SecretSyncLiveCloudKitProofTests {
  @Test("one role emits a manifest-authenticated non-protected ledger probe")
  func ledgerProbe() async throws {
    let values = try SecretSyncLiveCloudKitProofConfiguration.loadProbe()
    let ledger = try SecretSyncLiveCleanupLedger(
      url: values.ledgerURL, namespace: values.runNamespace,
      logicalLedgerIdentifier: values.signedRunManifest.manifest.ledgerIdentifier,
      role: values.deviceRole,
      signedRunManifestDigest: values.runManifestDigest
    )
    let attachment = try SecretSyncLiveExactJSON.encode(
      await ledger.probeAttachment()
    )
    Attachment.record(
      attachment, named: SecretSyncLiveLedgerProbeAttachment.filename
    )
  }

  @Test("one external role executes exactly one fail-closed proof phase")
  func externalPhase() async throws {
    let values = try requiredConfiguration()
    let ledger = try SecretSyncLiveCleanupLedger(
      url: values.ledgerURL, namespace: values.runNamespace,
      logicalLedgerIdentifier: values.signedRunManifest.manifest.ledgerIdentifier,
      role: values.deviceRole,
      signedRunManifestDigest: values.runManifestDigest
    )
    if values.phase == .cleanup {
      try await authorizeCleanupBeforeAdmission(values, ledger: ledger)
    }
    try await ledger.admitLaunchGrant(values: values)
    if try await SecretSyncLiveCleanupEntryPoint.requiresInitialZoneAdmission(
      values: values, ledger: ledger
    ) {
      try await requirePreexistingZones(values)
    }
    switch values.phase {
    case .credential: try await proveHardwareCustody(values, ledger: ledger)
    case .backgroundDenied: try await proveBackgroundDenial(values, ledger: ledger)
    case .stage: try await stageCompleteGraph(values, ledger: ledger)
    case .conditionalHead: try await conditionallyAdvance(values, ledger: ledger)
    case .verify: try await verifyCommittedGraph(values, ledger: ledger)
    case .offline: try await verifyOfflineFloor(values, ledger: ledger)
    case .revoke: try await recordRevokedC(values, ledger: ledger)
    case .recovery: try await verifyRecoveryBinding(values, ledger: ledger)
    case .rotation: try await verifyRecoveryRotation(values, ledger: ledger)
    case .restart: try await verifyRestart(values, ledger: ledger)
    case .audit: try await audit(values, ledger: ledger)
    case .cleanup: try await cleanup(values, ledger: ledger)
    }
    try await recordPhaseEvidence(values, ledger: ledger)
  }

  /// Cleanup is admitted only after the device independently verifies the
  /// signed stage receipt, exact stage inventory, and full cleanup capability.
  private func authorizeCleanupBeforeAdmission(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let inventoryText = environment[
      SecretSyncLiveCloudKitProofConfiguration.stageInventoryKey
    ], let inventoryData = Data(base64Encoded: inventoryText),
      let receiptText = environment[
        SecretSyncLiveCloudKitProofConfiguration.stageReceiptKey
      ], let receiptData = Data(base64Encoded: receiptText),
      let authorization = values.cleanupAuthorization
    else { throw SecretSyncLiveCloudKitProofConfigurationError.attachmentMalformed }
    let inventory = try SecretSyncLiveStageInventoryAttachment.decodeExact(inventoryData)
    let receipt = try SecretSyncLivePhaseReceiptAttachment.decodeExact(receiptData)
      .validated(values: values, expectedRole: .a, expectedPhase: .stage)
    guard inventory.version == 1, inventory.namespace == values.runNamespace,
      inventory.role == .a, inventory.runManifestDigest == values.runManifestDigest,
      inventory.launchGrantDigest == receipt.launchGrantDigest,
      inventory.destinationBindingDigest == receipt.destinationBindingDigest,
      receipt.inventoryDigest == (try inventory.canonicalDigest())
    else { throw SecretSyncLiveCloudKitProofConfigurationError.attachmentBindingMismatch }
    _ = try await ledger.authorizeCleanup(
      authorization, inventory: inventory,
      signedRunManifest: values.signedRunManifest,
      trustedAuthorityPublicKey: values.trustedHostAuthorityPublicKey,
      deterministicHeadRecordName: try deterministicHeadRecordName(values),
      now: Date()
    )
  }

  /// Receipts are XCTest attachments so the host must extract and validate
  /// result-bundle evidence before it advances its durable protocol state.
  private func recordPhaseEvidence(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let artifactDigest: Data
    if values.phase == .cleanup, values.deviceRole == .a {
      // Cleanup A deletes the signed proof set, so its terminal receipt binds
      // the authenticated local deletion checkpoint. A CloudKit cleanup-A
      // marker is intentionally absent; only B and C publish markers.
      artifactDigest = try await ledger.currentContentDigest()
    } else {
      let kind = "phase-\(values.phase.rawValue)"
      artifactDigest = try await loadArtifact(
        SecretSyncLiveSignedArtifactEnvelope.self, kind: kind,
        role: values.deviceRole, values: values
      ).artifactDigest()
    }
    var inventory: SecretSyncLiveStageInventoryAttachment?
    if values.phase == .stage {
      let deterministicNames = Set(
        values.signedRunManifest.manifest.artifactRecordNames
      )
      let deterministicHead = try deterministicHeadRecordName(values)
      let records = try await ledger.exactRecordIDs().compactMap { recordID in
        guard !deterministicNames.contains(recordID.recordName),
          recordID.recordName != deterministicHead
        else { return nil }
        return SecretSyncLiveRecordReference(
          recordName: recordID.recordName, zoneName: recordID.zoneID.zoneName
        )
      }.sorted(by: SecretSyncLiveCleanupAuthorizationVerifier.recordOrder)
      guard !records.isEmpty else {
        throw SecretSyncLiveCloudKitProofConfigurationError.attachmentBindingMismatch
      }
      inventory = SecretSyncLiveStageInventoryAttachment(
        version: 1, namespace: values.runNamespace, role: values.deviceRole,
        runManifestDigest: values.runManifestDigest,
        launchGrantDigest: values.launchGrantDigest,
        destinationBindingDigest: values.launchGrant.manifest.destinationBindingDigest,
        records: records
      )
      Attachment.record(
        try SecretSyncLiveExactJSON.encode(inventory!),
        named: SecretSyncLiveStageInventoryAttachment.filename
      )
    }
    let receipt = SecretSyncLivePhaseReceiptAttachment(
      version: 1, namespace: values.runNamespace, role: values.deviceRole,
      phase: values.phase, runManifestDigest: values.runManifestDigest,
      launchGrantDigest: values.launchGrantDigest,
      destinationBindingDigest: values.launchGrant.manifest.destinationBindingDigest,
      artifactDigest: artifactDigest,
      inventoryDigest: try inventory?.canonicalDigest(),
      credentialBindingDigest: values.phase == .credential
        ? SecretSyncLiveCredentialBinding.digest(
          try await loadArtifact(
            SecretSyncLiveCredentialEvidence.self, kind: "credential",
            role: values.deviceRole, values: values
          ).credential
        ) : nil
    )
    Attachment.record(
      try SecretSyncLiveExactJSON.encode(receipt),
      named: SecretSyncLivePhaseReceiptAttachment.filename
    )
  }

  private func deterministicHeadRecordName(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> String {
    try SecretSyncHeadCAS.recordID(for: scopeID(values)).recordName
  }

  private func proveHardwareCustody(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    guard SecretSyncSecureEnclaveCustody.hardwareAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }
    let custody = SecretSyncSecureEnclaveCustody()
    if let resumed = try await resumeCredentialPublication(
      values, ledger: ledger, custody: custody
    ) {
      try await finalizeCredentialEvidence(
        resumed, values: values, ledger: ledger
      )
      return
    }
    if values.deviceRole == .a {
      try await provisionAgreementVerifiers(values, ledger: ledger)
    }
    let verifier = try await loadArtifact(
      SecretSyncLiveAgreementVerifierPublic.self, kind: "agreement-verifier",
      role: values.deviceRole, values: values
    )
    let generation = try await custody.createCredential(
      for: TrustedDeviceID(UUID()),
      checkpointBeforePersistence: { generation in
        try await ledger.checkpointProvisionalCredential(
          generation, role: values.deviceRole
        )
      }
    )
    let candidateEvidence = try await verifyHardwareProof(
      custody: custody, generation: generation,
      agreementVerifierPublicKey: verifier.publicKey, values: values
    )
    let evidence = try await SecretSyncLiveCredentialPublicationBoundary.run(
      generation: generation, role: values.deviceRole, ledger: ledger,
      removeBothHandles: { credentialID in
        try await custody.removeCredentialForPhysicalProof(credentialID)
      },
      clearCheckpoint: {
        try await ledger.clearCredentialCheckpoint(role: values.deviceRole)
      },
      publish: {
        try await saveArtifact(
          candidateEvidence, kind: "credential", role: values.deviceRole,
          values: values, ledger: ledger
        )
        return candidateEvidence
      },
      reconcilePublication: {
        try await reconcileExactArtifact(
          candidateEvidence, kind: "credential", role: values.deviceRole,
          values: values
        )
      }
    )
    try await finalizeCredentialEvidence(
      evidence, values: values, ledger: ledger
    )
  }

  private func resumeCredentialPublication(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger,
    custody: SecretSyncSecureEnclaveCustody
  ) async throws -> SecretSyncLiveCredentialEvidence? {
    guard let checkpoint = try await ledger.credentialCheckpoint(
      role: values.deviceRole
    ) else { return nil }
    let recordID = try artifactRecordID(
      kind: "credential", role: values.deviceRole, values: values
    )
    let results = try await CKContainer(identifier: values.containerIdentifier)
      .privateCloudDatabase.fetch(withRecordIDs: [recordID])
    switch results[recordID] {
    case .success(let record):
      guard record["namespace"] as? String == values.runNamespace,
        record["kind"] as? String == "credential",
        record["role"] as? String == values.deviceRole.rawValue,
        let payload = record["payload"] as? Data,
        let evidence = try? JSONDecoder().decode(
          SecretSyncLiveCredentialEvidence.self, from: payload
        ),
        evidence.launchGrantDigest == values.launchGrantDigest,
        evidence.credential.deviceID == checkpoint.deviceID,
        evidence.credential.credentialID == checkpoint.credentialID,
        evidence.credential.signingPublicKey == checkpoint.signingPublicKey,
        evidence.credential.keyAgreementPublicKey
          == checkpoint.agreementPublicKey,
        try SecretSyncLiveAttestation.verify(
          evidence,
          namespace: values.runNamespace,
          role: values.deviceRole,
          expectedLaunchGrantDigest: values.launchGrantDigest,
          credentialRecordName: recordID.recordName,
          verifierRecordName: try artifactRecordID(
            kind: "agreement-verifier", role: values.deviceRole, values: values
          ).recordName,
          agreementVerifierPrivateKey: try await ledger
            .agreementVerifierPrivateKey(role: values.deviceRole)
        )
      else {
        // An existing but non-identical artifact is never rollback authority.
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      if !checkpoint.published {
        try await ledger.markCredentialPublished(role: values.deviceRole)
      }
      return evidence
    case .failure(let error):
      guard (error as? CKError)?.code == .unknownItem else { throw error }
      guard !checkpoint.published else {
        // A durable published marker plus remote absence is inconsistent; keep
        // the checkpoint and handles for operator-visible retry/inspection.
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      try await SecretSyncLiveCredentialPublicationBoundary
        .removeInterruptedProvisional(
          role: values.deviceRole,
          ledger: ledger,
          removeBothHandles: { credentialID in
            try await custody.removeCredentialForPhysicalProof(credentialID)
          }
        )
      return nil
    case nil:
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
  }

  private func finalizeCredentialEvidence(
    _ evidence: SecretSyncLiveCredentialEvidence,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.admitDevice(
      role: values.deviceRole, evidenceID: evidence.evidenceID
    )
    try await ledger.storeCredentialForCleanup(
      evidence.credential, role: values.deviceRole
    )
    try await complete(.hardwareCustody, values: values, ledger: ledger)
  }

  private func verifyHardwareProof(
    custody: SecretSyncSecureEnclaveCustody,
    generation: SecretSyncCustodyCredentialGeneration,
    agreementVerifierPublicKey: Data,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) async throws -> SecretSyncLiveCredentialEvidence {
    let transcript = try possessionTranscript(generation, values: values)
    let signingChallenge = try SecretSyncSigningProofChallenge(transcript: transcript)
    let agreementChallenge = try SecretSyncLiveAttestation.agreementChallenge(
      transcript: transcript, verifierPublicKey: agreementVerifierPublicKey
    )
    let signing = try await custody.proveSigningKeyPossession(
      SigningProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.signingHandle,
        challengeID: transcript.challengeID,
        challengeBytes: signingChallenge.canonicalBytes
      )
    )
    let agreementProof = try await custody.proveKeyAgreementKeyPossession(
      KeyAgreementProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.agreementHandle,
        challengeID: transcript.challengeID,
        challengeBytes: agreementChallenge
      )
    )
    guard
      try signingChallenge.verify(
        signing.proofBytes,
        publicKey: generation.signingPublicKey
      )
    else { throw SecretSyncCustodyError.invalidProof }
    let status: TrustedDeviceCredentialStatus = values.deviceRole == .c ? .revoked : .active
    let credential = try TrustedDeviceCredential(
      deviceID: generation.deviceID, credentialID: generation.credentialID,
      credentialVersion: 1, status: status,
      signingPublicKey: generation.signingPublicKey,
      keyAgreementPublicKey: generation.agreementPublicKey,
      enrollmentProof: DeviceCredentialEnrollmentProof(
        challengeID: transcript.challengeID,
        challengeBytes: signingChallenge.canonicalBytes,
        signingProofBytes: signing.proofBytes,
        keyAgreementProofBytes: agreementProof.proofBytes,
        provenance: .globalRecovery(
          GlobalRecoveryEnrollmentAuthority(
            requestID: transcript.sessionID,
            recoveryRecipientID: scopeID(values).rawValue
          )
        )
      )
    )
    let credentialRecordName = try artifactRecordID(
      kind: "credential", role: values.deviceRole, values: values
    ).recordName
    let verifierRecordName = try artifactRecordID(
      kind: "agreement-verifier", role: values.deviceRole, values: values
    ).recordName
    let transcriptValue = SecretSyncLiveAttestation.transcriptValue(transcript)
    let body = try SecretSyncLiveAttestation.canonicalBody(
      namespace: values.runNamespace, role: values.deviceRole,
      launchGrantDigest: values.launchGrantDigest,
      credentialRecordName: credentialRecordName,
      verifierRecordName: verifierRecordName, credential: credential,
      transcript: transcriptValue,
      signingChallenge: signingChallenge.canonicalBytes,
      signingProof: signing.proofBytes,
      agreementChallenge: agreementChallenge,
      agreementProof: agreementProof.proofBytes
    )
    let bodyDigest = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
      .digest(canonicalBytes: body)
    let attestationTranscript = try possessionTranscript(
      generation, values: values, boundDigest: bodyDigest
    )
    let attestationChallenge = try SecretSyncSigningProofChallenge(
      transcript: attestationTranscript
    )
    let attestationProof = try await custody.proveSigningKeyPossession(
      SigningProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.signingHandle,
        challengeID: attestationTranscript.challengeID,
        challengeBytes: attestationChallenge.canonicalBytes
      )
    )
    guard try attestationChallenge.verify(
      attestationProof.proofBytes, publicKey: generation.signingPublicKey
    ) else { throw SecretSyncCustodyError.invalidProof }
    return SecretSyncLiveCredentialEvidence(
      launchGrantDigest: values.launchGrantDigest,
      credential: credential,
      possessionTranscript: transcriptValue,
      signingChallenge: signingChallenge.canonicalBytes,
      signingProof: signing.proofBytes,
      agreementChallenge: agreementChallenge,
      agreementProof: agreementProof.proofBytes,
      attestationTranscript: SecretSyncLiveAttestation.transcriptValue(
        attestationTranscript
      ),
      attestationChallenge: attestationChallenge.canonicalBytes,
      attestationProof: attestationProof.proofBytes,
      evidenceID: SecretSyncLiveAttestation.evidenceID(
        body: body, challenge: attestationChallenge.canonicalBytes,
        proof: attestationProof.proofBytes
      )
    )
  }

  private func stageCompleteGraph(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(
      .backgroundDenied, role: .a, values: values, ledger: ledger
    )
    let physical = try await SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases
      .asyncMap { role in
        try await loadArtifact(
          SecretSyncLiveCredentialEvidence.self, kind: "credential", role: role,
          values: values
        ).credential
      }
    let context = try liveStore(values, ledger: ledger)
    for role in [SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a, .b] {
      let fixture = try U7PolicyFixture.makeLive(
        scopeID: scopeID(values), physicalCredentials: physical
      )
      try await context.store.appendStagedPolicy(fixture.entry)
      let rebuilt = try await context.store.reconstructPolicy(
        commitDigest: fixture.entry.commit.recordDigest
      )
      guard rebuilt == fixture.entry else {
        throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
      }
      try await saveArtifact(
        SecretSyncLiveCandidateReference(
          commitDigest: fixture.entry.commit.recordDigest.bytes,
          predecessorDigest: fixture.entry.commit.predecessorCommitDigest?.bytes
        ),
        kind: "candidate", role: role, values: values, ledger: ledger
      )
    }
    let manifest = try await ledger.exactRecordIDs().map {
      SecretSyncLiveRecordReference(
        recordName: $0.recordName, zoneName: $0.zoneID.zoneName
      )
    }
    try await saveArtifact(
      manifest, kind: "manifest", role: .a, values: values, ledger: ledger
    )
    try await complete(.immutableStage, values: values, ledger: ledger)
  }

  private func proveBackgroundDenial(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.credential, role: .a, values: values, ledger: ledger)
    let custody = SecretSyncSecureEnclaveCustody()
    do {
      _ = try await custody.beginForegroundHydrationSession()
      throw SecretSyncLiveCloudKitProofConfigurationError.backgroundAuthorizationGranted
    } catch SecretSyncCustodyError.backgroundOperationDenied {
      try await complete(.deny, values: values, ledger: ledger)
    }
  }

  private func conditionallyAdvance(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.stage, role: .a, values: values, ledger: ledger)
    let context = try liveStore(values, ledger: ledger)
    let candidate = try await loadArtifact(
      SecretSyncLiveCandidateReference.self, kind: "candidate",
      role: values.deviceRole, values: values
    )
    let digest = try SecretRecordDigest(bytes: candidate.commitDigest)
    let entry = try await context.store.reconstructPolicy(commitDigest: digest)
    let freshness = try commitment(entry.commit)
    let snapshot = try SecretPolicyValidator.validateTransition(
      currentSnapshot: nil, stagedRecords: entry.records, commit: entry.commit,
      trustedCredentials: entry.credentials, trustedDeviceRecords: entry.trustRecords,
      knownCompetingChildDigests: [], externalFreshness: freshness,
      digester: context.digester,
      signatureVerifier: SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    )
    let precondition = try SecretPolicyAdvancePrecondition(
      expectedHead: nil, candidateEntry: entry, validatedSnapshot: snapshot
    )
    let result = try await context.store.compareAndAdvance(precondition)
    let proof: SecretSyncLiveCASResult
    let relation: SecretSyncLiveEvidence.HeadRelation
    switch result {
    case .advanced(let head):
      proof = SecretSyncLiveCASResult(
        role: values.deviceRole, outcome: .advanced,
        candidateDigest: digest.bytes,
        expectedPredecessorDigest: candidate.predecessorDigest,
        serverHeadDigest: head.commitDigest.bytes
      )
      relation = .exact
    case .forkDetected(let current, _):
      proof = SecretSyncLiveCASResult(
        role: values.deviceRole, outcome: .forkDetected,
        candidateDigest: digest.bytes,
        expectedPredecessorDigest: candidate.predecessorDigest,
        serverHeadDigest: current.commitDigest.bytes
      )
      relation = .fork
    }
    try await saveArtifact(
      proof, kind: "cas", role: values.deviceRole, values: values, ledger: ledger
    )
    try await complete(
      .conditionalHead, relation: relation, values: values, ledger: ledger
    )
  }

  private func verifyCommittedGraph(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    _ = try await loadArtifact(
      SecretSyncLiveCASResult.self, kind: "cas", role: .a, values: values
    )
    _ = try await loadArtifact(
      SecretSyncLiveCASResult.self, kind: "cas", role: .b, values: values
    )
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    let rebuilt = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    guard rebuilt.commit.recordDigest == head.commitDigest else {
      throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
    }
    let credential = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: values.deviceRole, values: values
    )
    let localCheckpoint = try #require(
      try await ledger.credentialCheckpoint(role: values.deviceRole)
    )
    let bound = try SecretSyncV1BoundContext(
      scopeID: rebuilt.commit.scopeID,
      scopeSnapshotDigest: rebuilt.commit.scopeSnapshotDigest,
      policyEpoch: rebuilt.commit.policyEpoch,
      policyDigest: rebuilt.commit.policyDigest,
      generationID: rebuilt.commit.generationID, formatVersion: 1
    )
    let custody = SecretSyncSecureEnclaveCustody()
    if values.deviceRole == .c {
      let envelope = try #require(rebuilt.records.recipientEnvelopes.first)
      await #expect(throws: SecretSyncCustodyError.invalidProof) {
        _ = try await custody.openRecipientGenerationKey(
          envelope.wrappedKeyBytes,
          privateKeyHandle: localCheckpoint.agreementHandle,
          credentialID: credential.credential.credentialID,
          context: SecretSyncRecipientEnvelopeContext(
            boundContext: bound,
            recipientCredentialID: envelope.recipientCredentialID
          ),
          session: try await custody.beginForegroundHydrationSession()
        )
      }
      try await complete(.deny, values: values, ledger: ledger)
      return
    }
    let envelope = try #require(
      rebuilt.records.recipientEnvelopes.first {
        $0.recipientCredentialID == credential.credential.credentialID
      }
    )
    let opened = try await custody.openRecipientGenerationKey(
      envelope.wrappedKeyBytes,
      privateKeyHandle: localCheckpoint.agreementHandle,
      credentialID: credential.credential.credentialID,
      context: SecretSyncRecipientEnvelopeContext(
        boundContext: bound, recipientCredentialID: credential.credential.credentialID
      ),
      session: try await custody.beginForegroundHydrationSession()
    )
    let plaintext = try SecretSyncAESGCMProvider(suite: U7GoldenVectors.suite()).open(
      sealedBytes: rebuilt.records.sealedPayload.ciphertextBytes,
      using: opened, context: bound
    )
    guard plaintext == Data("u7-production-encrypted-payload".utf8) else {
      throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
    }
    if values.deviceRole == .a {
      try await ledger.storeProtectedCommitment(commitment(rebuilt.commit))
    }
    try await complete(.authorize, values: values, ledger: ledger)
  }

  private func verifyOfflineFloor(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    _ = try await loadArtifact(
      SecretSyncLiveCASResult.self, kind: "cas", role: .a, values: values
    )
    let floor = try await ledger.protectedCommitment()
    let observation = SecretSyncLiveNetworkObservation()
    let database = SecretSyncLiveRecordingDatabase(
      database: CKContainer(identifier: values.containerIdentifier).privateCloudDatabase,
      ledger: ledger, networkObservation: observation
    )
    let returned = try await SecretSyncFreshnessTransport(database: database)
      .normalPathCommitment(
        for: floor.scopeID,
        authority: .protectedLocal(SecretSyncLiveProtectedFloor(commitment: floor))
      )
    guard returned == floor, await observation.observedOfflineTransportFailure() else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    try await complete(
      .offlineTransportFallback,
      productionSeam: "SecretSyncFreshnessTransport.normalPathCommitment.protectedLocal",
      outcomeDigest: Data(SHA256.hash(data: try returned.canonicalBytes())),
      values: values, ledger: ledger
    )
  }

  private func recordRevokedC(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let evidence = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential", role: .c,
      values: values
    )
    guard evidence.credential.status == .revoked else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    try await complete(.deny, values: values, ledger: ledger)
  }

  private func verifyRecoveryBinding(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.offline, role: .a, values: values, ledger: ledger)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    let entry = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    let outcome = try await SecretSyncLiveRecoveryExercise.stageBreakGlass(
      commitment: commitment(entry.commit),
      generationID: entry.commit.generationID
    )
    try await ledger.storeTransitionOutcome(outcome.evidenceBytes, phase: .recovery)
    try await complete(
      .breakGlassCustodyStaged,
      productionSeam: outcome.seam, outcomeDigest: outcome.digest,
      values: values, ledger: ledger
    )
  }

  private func verifyRestart(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.rotation, role: .a, values: values, ledger: ledger)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    _ = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    try await complete(.restart, values: values, ledger: ledger)
  }

  private func verifyRecoveryRotation(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.recovery, role: .a, values: values, ledger: ledger)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    let entry = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    let outcome = try await SecretSyncLiveRecoveryExercise.stageRotation(
      commitment: commitment(entry.commit),
      currentGenerationID: entry.commit.generationID
    )
    try await ledger.storeTransitionOutcome(outcome.evidenceBytes, phase: .rotation)
    try await complete(
      .recoveryRotationCustodyStaged,
      productionSeam: outcome.seam, outcomeDigest: outcome.digest,
      values: values, ledger: ledger
    )
  }

  private func cleanup(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let database = CKContainer(identifier: values.containerIdentifier).privateCloudDatabase
    try await SecretSyncLiveCleanupEntryPoint.run(
      values: values, ledger: ledger, database: database,
      expectedRecordIDs: {
        try proofArtifactIDs(values: values) + [
          SecretSyncHeadCAS.recordID(for: try scopeID(values))
        ]
      },
      verifyAPrerequisites: {
        try await requirePhase(.audit, role: .a, values: values, ledger: ledger)
        try await requirePhase(.cleanup, role: .b, values: values, ledger: ledger)
        try await requirePhase(.cleanup, role: .c, values: values, ledger: ledger)
      },
      removeCredential: { credentialID in
        try await SecretSyncSecureEnclaveCustody().removeCredentialForPhysicalProof(
          credentialID
        )
      },
      publishOrValidateMarker: { marker in
        let envelope = try await signedPhaseEnvelope(
          marker, kind: "phase-cleanup", values: values, ledger: ledger
        )
        try await SecretSyncLiveCleanupMarkerStore.publishOrValidate(
          envelope, values: values, database: database, ledger: ledger
        )
      }
    )
  }

  private func proofArtifactIDs(
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> [CKRecord.ID] {
    var pairs: [(String, SecretSyncLiveCloudKitProofConfiguration.DeviceRole)] = []
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      pairs.append(("agreement-verifier", role))
      pairs.append(("credential", role))
      pairs.append(("phase-credential", role))
      pairs.append(("phase-verify", role))
    }
    pairs += [
      ("phase-backgroundDenied", .a), ("candidate", .a), ("candidate", .b),
      ("manifest", .a), ("phase-stage", .a), ("cas", .a), ("cas", .b),
      ("phase-conditionalHead", .a), ("phase-conditionalHead", .b),
      ("phase-revoke", .c), ("phase-offline", .a), ("phase-recovery", .a),
      ("phase-rotation", .a), ("phase-restart", .a), ("phase-audit", .a),
      ("phase-cleanup", .b), ("phase-cleanup", .c),
    ]
    return try pairs.map {
      try artifactRecordID(kind: $0.0, role: $0.1, values: values)
    }
  }

  private func audit(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.restart, role: .a, values: values, ledger: ledger)
    let cas = try await [SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a, .b]
      .asyncMap {
        try await loadArtifact(
          SecretSyncLiveCASResult.self, kind: "cas", role: $0, values: values
        )
      }
    guard Set(cas.map(\.outcome)) == Set([.advanced, .forkDetected]),
      Set(cas.map(\.expectedPredecessorDigest)).count == 1,
      cas.first(where: { $0.outcome == .advanced })?.candidateDigest
        == cas.first(where: { $0.outcome == .advanced })?.serverHeadDigest,
      cas.first(where: { $0.outcome == .forkDetected })?.serverHeadDigest
        == cas.first(where: { $0.outcome == .advanced })?.serverHeadDigest
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
    var credentialEvidence: [SecretSyncLiveCredentialEvidence] = []
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      let credential = try await loadArtifact(
        SecretSyncLiveCredentialEvidence.self, kind: "credential", role: role,
        values: values
      )
      let verifierPrivateKey = try await ledger.agreementVerifierPrivateKey(
        role: role
      )
      let verifierPublic = try await loadArtifact(
        SecretSyncLiveAgreementVerifierPublic.self,
        kind: "agreement-verifier", role: role, values: values
      )
      guard let trustedCredentialGrantDigest = values.launchGrant.manifest
        .trustedCredentialGrantDigestsByRole[role.rawValue] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      guard try P256.KeyAgreement.PrivateKey(rawRepresentation: verifierPrivateKey)
          .publicKey.x963Representation == verifierPublic.publicKey,
        try SecretSyncLiveAttestation.verify(
          credential, namespace: values.runNamespace, role: role,
          expectedLaunchGrantDigest: trustedCredentialGrantDigest,
          credentialRecordName: try artifactRecordID(
            kind: "credential", role: role, values: values
          ).recordName,
          verifierRecordName: try artifactRecordID(
            kind: "agreement-verifier", role: role, values: values
          ).recordName,
          agreementVerifierPrivateKey: verifierPrivateKey
        )
      else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
      credentialEvidence.append(credential)
      let proof = try await loadPhaseEvidence(
        phase: .verify, role: role,
        values: values, ledger: ledger
      )
      let expected: SecretSyncLiveEvidence.Operation = role == .c ? .deny : .authorize
      guard proof.operation == expected, proof.resultCode == .passed else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
    }
    try SecretSyncLiveCredentialDistinctness.require(credentialEvidence)
    let floor = try await ledger.protectedCommitment()
    let offline = try await loadPhaseEvidence(
      phase: .offline, role: .a,
      values: values, ledger: ledger
    )
    guard offline.operation == .offlineTransportFallback,
      offline.productionSeam
        == "SecretSyncFreshnessTransport.normalPathCommitment.protectedLocal",
      offline.outcomeDigest
        == Data(SHA256.hash(data: try floor.canonicalBytes()))
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
    let recoveryBytes = try await ledger.transitionOutcome(phase: .recovery)
    let recovery = try SecretSyncLiveRecoveryExercise.validateStored(
      recoveryBytes, operation: .breakGlass,
      seam: "SecretSyncRecoveryKeyCustody.stageBreakGlass"
    )
    let recoveryProof = try await loadPhaseEvidence(
      phase: .recovery, role: .a,
      values: values, ledger: ledger
    )
    guard recoveryProof.operation == .breakGlassCustodyStaged,
      recoveryProof.productionSeam == recovery.seam,
      recoveryProof.outcomeDigest == recovery.digest
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
    let rotationBytes = try await ledger.transitionOutcome(phase: .rotation)
    let rotation = try SecretSyncLiveRecoveryExercise.validateStored(
      rotationBytes, operation: .rotation,
      seam: "SecretSyncRecoveryKeyCustody.stageRotation"
    )
    let rotationProof = try await loadPhaseEvidence(
      phase: .rotation, role: .a,
      values: values, ledger: ledger
    )
    guard rotationProof.operation == .recoveryRotationCustodyStaged,
      rotationProof.productionSeam == rotation.seam,
      rotationProof.outcomeDigest == rotation.digest
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
    let kind = "phase-audit"
    let evidence: SecretSyncLiveEvidence
    let envelope: SecretSyncLiveSignedArtifactEnvelope
    if let staged = try await ledger.stagedAuditEnvelope() {
      envelope = staged
      evidence = try JSONDecoder().decode(
        SecretSyncLiveEvidence.self, from: staged.payload
      )
    } else {
      evidence = SecretSyncLiveEvidence(
        timestamp: Date(), deviceRole: .a, operation: .configuration,
        resultCode: .passed, headRelation: .exact,
        productionSeam: nil, outcomeDigest: nil
      )
      envelope = try await signedPhaseEnvelope(
        evidence, kind: kind, values: values, ledger: ledger
      )
    }
    let credentialArtifact = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: .a, values: values
    )
    guard try SecretSyncLiveSignedArtifactVerifier.verify(
      envelope,
      expectedNamespace: values.runNamespace,
      expectedRole: .a,
      expectedPhase: .audit,
      expectedKind: kind,
      expectedRecordName: try artifactRecordID(
        kind: kind, role: .a, values: values
      ).recordName,
      expectedLaunchGrantDigest: envelope.launchGrantDigest,
      expectedRunManifestDigest: values.runManifestDigest,
      expectedPlatform: .mac,
      expectedDestinationBindingDigest:
        envelope.verifiedLaunchGrant.manifest.destinationBindingDigest,
      credentialArtifact: credentialArtifact,
      trustedHostAuthorityPublicKey: values.trustedHostAuthorityPublicKey
    ) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    try await SecretSyncLiveAuditCompletionBoundary.run(
      envelope: envelope,
      evidence: evidence,
      stage: { envelope in
        try await ledger.stageAuditEnvelope(envelope)
      },
      publishOrValidate: { envelope in
        try await saveArtifactOrValidateIdentical(
          envelope, kind: kind, role: .a, values: values, ledger: ledger
        )
      },
      commitCompletionAndErase: { evidence in
        try await ledger.completeAuditAndEraseVerifierKeys(evidence: evidence)
      }
    )
  }

  private func liveStore(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) throws -> (
    store: SecretSyncCloudKitPolicyStore,
    digester: SecretSyncSHA256DigestProvider
  ) {
    let cloud = CKContainer(identifier: values.containerIdentifier).privateCloudDatabase
    let recording = SecretSyncLiveRecordingDatabase(database: cloud, ledger: ledger)
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    return (SecretSyncCloudKitPolicyStore(database: recording, digester: digester), digester)
  }

  private func possessionTranscript(
    _ generation: SecretSyncCustodyCredentialGeneration,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    boundDigest: SecretRecordDigest? = nil
  ) throws -> SecretSyncProofOfPossessionTranscript {
    let now = Date()
    let digestProvider = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let roleBinding = Data(
      "\(values.runNamespace)|\(values.deviceRole.rawValue)|possession".utf8
    )
    let headDigest = try boundDigest ?? digestProvider.digest(canonicalBytes: roleBinding)
    let policyDigest = try boundDigest ?? digestProvider.digest(
      canonicalBytes: roleBinding + Data("|policy".utf8)
    )
    return try SecretSyncProofOfPossessionTranscript(
      challengeID: UUID(), sessionID: UUID(),
      issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
      deviceID: generation.deviceID, credentialID: generation.credentialID,
      signingPublicKey: generation.signingPublicKey,
      agreementPublicKey: generation.agreementPublicKey,
      authorityCredentialID: DeviceCredentialID(UUID()),
      freshnessCommitment: try SecretBootstrapFreshnessCommitment(
        scopeID: scopeID(values), latestPolicyEpoch: 1,
        headCommitDigest: headDigest, policyDigest: policyDigest
      )
    )
  }

  private func provisionAgreementVerifiers(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      let key = P256.KeyAgreement.PrivateKey()
      try await ledger.storeAgreementVerifierPrivateKey(
        key.rawRepresentation, role: role
      )
      try await saveArtifact(
        SecretSyncLiveAgreementVerifierPublic(
          publicKey: key.publicKey.x963Representation
        ),
        kind: "agreement-verifier", role: role,
        values: values, ledger: ledger
      )
    }
  }

  private func complete(
    _ operation: SecretSyncLiveEvidence.Operation,
    relation: SecretSyncLiveEvidence.HeadRelation = .exact,
    productionSeam: String? = nil,
    outcomeDigest: Data? = nil,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let evidence = SecretSyncLiveEvidence(
      timestamp: Date(), deviceRole: values.deviceRole, operation: operation,
      resultCode: .passed, headRelation: relation,
      productionSeam: productionSeam, outcomeDigest: outcomeDigest
    )
    let kind = "phase-\(values.phase.rawValue)"
    let envelope = try await signedPhaseEnvelope(
      evidence, kind: kind, values: values, ledger: ledger
    )
    try await saveArtifact(
      envelope, kind: kind, role: values.deviceRole,
      values: values, ledger: ledger
    )
    try await ledger.complete(
      phase: values.phase,
      role: values.deviceRole,
      evidence: evidence
    )
  }

  private func requirePhase(
    _ phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let kind = "phase-\(phase.rawValue)"
    let envelope = try await loadArtifact(
      SecretSyncLiveSignedArtifactEnvelope.self, kind: kind,
      role: role, values: values
    )
    let credentialArtifact = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: role, values: values
    )
    guard values.launchGrant.manifest.prerequisiteArtifactDigests.contains(
      try envelope.artifactDigest()
    ), try SecretSyncLiveSignedArtifactVerifier.verify(
      envelope, expectedNamespace: values.runNamespace,
      expectedRole: role, expectedPhase: phase, expectedKind: kind,
      expectedRecordName: try artifactRecordID(
        kind: kind, role: role, values: values
      ).recordName,
      expectedLaunchGrantDigest: envelope.launchGrantDigest,
      expectedRunManifestDigest: values.runManifestDigest,
      expectedPlatform: SecretSyncLivePlatformMatrix.expectedPlatform(for: role),
      expectedDestinationBindingDigest:
        envelope.verifiedLaunchGrant.manifest.destinationBindingDigest,
      credentialArtifact: credentialArtifact,
      trustedHostAuthorityPublicKey: values.trustedHostAuthorityPublicKey
    ) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
  }

  private func signedPhaseEnvelope<T: Encodable>(
    _ artifact: T,
    kind: String,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws -> SecretSyncLiveSignedArtifactEnvelope {
    let checkpoint = try #require(
      try await ledger.credentialCheckpoint(role: values.deviceRole)
    )
    guard checkpoint.published else {
      throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
    }
    let binding = try await ledger.credentialBindingDigest(role: values.deviceRole)
    guard values.phase == .credential
      || binding == values.launchGrant.manifest.credentialBindingDigest else {
      throw SecretSyncLiveCloudKitProofConfigurationError.launchGrantCredentialMismatch
    }
    let payload = try JSONEncoder().encode(artifact)
    let payloadDigest = Data(SHA256.hash(data: payload))
    let recordName = try artifactRecordID(
      kind: kind, role: values.deviceRole, values: values
    ).recordName
    let placeholder = try artifactSigningTranscript(
      checkpoint: checkpoint, bodyDigest: Data(repeating: 0, count: 32),
      payloadDigest: payloadDigest, values: values
    )
    var envelope = SecretSyncLiveSignedArtifactEnvelope(
      version: 1, namespace: values.runNamespace,
      role: values.deviceRole, phase: values.phase, kind: kind,
      recordName: recordName, launchNonce: values.launchGrant.manifest.nonce,
      verifiedLaunchGrant: values.launchGrant,
      launchGrantDigest: values.launchGrantDigest,
      runManifestDigest: values.runManifestDigest,
      prerequisiteArtifactDigests: values.launchGrant.manifest
        .prerequisiteArtifactDigests,
      credentialBindingDigest: binding,
      signingPublicKey: checkpoint.signingPublicKey,
      agreementPublicKey: checkpoint.agreementPublicKey,
      payload: payload, payloadDigest: payloadDigest,
      signingTranscript: placeholder, signature: Data(repeating: 0, count: 64)
    )
    let bodyDigest = Data(SHA256.hash(data: try envelope.canonicalBody()))
    let transcript = try artifactSigningTranscript(
      checkpoint: checkpoint, bodyDigest: bodyDigest,
      payloadDigest: payloadDigest, values: values
    )
    let challenge = try SecretSyncSigningProofChallenge(
      transcript: transcript.productionValue()
    )
    let proof = try await SecretSyncSecureEnclaveCustody()
      .proveSigningKeyPossession(
        SigningProofOfPossessionRequest(
          credentialID: checkpoint.credentialID,
          privateKeyHandle: checkpoint.signingHandle,
          challengeID: transcript.challengeID,
          challengeBytes: challenge.canonicalBytes
        )
      )
    envelope = SecretSyncLiveSignedArtifactEnvelope(
      version: envelope.version, namespace: envelope.namespace,
      role: envelope.role, phase: envelope.phase, kind: envelope.kind,
      recordName: envelope.recordName, launchNonce: envelope.launchNonce,
      verifiedLaunchGrant: envelope.verifiedLaunchGrant,
      launchGrantDigest: envelope.launchGrantDigest,
      runManifestDigest: envelope.runManifestDigest,
      prerequisiteArtifactDigests: envelope.prerequisiteArtifactDigests,
      credentialBindingDigest: envelope.credentialBindingDigest,
      signingPublicKey: envelope.signingPublicKey,
      agreementPublicKey: envelope.agreementPublicKey,
      payload: envelope.payload, payloadDigest: envelope.payloadDigest,
      signingTranscript: transcript, signature: proof.proofBytes
    )
    let credentialArtifact = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: values.deviceRole, values: values
    )
    guard try SecretSyncLiveSignedArtifactVerifier.verify(
      envelope, expectedNamespace: values.runNamespace,
      expectedRole: values.deviceRole, expectedPhase: values.phase,
      expectedKind: kind, expectedRecordName: recordName,
      expectedLaunchGrantDigest: values.launchGrantDigest,
      expectedRunManifestDigest: values.runManifestDigest,
      expectedPlatform: values.launchGrant.manifest.platform,
      expectedDestinationBindingDigest:
        values.launchGrant.manifest.destinationBindingDigest,
      credentialArtifact: credentialArtifact,
      trustedHostAuthorityPublicKey: values.trustedHostAuthorityPublicKey
    ) else { throw SecretSyncCustodyError.invalidProof }
    return envelope
  }

  private func artifactSigningTranscript(
    checkpoint: SecretSyncLiveCleanupLedger.CredentialCheckpoint,
    bodyDigest: Data,
    payloadDigest: Data,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> SecretSyncLivePossessionTranscript {
    let now = Date()
    return SecretSyncLivePossessionTranscript(
      challengeID: UUID(), sessionID: UUID(), issuedAt: now.addingTimeInterval(-1),
      expiresAt: now.addingTimeInterval(300), deviceID: checkpoint.deviceID,
      credentialID: checkpoint.credentialID,
      signingPublicKey: checkpoint.signingPublicKey,
      agreementPublicKey: checkpoint.agreementPublicKey,
      // The independently signed launch nonce is the external authority
      // identity for this phase; the credential must never authorize itself.
      authorityCredentialID: DeviceCredentialID(
        values.launchGrant.manifest.nonce
      ),
      freshnessCommitment: try SecretBootstrapFreshnessCommitment(
        scopeID: try scopeID(values), latestPolicyEpoch: 1,
        headCommitDigest: try SecretRecordDigest(bytes: bodyDigest),
        policyDigest: try SecretRecordDigest(bytes: payloadDigest)
      )
    )
  }

  private func saveArtifact<T: Encodable>(
    _ artifact: T,
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let recordID = try artifactRecordID(kind: kind, role: role, values: values)
    let record = CKRecord(recordType: "U7SecretSyncProof", recordID: recordID)
    record["namespace"] = values.runNamespace as CKRecordValue
    record["kind"] = kind as CKRecordValue
    record["role"] = role.rawValue as CKRecordValue
    record["payload"] = try JSONEncoder().encode(artifact) as CKRecordValue
    try await ledger.recordBeforeSave(recordID)
    try await SecretSyncLiveImmutableArtifactStore.create(
      record,
      database: CKContainer(identifier: values.containerIdentifier)
        .privateCloudDatabase
    )
  }

  private func reconcileExactArtifact<T: Codable & Equatable>(
    _ expected: T,
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) async throws -> T? {
    let recordID = try artifactRecordID(kind: kind, role: role, values: values)
    let results = try await CKContainer(identifier: values.containerIdentifier)
      .privateCloudDatabase.fetch(withRecordIDs: [recordID])
    switch results[recordID] {
    case .success(let record):
      guard record["namespace"] as? String == values.runNamespace,
        record["kind"] as? String == kind,
        record["role"] as? String == role.rawValue,
        let payload = record["payload"] as? Data,
        try JSONDecoder().decode(T.self, from: payload) == expected
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      return expected
    case .failure(let error):
      if (error as? CKError)?.code == .unknownItem {
        return nil
      }
      throw error
    case nil:
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
  }

  private func saveArtifactOrValidateIdentical<T: Codable & Equatable>(
    _ artifact: T,
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    do {
      try await saveArtifact(
        artifact, kind: kind, role: role, values: values, ledger: ledger
      )
    } catch {
      let publicationFailure = error
      guard try await reconcileExactArtifact(
        artifact, kind: kind, role: role, values: values
      ) != nil else {
        throw publicationFailure
      }
    }
  }

  private func loadPhaseEvidence(
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws -> SecretSyncLiveEvidence {
    let kind = "phase-\(phase.rawValue)"
    let envelope = try await loadArtifact(
      SecretSyncLiveSignedArtifactEnvelope.self, kind: kind,
      role: role, values: values
    )
    let credentialArtifact = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: role, values: values
    )
    guard try SecretSyncLiveSignedArtifactVerifier.verify(
      envelope, expectedNamespace: values.runNamespace,
      expectedRole: role, expectedPhase: phase, expectedKind: kind,
      expectedRecordName: try artifactRecordID(
        kind: kind, role: role, values: values
      ).recordName,
      expectedLaunchGrantDigest: envelope.launchGrantDigest,
      expectedRunManifestDigest: values.runManifestDigest,
      expectedPlatform: SecretSyncLivePlatformMatrix.expectedPlatform(for: role),
      expectedDestinationBindingDigest:
        envelope.verifiedLaunchGrant.manifest.destinationBindingDigest,
      credentialArtifact: credentialArtifact,
      trustedHostAuthorityPublicKey: values.trustedHostAuthorityPublicKey
    ) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
    }
    return try JSONDecoder().decode(SecretSyncLiveEvidence.self, from: envelope.payload)
  }

  private func loadArtifact<T: Decodable>(
    _ type: T.Type,
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) async throws -> T {
    let recordID = try artifactRecordID(kind: kind, role: role, values: values)
    let results = try await CKContainer(identifier: values.containerIdentifier)
      .privateCloudDatabase.fetch(withRecordIDs: [recordID])
    guard case .success(let record)? = results[recordID],
      let namespace = record["namespace"] as? String,
      namespace == values.runNamespace,
      let payload = record["payload"] as? Data
    else { throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase }
    return try JSONDecoder().decode(type, from: payload)
  }

  private func artifactRecordID(
    kind: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> CKRecord.ID {
    try SecretSyncLiveArtifactRecordID.make(
      kind: kind, role: role, values: values
    )
  }

  private func requirePreexistingZones(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) async throws {
    let database = CKContainer(identifier: values.containerIdentifier)
      .privateCloudDatabase
    try SecretSyncLiveZoneAdmission.requirePreexisting(
      observed: try await database.allRecordZones().map(\.zoneID),
      control: values.controlZoneID, payload: values.payloadZoneID
    )
  }

  private func commitment(
    _ commit: SecretTransitionCommit
  ) throws -> SecretBootstrapFreshnessCommitment {
    try SecretBootstrapFreshnessCommitment(
      scopeID: commit.scopeID, latestPolicyEpoch: commit.policyEpoch,
      headCommitDigest: commit.recordDigest, policyDigest: commit.policyDigest
    )
  }

  private func scopeID(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> SecretScopeID {
    guard let value = UUID(uuidString: String(values.runNamespace.dropFirst(3))) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.invalidRunNamespace
    }
    return SecretScopeID(value)
  }

  private func requiredConfiguration() throws
    -> SecretSyncLiveCloudKitProofConfiguration.Values
  {
    switch SecretSyncLiveCloudKitProofConfiguration.load() {
    case .configured(let values): return values
    case .disabled: throw SecretSyncLiveCloudKitProofConfigurationError.operatorAttestationMissing
    case .invalid(let error): throw error
    }
  }
}

private actor SecretSyncLiveNetworkObservation {
  private var offlineTransportFailure = false

  func recordOfflineTransportFailure() {
    offlineTransportFailure = true
  }

  func observedOfflineTransportFailure() -> Bool {
    offlineTransportFailure
  }
}

private struct SecretSyncLiveRecordingDatabase: CloudKitDatabaseProtocol {
  let database: CKDatabase
  let ledger: SecretSyncLiveCleanupLedger
  let networkObservation: SecretSyncLiveNetworkObservation?

  init(
    database: CKDatabase,
    ledger: SecretSyncLiveCleanupLedger,
    networkObservation: SecretSyncLiveNetworkObservation? = nil
  ) {
    self.database = database
    self.ledger = ledger
    self.networkObservation = networkObservation
  }

  func modifyRecords(
    saving records: [CKRecord],
    deleting ids: [CKRecord.ID],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
    atomically: Bool
  ) async throws -> (
    saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
    deleteResults: [CKRecord.ID: Result<Void, any Error>]
  ) {
    for record in records { try await ledger.recordBeforeSave(record.recordID) }
    return try await database.modifyRecords(
      saving: records, deleting: ids, savePolicy: savePolicy, atomically: atomically
    )
  }

  func fetch(
    withRecordIDs ids: [CKRecord.ID]
  ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
    do {
      return try await database.fetch(withRecordIDs: ids)
    } catch {
      if let code = (error as? CKError)?.code,
        code == .networkFailure || code == .networkUnavailable {
        await networkObservation?.recordOfflineTransportFailure()
      }
      throw error
    }
  }

  func fetchZoneChanges(
    inZoneWith zoneID: CKRecordZone.ID,
    since token: CKServerChangeToken?
  ) async throws -> CloudKitZoneChanges {
    try await database.fetchZoneChanges(inZoneWith: zoneID, since: token)
  }

  func modifyRecordZones(
    saving zones: [CKRecordZone],
    deleting ids: [CKRecordZone.ID]
  ) async throws -> (
    saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
    deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
  ) {
    throw SecretSyncLiveCloudKitProofConfigurationError.zoneMutationProhibited
  }

  func modifySubscriptions(
    saving subscriptions: [CKSubscription],
    deleting ids: [CKSubscription.ID]
  ) async throws -> (
    saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
    deleteResults: [CKSubscription.ID: Result<Void, any Error>]
  ) {
    try await database.modifySubscriptions(saving: subscriptions, deleting: ids)
  }
}

private extension Sequence {
  func asyncMap<T>(
    _ transform: (Element) async throws -> T
  ) async rethrows -> [T] {
    var values: [T] = []
    for element in self { values.append(try await transform(element)) }
    return values
  }
}

private struct SecretSyncLiveAttestationFixture {
  enum Mutation: CaseIterable { case launchGrant, signingChallenge, signingProof, agreementChallenge
    case agreementProof, attestationChallenge, attestationProof }

  let namespace: String
  let launchGrantDigest: Data
  let credentialRecordName: String
  let verifierRecordName: String
  let signing: P256.Signing.PrivateKey
  let agreement: P256.KeyAgreement.PrivateKey
  let verifier: P256.KeyAgreement.PrivateKey
  let evidence: SecretSyncLiveCredentialEvidence

  static func make() throws -> SecretSyncLiveAttestationFixture {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let launchGrantDigest = Data(SHA256.hash(data: Data("host-grant-A".utf8)))
    let credentialRecordName = "\(namespace)-credential-A"
    let verifierRecordName = "\(namespace)-agreement-verifier-A"
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    let verifier = P256.KeyAgreement.PrivateKey()
    let signingPublic = try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("fixture-signing".utf8),
      publicKeyBytes: signing.publicKey.x963Representation
    )
    let agreementPublic = try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("fixture-agreement".utf8),
      publicKeyBytes: agreement.publicKey.x963Representation
    )
    let transcript = try transcript(
      signing: signingPublic, agreement: agreementPublic,
      head: U7GoldenVectors.digest(0xA1), policy: U7GoldenVectors.digest(0xA2),
      challenge: U7UUID.byte(0xA3), session: U7UUID.byte(0xA4)
    )
    let signingChallenge = try SecretSyncSigningProofChallenge(transcript: transcript)
    let signatures = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    let signingProof = try signatures.sign(
      canonicalBytes: signingChallenge.canonicalBytes, using: signing
    )
    let agreementChallenge = try SecretSyncLiveAttestation.agreementChallenge(
      transcript: transcript,
      verifierPublicKey: verifier.publicKey.x963Representation
    )
    let agreementProof = try SecretSyncLiveAttestation.agreementResponse(
      challenge: agreementChallenge, credentialPrivateKey: agreement,
      verifierPublicKey: verifier.publicKey.x963Representation
    )
    let credential = try TrustedDeviceCredential(
      deviceID: transcript.deviceID, credentialID: transcript.credentialID,
      credentialVersion: 1, status: .active,
      signingPublicKey: signingPublic, keyAgreementPublicKey: agreementPublic,
      enrollmentProof: DeviceCredentialEnrollmentProof(
        challengeID: transcript.challengeID,
        challengeBytes: signingChallenge.canonicalBytes,
        signingProofBytes: signingProof,
        keyAgreementProofBytes: agreementProof,
        provenance: .globalRecovery(
          GlobalRecoveryEnrollmentAuthority(
            requestID: transcript.sessionID,
            recoveryRecipientID: U7UUID.byte(0xA5)
          )
        )
      )
    )
    let transcriptValue = SecretSyncLiveAttestation.transcriptValue(transcript)
    let body = try SecretSyncLiveAttestation.canonicalBody(
      namespace: namespace, role: .a,
      launchGrantDigest: launchGrantDigest,
      credentialRecordName: credentialRecordName,
      verifierRecordName: verifierRecordName,
      credential: credential, transcript: transcriptValue,
      signingChallenge: signingChallenge.canonicalBytes, signingProof: signingProof,
      agreementChallenge: agreementChallenge, agreementProof: agreementProof
    )
    let bodyDigest = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
      .digest(canonicalBytes: body)
    let attestation = try Self.transcript(
      signing: signingPublic, agreement: agreementPublic,
      head: bodyDigest, policy: bodyDigest,
      challenge: U7UUID.byte(0xA6), session: U7UUID.byte(0xA7)
    )
    let attestationChallenge = try SecretSyncSigningProofChallenge(transcript: attestation)
    let attestationProof = try signatures.sign(
      canonicalBytes: attestationChallenge.canonicalBytes, using: signing
    )
    let evidence = SecretSyncLiveCredentialEvidence(
      launchGrantDigest: launchGrantDigest,
      credential: credential, possessionTranscript: transcriptValue,
      signingChallenge: signingChallenge.canonicalBytes, signingProof: signingProof,
      agreementChallenge: agreementChallenge, agreementProof: agreementProof,
      attestationTranscript: SecretSyncLiveAttestation.transcriptValue(attestation),
      attestationChallenge: attestationChallenge.canonicalBytes,
      attestationProof: attestationProof,
      evidenceID: SecretSyncLiveAttestation.evidenceID(
        body: body, challenge: attestationChallenge.canonicalBytes,
        proof: attestationProof
      )
    )
    return SecretSyncLiveAttestationFixture(
      namespace: namespace, launchGrantDigest: launchGrantDigest,
      credentialRecordName: credentialRecordName,
      verifierRecordName: verifierRecordName,
      signing: signing,
      agreement: agreement,
      verifier: verifier, evidence: evidence
    )
  }

  func mutated(_ mutation: Mutation) -> SecretSyncLiveCredentialEvidence {
    func changed(_ bytes: Data) -> Data {
      var bytes = bytes
      bytes[bytes.startIndex] ^= 1
      return bytes
    }
    return SecretSyncLiveCredentialEvidence(
      launchGrantDigest: mutation == .launchGrant
        ? changed(evidence.launchGrantDigest) : evidence.launchGrantDigest,
      credential: evidence.credential,
      possessionTranscript: evidence.possessionTranscript,
      signingChallenge: mutation == .signingChallenge
        ? changed(evidence.signingChallenge) : evidence.signingChallenge,
      signingProof: mutation == .signingProof
        ? changed(evidence.signingProof) : evidence.signingProof,
      agreementChallenge: mutation == .agreementChallenge
        ? changed(evidence.agreementChallenge) : evidence.agreementChallenge,
      agreementProof: mutation == .agreementProof
        ? changed(evidence.agreementProof) : evidence.agreementProof,
      attestationTranscript: evidence.attestationTranscript,
      attestationChallenge: mutation == .attestationChallenge
        ? changed(evidence.attestationChallenge) : evidence.attestationChallenge,
      attestationProof: mutation == .attestationProof
        ? changed(evidence.attestationProof) : evidence.attestationProof,
      evidenceID: evidence.evidenceID
    )
  }

  private static func transcript(
    signing: SigningPublicKeyDescriptor,
    agreement: KeyAgreementPublicKeyDescriptor,
    head: SecretRecordDigest,
    policy: SecretRecordDigest,
    challenge: UUID,
    session: UUID
  ) throws -> SecretSyncProofOfPossessionTranscript {
    try SecretSyncProofOfPossessionTranscript(
      challengeID: challenge, sessionID: session,
      issuedAt: Date(timeIntervalSince1970: 1_000),
      expiresAt: Date(timeIntervalSince1970: 2_000),
      deviceID: TrustedDeviceID(U7UUID.byte(0xB1)),
      credentialID: DeviceCredentialID(U7UUID.byte(0xB2)),
      signingPublicKey: signing, agreementPublicKey: agreement,
      authorityCredentialID: DeviceCredentialID(U7UUID.byte(0xB3)),
      freshnessCommitment: SecretBootstrapFreshnessCommitment(
        scopeID: U7GoldenVectors.scopeID, latestPolicyEpoch: 1,
        headCommitDigest: head, policyDigest: policy
      )
    )
  }
}

private enum SecretSyncLiveDistinctnessFixtures {
  enum Reuse: Equatable {
    case credentialID
    case signingDescriptor
    case signingKeyID
    case signingKeyBytes
    case agreementDescriptor
    case agreementKeyID
    case agreementKeyBytes
  }

  static func make() throws -> [SecretSyncLiveCredentialEvidence] {
    let template = try SecretSyncLiveAttestationFixture.make().evidence
    return try (0..<3).map { index in
      let signing = P256.Signing.PrivateKey()
      let agreement = P256.KeyAgreement.PrivateKey()
      let credential = try TrustedDeviceCredential(
        deviceID: TrustedDeviceID(UUID()), credentialID: DeviceCredentialID(UUID()),
        credentialVersion: 1, status: .active,
        signingPublicKey: SigningPublicKeyDescriptor(
          algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
          keyIdentifier: Data("distinct-signing-\(index)".utf8),
          publicKeyBytes: signing.publicKey.x963Representation
        ),
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
          algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
          keyIdentifier: Data("distinct-agreement-\(index)".utf8),
          publicKeyBytes: agreement.publicKey.x963Representation
        ),
        enrollmentProof: template.credential.enrollmentProof
      )
      return replacing(
        template, credential: credential,
        evidenceID: "distinct-evidence-\(index)",
        grantDigest: Data(SHA256.hash(data: Data("distinct-grant-\(index)".utf8)))
      )
    }
  }

  static func reusing(
    _ reuse: Reuse,
    from source: SecretSyncLiveCredentialEvidence,
    in target: SecretSyncLiveCredentialEvidence
  ) throws -> SecretSyncLiveCredentialEvidence {
    let signing = try SigningPublicKeyDescriptor(
      algorithmIdentifier: target.credential.signingPublicKey.algorithmIdentifier,
      keyIdentifier: reuse == .signingDescriptor || reuse == .signingKeyID
        ? source.credential.signingPublicKey.keyIdentifier
        : target.credential.signingPublicKey.keyIdentifier,
      publicKeyBytes: reuse == .signingDescriptor || reuse == .signingKeyBytes
        ? source.credential.signingPublicKey.publicKeyBytes
        : target.credential.signingPublicKey.publicKeyBytes
    )
    let agreement = try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: target.credential.keyAgreementPublicKey.algorithmIdentifier,
      keyIdentifier: reuse == .agreementDescriptor || reuse == .agreementKeyID
        ? source.credential.keyAgreementPublicKey.keyIdentifier
        : target.credential.keyAgreementPublicKey.keyIdentifier,
      publicKeyBytes: reuse == .agreementDescriptor || reuse == .agreementKeyBytes
        ? source.credential.keyAgreementPublicKey.publicKeyBytes
        : target.credential.keyAgreementPublicKey.publicKeyBytes
    )
    let credential = try TrustedDeviceCredential(
      deviceID: target.credential.deviceID,
      credentialID: reuse == .credentialID
        ? source.credential.credentialID : target.credential.credentialID,
      credentialVersion: target.credential.credentialVersion,
      status: target.credential.status,
      signingPublicKey: signing,
      keyAgreementPublicKey: agreement,
      enrollmentProof: target.credential.enrollmentProof
    )
    return replacing(
      target, credential: credential, evidenceID: target.evidenceID,
      grantDigest: target.launchGrantDigest
    )
  }

  private static func replacing(
    _ evidence: SecretSyncLiveCredentialEvidence,
    credential: TrustedDeviceCredential,
    evidenceID: String,
    grantDigest: Data
  ) -> SecretSyncLiveCredentialEvidence {
    SecretSyncLiveCredentialEvidence(
      launchGrantDigest: grantDigest, credential: credential,
      possessionTranscript: evidence.possessionTranscript,
      signingChallenge: evidence.signingChallenge,
      signingProof: evidence.signingProof,
      agreementChallenge: evidence.agreementChallenge,
      agreementProof: evidence.agreementProof,
      attestationTranscript: evidence.attestationTranscript,
      attestationChallenge: evidence.attestationChallenge,
      attestationProof: evidence.attestationProof, evidenceID: evidenceID
    )
  }
}

private actor SecretSyncLiveArtifactDatabaseFake: CloudKitDatabaseProtocol {
  private(set) var savePolicies: [CKModifyRecordsOperation.RecordSavePolicy] = []
  private(set) var zoneMutationCount = 0
  private(set) var deleteInvocationCount = 0
  private(set) var deletedRecordIDs = Set<CKRecord.ID>()
  private(set) var fetchInvocationCount = 0
  private var forceNetworkFailure = false
  private var deleteFailures = Set<CKRecord.ID>()
  private var failNextVerification = false
  private var records: [CKRecord.ID: CKRecord] = [:]

  func setNetworkFailure(_ value: Bool) {
    forceNetworkFailure = value
  }

  func setDeleteFailures(_ recordIDs: Set<CKRecord.ID>) {
    deleteFailures = recordIDs
  }

  func failNextAbsenceVerification() {
    failNextVerification = true
  }

  func seed(recordIDs: [CKRecord.ID]) {
    for recordID in recordIDs {
      records[recordID] = CKRecord(recordType: "U7SecretSyncProof", recordID: recordID)
    }
  }

  func modifyRecords(
    saving values: [CKRecord], deleting ids: [CKRecord.ID],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool
  ) async throws -> (
    saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
    deleteResults: [CKRecord.ID: Result<Void, any Error>]
  ) {
    savePolicies.append(savePolicy)
    var saves: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
    for value in values {
      if records[value.recordID] == nil {
        records[value.recordID] = value
        saves[value.recordID] = .success(value)
      } else {
        saves[value.recordID] = .failure(SecretSyncLiveArtifactFakeError.exists)
      }
    }
    if !ids.isEmpty { deleteInvocationCount += 1 }
    var deletes: [CKRecord.ID: Result<Void, any Error>] = [:]
    for id in ids {
      if deleteFailures.contains(id) {
        deletes[id] = .failure(CKError(.serverRejectedRequest))
      } else if records.removeValue(forKey: id) != nil {
        deletedRecordIDs.insert(id)
        deletes[id] = .success(())
      } else {
        deletes[id] = .failure(CKError(.unknownItem))
      }
    }
    return (saves, deletes)
  }

  func fetch(
    withRecordIDs ids: [CKRecord.ID]
  ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
    fetchInvocationCount += 1
    if forceNetworkFailure { throw CKError(.networkFailure) }
    if failNextVerification {
      failNextVerification = false
      throw CKError(.networkUnavailable)
    }
    return Dictionary(uniqueKeysWithValues: ids.map { id -> (
      CKRecord.ID, Result<CKRecord, any Error>
    ) in
      if let record = records[id] {
        return (id, .success(record))
      }
      return (id, .failure(CKError(.unknownItem)))
    })
  }

  func fetchZoneChanges(
    inZoneWith zoneID: CKRecordZone.ID, since token: CKServerChangeToken?
  ) async throws -> CloudKitZoneChanges {
    CloudKitZoneChanges(
      modifiedRecords: [], deletedRecordIDs: [], changeToken: token
    )
  }

  func modifyRecordZones(
    saving zones: [CKRecordZone], deleting ids: [CKRecordZone.ID]
  ) async throws -> (
    saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
    deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
  ) {
    zoneMutationCount += 1
    return ([:], [:])
  }

  func modifySubscriptions(
    saving subscriptions: [CKSubscription], deleting ids: [CKSubscription.ID]
  ) async throws -> (
    saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
    deleteResults: [CKSubscription.ID: Result<Void, any Error>]
  ) { ([:], [:]) }
}

private actor SecretSyncLiveCleanupEntryProbe {
  private(set) var prerequisiteVerificationCount = 0
  private(set) var credentialRemovalCount = 0
  private(set) var markerSaveCount = 0

  func recordPrerequisiteVerification() {
    prerequisiteVerificationCount += 1
  }

  func recordCredentialRemoval() {
    credentialRemovalCount += 1
  }

  func shouldCrashAfterFirstMarkerSave() -> Bool {
    markerSaveCount += 1
    return markerSaveCount == 1
  }
}

private actor SecretSyncRestartHandleProbe {
  private var roles: Set<String>
  private(set) var removalAttemptCount = 0

  init(insertedCount: Int) {
    roles = Set(["signing", "agreement"].prefix(insertedCount))
  }

  var remainingCount: Int { roles.count }

  func removeBoth() throws {
    for role in ["signing", "agreement"] {
      removalAttemptCount += 1
      roles.remove(role)
    }
  }
}

private enum SecretSyncLiveArtifactFakeError: Error {
  case exists
  case postSaveCrash
  case mismatch
}

private struct SecretSyncLiveSignedArtifactFixture {
  enum Mutation: CaseIterable {
    case launchGrant
    case role
    case phase
    case nonce
    case runManifestDigest
    case prerequisites
    case credentialBinding
    case credentialID
    case signingDescriptor
    case agreementDescriptor
    case signingKey
  }

  let authority: P256.Signing.PrivateKey
  let signing: P256.Signing.PrivateKey
  let agreement: P256.KeyAgreement.PrivateKey
  let grant: SecretSyncLiveHostLaunchGrant
  let grantDigest: Data
  let runManifestDigest: Data
  let credential: TrustedDeviceCredential
  let credentialArtifact: SecretSyncLiveCredentialEvidence
  let envelope: SecretSyncLiveSignedArtifactEnvelope

  static func make(
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase = .credential,
    grantCredentialBinding: Data? = nil
  ) throws -> SecretSyncLiveSignedArtifactFixture {
    let authority = P256.Signing.PrivateKey()
    let credentialFixture = try SecretSyncLiveAttestationFixture.make()
    let signing = credentialFixture.signing
    let agreement = credentialFixture.agreement
    let credential = credentialFixture.evidence.credential
    let runManifestDigest = Data(repeating: 0x61, count: 32)
    let grant = try signedGrant(
      authority: authority,
      manifest: grantManifest(
        runManifestDigest: runManifestDigest,
        phase: phase,
        credentialGrantDigest: credentialFixture.evidence.launchGrantDigest,
        credentialBindingDigest: phase == .credential
          ? nil
          : grantCredentialBinding
            ?? SecretSyncLiveCredentialBinding.digest(credential)
      )
    )
    let grantDigest = try digest(grant, authority: authority)
    let envelope = try makeEnvelope(
      grant: grant, grantDigest: grantDigest,
      runManifestDigest: runManifestDigest,
      credential: credential, signing: signing
    )
    return SecretSyncLiveSignedArtifactFixture(
      authority: authority, signing: signing, agreement: agreement,
      grant: grant, grantDigest: grantDigest,
      runManifestDigest: runManifestDigest,
      credential: credential, credentialArtifact: credentialFixture.evidence,
      envelope: envelope
    )
  }

  func verify(_ candidate: SecretSyncLiveSignedArtifactEnvelope) throws -> Bool {
    try SecretSyncLiveSignedArtifactVerifier.verify(
      candidate,
      expectedNamespace: envelope.namespace,
      expectedRole: envelope.role,
      expectedPhase: envelope.phase,
      expectedKind: envelope.kind,
      expectedRecordName: envelope.recordName,
      expectedLaunchGrantDigest: grantDigest,
      expectedRunManifestDigest: runManifestDigest,
      expectedPlatform: grant.manifest.platform,
      expectedDestinationBindingDigest: grant.manifest.destinationBindingDigest,
      credentialArtifact: credentialArtifact,
      trustedHostAuthorityPublicKey: authority.publicKey.x963Representation
    )
  }

  func mutated(_ mutation: Mutation) throws -> SecretSyncLiveSignedArtifactEnvelope {
    var manifest = grant.manifest
    var candidateSigning = signing
    let substituted = try SecretSyncLiveAttestationFixture.make()
    var bindingOverride: Data?
    var credentialIDOverride: DeviceCredentialID?
    var signingDescriptorOverride: SigningPublicKeyDescriptor?
    var agreementDescriptorOverride: KeyAgreementPublicKeyDescriptor?
    var grantWasMutated = false
    switch mutation {
    case .launchGrant, .nonce:
      manifest = Self.replacing(manifest, nonce: UUID())
      grantWasMutated = true
    case .role:
      manifest = Self.replacing(manifest, role: .b)
      grantWasMutated = true
    case .phase:
      manifest = Self.replacing(manifest, phase: .verify)
      grantWasMutated = true
    case .runManifestDigest:
      manifest = Self.replacing(
        manifest, runManifestDigest: Data(repeating: 0x62, count: 32)
      )
      grantWasMutated = true
    case .prerequisites:
      manifest = Self.replacing(
        manifest, prerequisites: [Data(repeating: 0x63, count: 32)]
      )
      grantWasMutated = true
    case .credentialBinding:
      bindingOverride = Data(repeating: 0x65, count: 32)
    case .credentialID:
      credentialIDOverride = DeviceCredentialID(UUID())
    case .signingDescriptor:
      signingDescriptorOverride = substituted.evidence.credential.signingPublicKey
    case .agreementDescriptor:
      agreementDescriptorOverride = substituted.evidence.credential
        .keyAgreementPublicKey
    case .signingKey:
      candidateSigning = substituted.signing
    }
    let candidateGrant = grantWasMutated
      ? try Self.signedGrant(authority: authority, manifest: manifest)
      : grant
    let candidateGrantDigest = grantWasMutated
      ? try Self.digest(candidateGrant, authority: authority)
      : grantDigest
    return try Self.makeEnvelope(
      grant: candidateGrant,
      grantDigest: candidateGrantDigest,
      runManifestDigest: manifest.runManifestDigest,
      credential: credential,
      signing: candidateSigning,
      credentialBindingDigest: bindingOverride,
      transcriptCredentialID: credentialIDOverride,
      signingPublicKey: signingDescriptorOverride,
      agreementPublicKey: agreementDescriptorOverride
    )
  }

  private static func grantManifest(
    runManifestDigest: Data,
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    credentialGrantDigest: Data,
    credentialBindingDigest: Data?
  ) -> SecretSyncLiveHostLaunchGrant.Manifest {
    SecretSyncLiveHostLaunchGrant.Manifest(
      version: 2,
      runNamespace: "u7-00112233-4455-6677-8899-aabbccddeeff",
      role: .a,
      phase: phase,
      platform: .mac,
      nonce: U7UUID.byte(0x70),
      issuedAtUnixSeconds: 1_000,
      expiresAtUnixSeconds: 1_200,
      runManifestDigest: runManifestDigest,
      destinationBindingDigest: Data(repeating: 0xD1, count: 32),
      expectedLedgerContentDigest: Data(repeating: 0x64, count: 32),
      prerequisiteArtifactDigests: [],
      trustedCredentialGrantDigestsByRole: ["A": credentialGrantDigest],
      credentialBindingDigest: credentialBindingDigest,
      cleanupAuthorizationDigest: nil
    )
  }

  private static func replacing(
    _ value: SecretSyncLiveHostLaunchGrant.Manifest,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole? = nil,
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase? = nil,
    nonce: UUID? = nil,
    runManifestDigest: Data? = nil,
    prerequisites: [Data]? = nil
  ) -> SecretSyncLiveHostLaunchGrant.Manifest {
    SecretSyncLiveHostLaunchGrant.Manifest(
      version: value.version,
      runNamespace: value.runNamespace,
      role: role ?? value.role,
      phase: phase ?? value.phase,
      platform: value.platform,
      nonce: nonce ?? value.nonce,
      issuedAtUnixSeconds: value.issuedAtUnixSeconds,
      expiresAtUnixSeconds: value.expiresAtUnixSeconds,
      runManifestDigest: runManifestDigest ?? value.runManifestDigest,
      destinationBindingDigest: value.destinationBindingDigest,
      expectedLedgerContentDigest: value.expectedLedgerContentDigest,
      prerequisiteArtifactDigests: prerequisites ?? value.prerequisiteArtifactDigests,
      trustedCredentialGrantDigestsByRole: value.trustedCredentialGrantDigestsByRole,
      credentialBindingDigest: value.credentialBindingDigest,
      cleanupAuthorizationDigest: value.cleanupAuthorizationDigest
    )
  }

  private static func signedGrant(
    authority: P256.Signing.PrivateKey,
    manifest: SecretSyncLiveHostLaunchGrant.Manifest
  ) throws -> SecretSyncLiveHostLaunchGrant {
    let body = try SecretSyncLiveHostLaunchGrantVerifier
      .canonicalManifestBytes(manifest)
    return SecretSyncLiveHostLaunchGrant(
      manifest: manifest,
      signature: try authority.signature(for: body).derRepresentation
    )
  }

  private static func digest(
    _ grant: SecretSyncLiveHostLaunchGrant,
    authority: P256.Signing.PrivateKey
  ) throws -> Data {
    SecretSyncLiveHostLaunchGrantVerifier.digest(
      authorityPublicKey: authority.publicKey.x963Representation,
      manifestBytes: try SecretSyncLiveHostLaunchGrantVerifier
        .canonicalManifestBytes(grant.manifest),
      signature: grant.signature
    )
  }

  private static func makeEnvelope(
    grant: SecretSyncLiveHostLaunchGrant,
    grantDigest: Data,
    runManifestDigest: Data,
    credential: TrustedDeviceCredential,
    signing: P256.Signing.PrivateKey,
    credentialBindingDigest: Data? = nil,
    transcriptCredentialID: DeviceCredentialID? = nil,
    signingPublicKey: SigningPublicKeyDescriptor? = nil,
    agreementPublicKey: KeyAgreementPublicKeyDescriptor? = nil
  ) throws -> SecretSyncLiveSignedArtifactEnvelope {
    let payload = Data("approved-phase-evidence".utf8)
    let payloadDigest = Data(SHA256.hash(data: payload))
    let namespace = grant.manifest.runNamespace
    let role = grant.manifest.role
    let phase = grant.manifest.phase
    let kind = "phase-\(phase.rawValue)"
    let recordName = "\(namespace)-\(kind)-\(role.rawValue)"
    let claimedSigningPublicKey = signingPublicKey
      ?? credential.signingPublicKey
    let claimedAgreementPublicKey = agreementPublicKey
      ?? credential.keyAgreementPublicKey
    func transcript(_ bodyDigest: Data) throws -> SecretSyncLivePossessionTranscript {
      SecretSyncLivePossessionTranscript(
        challengeID: U7UUID.byte(0x74),
        sessionID: U7UUID.byte(0x75),
        issuedAt: Date(timeIntervalSince1970: 1_000),
        expiresAt: Date(timeIntervalSince1970: 2_000),
        deviceID: credential.deviceID,
        credentialID: transcriptCredentialID ?? credential.credentialID,
        signingPublicKey: claimedSigningPublicKey,
        agreementPublicKey: claimedAgreementPublicKey,
        authorityCredentialID: DeviceCredentialID(grant.manifest.nonce),
        freshnessCommitment: try SecretBootstrapFreshnessCommitment(
          scopeID: U7GoldenVectors.scopeID,
          latestPolicyEpoch: 1,
          headCommitDigest: SecretRecordDigest(bytes: bodyDigest),
          policyDigest: SecretRecordDigest(bytes: payloadDigest)
        )
      )
    }
    var envelope = SecretSyncLiveSignedArtifactEnvelope(
      version: 1,
      namespace: namespace,
      role: role,
      phase: phase,
      kind: kind,
      recordName: recordName,
      launchNonce: grant.manifest.nonce,
      verifiedLaunchGrant: grant,
      launchGrantDigest: grantDigest,
      runManifestDigest: runManifestDigest,
      prerequisiteArtifactDigests: grant.manifest.prerequisiteArtifactDigests,
      credentialBindingDigest: credentialBindingDigest
        ?? SecretSyncLiveCredentialBinding.digest(credential),
      signingPublicKey: claimedSigningPublicKey,
      agreementPublicKey: claimedAgreementPublicKey,
      payload: payload,
      payloadDigest: payloadDigest,
      signingTranscript: try transcript(Data(repeating: 0, count: 32)),
      signature: Data(repeating: 0, count: 64)
    )
    let boundTranscript = try transcript(Data(SHA256.hash(data: envelope.canonicalBody())))
    let challenge = try SecretSyncSigningProofChallenge(
      transcript: boundTranscript.productionValue()
    )
    envelope = SecretSyncLiveSignedArtifactEnvelope(
      version: envelope.version,
      namespace: envelope.namespace,
      role: envelope.role,
      phase: envelope.phase,
      kind: envelope.kind,
      recordName: envelope.recordName,
      launchNonce: envelope.launchNonce,
      verifiedLaunchGrant: envelope.verifiedLaunchGrant,
      launchGrantDigest: envelope.launchGrantDigest,
      runManifestDigest: envelope.runManifestDigest,
      prerequisiteArtifactDigests: envelope.prerequisiteArtifactDigests,
      credentialBindingDigest: envelope.credentialBindingDigest,
      signingPublicKey: envelope.signingPublicKey,
      agreementPublicKey: envelope.agreementPublicKey,
      payload: envelope.payload,
      payloadDigest: envelope.payloadDigest,
      signingTranscript: boundTranscript,
      signature: try signing.signature(for: challenge.canonicalBytes).rawRepresentation
    )
    return envelope
  }
}
