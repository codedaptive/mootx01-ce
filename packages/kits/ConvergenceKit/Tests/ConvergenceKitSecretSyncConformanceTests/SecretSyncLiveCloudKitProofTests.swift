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
    manifest: [SecretSyncLiveRecordReference],
    artifactIDs: [CKRecord.ID],
    headID: CKRecord.ID,
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws -> [CKRecord.ID] {
    var recordIDs = manifest.map {
      CKRecord.ID(
        recordName: $0.recordName,
        zoneID: CKRecordZone.ID(
          zoneName: $0.zoneName, ownerName: CKCurrentUserDefaultName
        )
      )
    }
    recordIDs.append(contentsOf: artifactIDs)
    recordIDs.append(headID)
    let exact = Array(Set(recordIDs))
    try requireAuthorized(exact, values: values)
    return exact
  }

  static func requireAuthorized(
    _ recordIDs: [CKRecord.ID],
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws {
    let allowed = Set([values.controlZoneID, values.payloadZoneID])
    guard recordIDs.allSatisfy({ allowed.contains($0.zoneID) }) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone
    }
  }

  static func deleteAndVerify(
    _ recordIDs: [CKRecord.ID],
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    database: any CloudKitDatabaseProtocol,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try requireAuthorized(recordIDs, values: values)
    guard !recordIDs.isEmpty else {
      try await ledger.retainUnresolved([])
      return
    }
    var unresolved = Set(recordIDs)
    for ids in Dictionary(grouping: recordIDs, by: \.zoneID).values {
      try requireAuthorized(ids, values: values)
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
    try requireAuthorized(recordIDs, values: values)
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
    _ marker: SecretSyncLiveEvidence,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    database: any CloudKitDatabaseProtocol,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let kind = "phase-cleanup"
    let recordID = try SecretSyncLiveArtifactRecordID.make(
      kind: kind, role: values.deviceRole, values: values
    )
    let payload = try JSONEncoder().encode(marker)
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
          SecretSyncLiveEvidence.self, from: existingPayload
        ) == marker
      else { throw error }
    }
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
        try SecretSyncLiveCleanupPlan.requireAuthorized(expected, values: values)
        aRecordIDs = try await ledger.checkpointCleanupPrerequisites(
          including: expected
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
      try SecretSyncLiveCleanupPlan.requireAuthorized(aRecordIDs, values: values)
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

@Suite("SecretSync live proof configuration contract")
struct SecretSyncLiveCloudKitProofConfigurationTests {
  @Test("normal prompt-free runs remain explicitly non-proof")
  func disabledIsNotProof() {
    #expect(SecretSyncLiveCloudKitProofConfiguration.load(environment: [:]) == .disabled)
  }

  @Test("partial live opt-in fails closed instead of becoming a skip")
  func partialOptInIsInvalid() {
    let configuration = SecretSyncLiveCloudKitProofConfiguration.load(
      environment: [SecretSyncLiveCloudKitProofConfiguration.optInKey: "1"]
    )
    #expect(configuration == .invalid(.operatorAttestationMissing))
  }

  @Test("role phase and distinct device evidence are mandatory")
  func externalRolePhaseBoundary() {
    var environment = completeEnvironment(role: "B", phase: "stage")
    #expect(
      SecretSyncLiveCloudKitProofConfiguration.load(
        environment: environment, runtimePlatform: .iPhone
      )
        == .invalid(.rolePhaseMismatch)
    )
    environment = completeEnvironment(role: "B", phase: "verify")
    if case .configured(let values) =
      SecretSyncLiveCloudKitProofConfiguration.load(
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
    let url = directory.appendingPathComponent("ledger.json")
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let first = try SecretSyncLiveCleanupLedger(url: url, namespace: namespace)
    let second = try SecretSyncLiveCleanupLedger(url: url, namespace: namespace)
    try await first.recordBeforeSave(
      CKRecord.ID(recordName: "one", zoneID: SecretSyncCloudKitZones.payloadZoneID)
    )
    try await second.recordBeforeSave(
      CKRecord.ID(recordName: "two", zoneID: SecretSyncCloudKitZones.payloadZoneID)
    )
    #expect(Set(try await first.exactRecordIDs().map(\.recordName)) == ["one", "two"])
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
      SecretSyncLiveCloudKitProofConfiguration.load(
        environment: completeEnvironment(role: "A", phase: "credential"),
        runtimePlatform: .mac
      )
    else {
      Issue.record("complete proof configuration must load")
      return
    }
    let kinds = [
      "agreement-verifier", "credential", "phase-credential", "phase-verify",
      "phase-backgroundDenied", "candidate", "manifest", "phase-stage", "cas",
      "phase-conditionalHead", "phase-revoke", "phase-offline", "phase-recovery",
      "phase-rotation", "phase-restart", "phase-audit", "phase-cleanup",
    ]
    for role in SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases {
      for kind in kinds {
        let recordID = try SecretSyncLiveArtifactRecordID.make(
          kind: kind, role: role, values: values
        )
        #expect(recordID.zoneID == SecretSyncCloudKitZones.controlZoneID)
        #expect(recordID.zoneID != CKRecordZone.default().zoneID)
      }
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
        SecretSyncLiveCloudKitProofConfiguration.load(
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
        SecretSyncLiveCloudKitProofConfiguration.load(
          environment: environment, runtimePlatform: .unsupported
        ) == .invalid(.matrixPlatformMismatch)
      )
      var substituted = environment
      substituted[SecretSyncLiveCloudKitProofConfiguration.roleKey]
        = role == .a ? "B" : "A"
      #expect(
        SecretSyncLiveCloudKitProofConfiguration.load(
          environment: substituted,
          runtimePlatform: role == .a ? .iPhone : .mac
        ) == .invalid(.hostLaunchGrantBindingMismatch)
      )
    }
    #expect(digests.count == 3)

    var wrongKey = completeEnvironment(role: "A", phase: "credential")
    wrongKey[SecretSyncLiveCloudKitProofConfiguration.hostAuthorityPublicKeyKey]
      = hostAuthority(seed: 2).publicKey.x963Representation.base64EncodedString()
    #expect(
      SecretSyncLiveCloudKitProofConfiguration.load(
        environment: wrongKey, runtimePlatform: .mac
      ) == .invalid(.hostLaunchGrantSignatureInvalid)
    )
    let expired = completeEnvironment(
      role: "A", phase: "credential", expiresAtUnixSeconds: 100
    )
    #expect(
      SecretSyncLiveCloudKitProofConfiguration.load(
        environment: expired, runtimePlatform: .mac,
        now: Date(timeIntervalSince1970: 101)
      ) == .invalid(.hostLaunchGrantExpired)
    )
  }

  @Test("launch grant ledger rejects nonce replay and wrong credential binding")
  func launchGrantReplayAndCredentialBinding() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-grant-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let ledger = try SecretSyncLiveCleanupLedger(
      url: directory.appendingPathComponent("ledger.json"), namespace: namespace
    )
    let nonce = UUID()
    let credentialEnvironment = completeEnvironment(
      role: "A", phase: "credential", nonce: nonce,
      expiresAtUnixSeconds: 4_000_000_000
    )
    let credentialValues = try #require(configured(
      credentialEnvironment, runtimePlatform: .mac
    ))
    try await ledger.admitLaunchGrant(values: credentialValues)
    await #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay) {
      try await ledger.admitLaunchGrant(values: credentialValues)
    }

    let replayEnvironment = completeEnvironment(
      role: "A", phase: "credential", nonce: nonce,
      expiresAtUnixSeconds: 4_000_000_001
    )
    let replayValues = try #require(configured(
      replayEnvironment, runtimePlatform: .mac
    ))
    await #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay) {
      try await ledger.admitLaunchGrant(values: replayValues)
    }

    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await ledger.storeCredentialForCleanup(credential, role: .a)
    #expect(try await ledger.credentialIDForCleanup(role: .a) == credential.credentialID)
    let wrongBinding = try #require(configured(
      completeEnvironment(
        role: "A", phase: "stage",
        credentialBindingDigest: Data(repeating: 0xFE, count: 32)
      ), runtimePlatform: .mac
    ))
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.launchGrantCredentialMismatch
    ) {
      try await ledger.admitLaunchGrant(values: wrongBinding)
    }
    let correctBinding = try #require(configured(
      completeEnvironment(
        role: "A", phase: "stage",
        credentialBindingDigest: SecretSyncLiveCredentialBinding.digest(credential)
      ), runtimePlatform: .mac
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
    guard case .configured(let values) =
      SecretSyncLiveCloudKitProofConfiguration.load(
        environment: completeEnvironment(role: "A", phase: "cleanup"),
        runtimePlatform: .mac
      )
    else {
      Issue.record("complete cleanup configuration must load")
      return
    }
    let headID = SecretSyncHeadCAS.recordID(for: SecretScopeID(
      UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    ))
    let artifactID = try SecretSyncLiveArtifactRecordID.make(
      kind: "manifest", role: .a, values: values
    )
    let payloadID = CKRecord.ID(
      recordName: "payload-record", zoneID: values.payloadZoneID
    )
    let manifest = [
      SecretSyncLiveRecordReference(
        recordName: payloadID.recordName, zoneName: payloadID.zoneID.zoneName
      )
    ]
    let exact = try SecretSyncLiveCleanupPlan.authorizedRecordIDs(
      manifest: manifest, artifactIDs: [artifactID], headID: headID,
      values: values
    )
    #expect(Set(exact) == Set([artifactID, payloadID, headID]))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-cleanup-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try SecretSyncLiveCleanupLedger(
      url: directory.appendingPathComponent("ledger.json"),
      namespace: values.runNamespace
    )
    _ = try await ledger.checkpointCleanupPrerequisites(including: exact)
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
      #expect(throws: SecretSyncLiveCloudKitProofConfigurationError.unauthorizedArtifactZone) {
        _ = try SecretSyncLiveCleanupPlan.authorizedRecordIDs(
          manifest: corrupted, artifactIDs: [artifactID], headID: headID,
          values: values
        )
      }
    }
    #expect(await database.deleteInvocationCount == 2)
  }

  @Test("cleanup retries only unresolved exact IDs after partial and verification loss")
  func cleanupRetrySemantics() async throws {
    let values = try #require(configured(
      completeEnvironment(role: "A", phase: "cleanup"), runtimePlatform: .mac
    ))
    let control = CKRecord.ID(
      recordName: "control", zoneID: values.controlZoneID
    )
    let payload = CKRecord.ID(
      recordName: "payload", zoneID: values.payloadZoneID
    )
    let alreadyAbsent = CKRecord.ID(
      recordName: "already-absent", zoneID: values.payloadZoneID
    )
    let exact = [control, payload, alreadyAbsent]

    let partialDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-partial-cleanup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: partialDirectory) }
    let partialLedger = try SecretSyncLiveCleanupLedger(
      url: partialDirectory.appendingPathComponent("ledger.json"),
      namespace: values.runNamespace
    )
    let partialDatabase = SecretSyncLiveArtifactDatabaseFake()
    await partialDatabase.seed(recordIDs: [control, payload])
    await partialDatabase.setDeleteFailures([payload])
    let firstAttempt = try await partialLedger.checkpointCleanupPrerequisites(
      including: exact
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
    let lossLedger = try SecretSyncLiveCleanupLedger(
      url: lossDirectory.appendingPathComponent("ledger.json"),
      namespace: values.runNamespace
    )
    let lossDatabase = SecretSyncLiveArtifactDatabaseFake()
    await lossDatabase.seed(recordIDs: [control, payload])
    await lossDatabase.failNextAbsenceVerification()
    let lossAttempt = try await lossLedger.checkpointCleanupPrerequisites(
      including: [control, payload]
    )
    await #expect(
      throws: SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    ) {
      try await SecretSyncLiveCleanupPlan.deleteAndVerify(
        lossAttempt, values: values, database: lossDatabase, ledger: lossLedger
      )
    }
    #expect(Set(try await lossLedger.exactRecordIDs()) == Set([control, payload]))
    let lossRetry = try #require(try await lossLedger.preparedCleanupRecordIDs())
    try await SecretSyncLiveCleanupPlan.deleteAndVerify(
      lossRetry, values: values, database: lossDatabase, ledger: lossLedger
    )
    #expect(try await lossLedger.exactRecordIDs().isEmpty)
  }

  @Test("A cleanup entry retries from its frozen checkpoint without prerequisite reloads")
  func cleanupEntryPointResumesFrozenSet() async throws {
    let values = try #require(configured(
      completeEnvironment(role: "A", phase: "cleanup"), runtimePlatform: .mac
    ))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-entry-a-cleanup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try SecretSyncLiveCleanupLedger(
      url: directory.appendingPathComponent("ledger.json"),
      namespace: values.runNamespace
    )
    let credential = try SecretSyncLiveAttestationFixture.make().evidence.credential
    try await ledger.storeCredentialForCleanup(credential, role: .a)
    let exact = [
      CKRecord.ID(recordName: "control", zoneID: values.controlZoneID),
      CKRecord.ID(recordName: "payload", zoneID: values.payloadZoneID),
    ]
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
    let ledger = try SecretSyncLiveCleanupLedger(
      url: directory.appendingPathComponent("ledger.json"),
      namespace: values.runNamespace
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
          try await SecretSyncLiveCleanupMarkerStore.publishOrValidate(
            marker, values: values, database: database, ledger: ledger
          )
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
        try await SecretSyncLiveCleanupMarkerStore.publishOrValidate(
          marker, values: values, database: database, ledger: ledger
        )
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

  private func completeEnvironment(
    role: String,
    phase: String,
    nonce: UUID = UUID(),
    authoritySeed: UInt8 = 1,
    credentialBindingDigest: Data? = nil,
    expiresAtUnixSeconds: Int64 = 4_000_000_000
  ) -> [String: String] {
    let parsedRole = SecretSyncLiveCloudKitProofConfiguration.DeviceRole(rawValue: role) ?? .a
    let parsedPhase = SecretSyncLiveCloudKitProofConfiguration.Phase(rawValue: phase) ?? .credential
    let binding = parsedPhase == .credential
      ? nil
      : credentialBindingDigest ?? Data(repeating: parsedRole == .a ? 0xA1 : 0xB1, count: 32)
    let manifest = SecretSyncLiveHostLaunchGrant.Manifest(
      version: 1,
      runNamespace: "u7-00112233-4455-6677-8899-aabbccddeeff",
      role: parsedRole, phase: parsedPhase,
      platform: SecretSyncLivePlatformMatrix.expectedPlatform(for: parsedRole),
      nonce: nonce, expiresAtUnixSeconds: expiresAtUnixSeconds,
      credentialBindingDigest: binding
    )
    let authority = hostAuthority(seed: authoritySeed)
    let body = try! SecretSyncLiveHostLaunchGrantVerifier.canonicalManifestBytes(manifest)
    let signature = try! authority.signature(for: body).derRepresentation
    let grant = SecretSyncLiveHostLaunchGrant(
      manifest: manifest, signature: signature
    )
    let grantBytes = try! JSONEncoder().encode(grant)
    return [
      SecretSyncLiveCloudKitProofConfiguration.optInKey: "1",
      SecretSyncLiveCloudKitProofConfiguration.attestationKey:
        "AUTHORIZED_U7_HOST_LAUNCH_GRANT",
      SecretSyncLiveCloudKitProofConfiguration.namespaceKey:
        "u7-00112233-4455-6677-8899-aabbccddeeff",
      SecretSyncLiveCloudKitProofConfiguration.roleKey: role,
      SecretSyncLiveCloudKitProofConfiguration.phaseKey: phase,
      SecretSyncLiveCloudKitProofConfiguration.ledgerPathKey:
        "/tmp/u7-live-proof-ledger.json",
      SecretSyncLiveCloudKitProofConfiguration.hostAuthorityPublicKeyKey:
        authority.publicKey.x963Representation.base64EncodedString(),
      SecretSyncLiveCloudKitProofConfiguration.hostLaunchGrantKey:
        grantBytes.base64EncodedString(),
    ]
  }

  private func hostAuthority(seed: UInt8) -> P256.Signing.PrivateKey {
    var raw = Data(repeating: 0, count: 32)
    raw[31] = seed
    return try! P256.Signing.PrivateKey(rawRepresentation: raw)
  }

  private func configured(
    _ environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform
  ) -> SecretSyncLiveCloudKitProofConfiguration.Values? {
    guard case .configured(let values) = SecretSyncLiveCloudKitProofConfiguration.load(
      environment: environment, runtimePlatform: runtimePlatform
    ) else { return nil }
    return values
  }
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
  @Test("one external role executes exactly one fail-closed proof phase")
  func externalPhase() async throws {
    let values = try requiredConfiguration()
    let ledger = try SecretSyncLiveCleanupLedger(
      url: values.ledgerURL, namespace: values.runNamespace
    )
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
  }

  private func proveHardwareCustody(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    guard SecretSyncSecureEnclaveCustody.hardwareAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }
    let custody = SecretSyncSecureEnclaveCustody()
    if values.deviceRole == .a {
      try await provisionAgreementVerifiers(values, ledger: ledger)
    }
    let verifier = try await loadArtifact(
      SecretSyncLiveAgreementVerifierPublic.self, kind: "agreement-verifier",
      role: values.deviceRole, values: values
    )
    let generation = try await custody.createCredential(for: TrustedDeviceID(UUID()))
    // Deliberately retain the exact Keychain handles until this role's cleanup
    // phase. A/B still need them to unwrap and C needs its key to prove reject.
    let evidence = try await verifyHardwareProof(
      custody: custody, generation: generation,
      agreementVerifierPublicKey: verifier.publicKey, values: values
    )
    try await saveArtifact(
      evidence, kind: "credential", role: values.deviceRole,
      values: values, ledger: ledger
    )
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
      signingHandleID: generation.signingHandle.rawValue,
      agreementHandleID: generation.agreementHandle.rawValue,
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
    try await requirePhase(.backgroundDenied, role: .a, values: values)
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
    try await requirePhase(.credential, role: .a, values: values)
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
    try await requirePhase(.stage, role: .a, values: values)
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
          privateKeyHandle: KeyAgreementPrivateKeyHandle(credential.agreementHandleID),
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
      privateKeyHandle: KeyAgreementPrivateKeyHandle(credential.agreementHandleID),
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
    try await requirePhase(.offline, role: .a, values: values)
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
    try await requirePhase(.rotation, role: .a, values: values)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    _ = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    try await complete(.restart, values: values, ledger: ledger)
  }

  private func verifyRecoveryRotation(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await requirePhase(.recovery, role: .a, values: values)
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
        try await requirePhase(.audit, role: .a, values: values)
        try await requirePhase(.cleanup, role: .b, values: values)
        try await requirePhase(.cleanup, role: .c, values: values)
      },
      removeCredential: { credentialID in
        try await SecretSyncSecureEnclaveCustody().removeCredentialForPhysicalProof(
          credentialID
        )
      },
      publishOrValidateMarker: { marker in
        try await SecretSyncLiveCleanupMarkerStore.publishOrValidate(
          marker, values: values, database: database, ledger: ledger
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
    try await requirePhase(.restart, role: .a, values: values)
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
      guard try P256.KeyAgreement.PrivateKey(rawRepresentation: verifierPrivateKey)
          .publicKey.x963Representation == verifierPublic.publicKey,
        try SecretSyncLiveAttestation.verify(
          credential, namespace: values.runNamespace, role: role,
          expectedLaunchGrantDigest: credential.launchGrantDigest,
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
      let proof = try await loadArtifact(
        SecretSyncLiveEvidence.self, kind: "phase-verify", role: role,
        values: values
      )
      let expected: SecretSyncLiveEvidence.Operation = role == .c ? .deny : .authorize
      guard proof.operation == expected, proof.resultCode == .passed else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
    }
    try SecretSyncLiveCredentialDistinctness.require(credentialEvidence)
    let floor = try await ledger.protectedCommitment()
    let offline = try await loadArtifact(
      SecretSyncLiveEvidence.self, kind: "phase-offline", role: .a,
      values: values
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
    let recoveryProof = try await loadArtifact(
      SecretSyncLiveEvidence.self, kind: "phase-recovery", role: .a,
      values: values
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
    let rotationProof = try await loadArtifact(
      SecretSyncLiveEvidence.self, kind: "phase-rotation", role: .a,
      values: values
    )
    guard rotationProof.operation == .recoveryRotationCustodyStaged,
      rotationProof.productionSeam == rotation.seam,
      rotationProof.outcomeDigest == rotation.digest
    else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
    try await complete(.configuration, values: values, ledger: ledger)
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
      freshnessCommitment: SecretBootstrapFreshnessCommitment(
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
    try await saveArtifact(
      evidence, kind: "phase-\(values.phase.rawValue)", role: values.deviceRole,
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
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) async throws {
    _ = try await loadArtifact(
      SecretSyncLiveEvidence.self, kind: "phase-\(phase.rawValue)",
      role: role, values: values
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
      credential: credential, signingHandleID: U7UUID.byte(0xA8),
      agreementHandleID: U7UUID.byte(0xA9), possessionTranscript: transcriptValue,
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
      signingHandleID: evidence.signingHandleID,
      agreementHandleID: evidence.agreementHandleID,
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
      signingHandleID: evidence.signingHandleID,
      agreementHandleID: evidence.agreementHandleID,
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

private enum SecretSyncLiveArtifactFakeError: Error {
  case exists
  case postSaveCrash
}
