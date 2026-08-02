import CloudKit
import ConvergenceKit
@_spi(SecretSyncPhysicalProof) @testable import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
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
      ]
    )
  }

  static func verify(
    _ evidence: SecretSyncLiveCredentialEvidence,
    namespace: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    credentialRecordName: String,
    verifierRecordName: String,
    agreementVerifierPrivateKey: Data
  ) throws -> Bool {
    let transcript = try evidence.possessionTranscript.productionValue()
    guard transcript.deviceID == evidence.credential.deviceID,
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
      SecretSyncLiveCloudKitProofConfiguration.load(environment: environment)
        == .invalid(.rolePhaseMismatch)
    )
    environment[SecretSyncLiveCloudKitProofConfiguration.phaseKey] = "verify"
    if case .configured(let values) =
      SecretSyncLiveCloudKitProofConfiguration.load(environment: environment)
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
        environment: completeEnvironment(role: "A", phase: "credential")
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

  @Test("canonical credential attestation rejects every proof mutation")
  func completeAttestationVerification() throws {
    let fixture = try SecretSyncLiveAttestationFixture.make()
    #expect(
      try SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
        credentialRecordName: fixture.credentialRecordName,
        verifierRecordName: fixture.verifierRecordName,
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
    for mutation in SecretSyncLiveAttestationFixture.Mutation.allCases {
      #expect(
        try !SecretSyncLiveAttestation.verify(
          fixture.mutated(mutation), namespace: fixture.namespace, role: .a,
          credentialRecordName: fixture.credentialRecordName,
          verifierRecordName: fixture.verifierRecordName,
          agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
        ), "mutation must reject: \(mutation)"
      )
    }
    #expect(
      try !SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
        credentialRecordName: fixture.credentialRecordName + "-tampered",
        verifierRecordName: fixture.verifierRecordName,
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
    #expect(
      try !SecretSyncLiveAttestation.verify(
        fixture.evidence, namespace: fixture.namespace, role: .a,
        credentialRecordName: fixture.credentialRecordName,
        verifierRecordName: fixture.verifierRecordName + "-tampered",
        agreementVerifierPrivateKey: fixture.verifier.rawRepresentation
      )
    )
  }

  private func completeEnvironment(role: String, phase: String) -> [String: String] {
    [
      SecretSyncLiveCloudKitProofConfiguration.optInKey: "1",
      SecretSyncLiveCloudKitProofConfiguration.attestationKey: "AUTHORIZED_U7_FIXED_MATRIX",
      SecretSyncLiveCloudKitProofConfiguration.namespaceKey:
        "u7-00112233-4455-6677-8899-aabbccddeeff",
      SecretSyncLiveCloudKitProofConfiguration.roleKey: role,
      SecretSyncLiveCloudKitProofConfiguration.phaseKey: phase,
      SecretSyncLiveCloudKitProofConfiguration.ledgerPathKey:
        "/tmp/u7-live-proof-ledger.json",
    ]
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
    try await requirePreexistingZones(values)
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
    try await complete(.authorize, values: values, ledger: ledger)
  }

  private func verifyOfflineFloor(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    _ = try await loadArtifact(
      SecretSyncLiveCASResult.self, kind: "cas", role: .a, values: values
    )
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    let entry = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    try SecretPolicyValidator.validateBootstrapFreshness(
      localCommit: entry.commit,
      against: commitment(entry.commit)
    )
    try await complete(.offlineFloor, values: values, ledger: ledger)
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
    let descriptor = try #require(entry.records.signedPolicy.policy.recoveryRecipient)
    let evidence = try BlindRecoveryConfirmationEvidence(
      recoveryRecipientID: descriptor.recoveryRecipientID,
      challengeID: UUID(),
      evidenceBytes: Data("operator-confirmed".utf8)
    )
    _ = try BreakGlassRecoveryRequest(
      requestID: UUID(), scopeID: entry.commit.scopeID,
      recoveryRecipientID: descriptor.recoveryRecipientID,
      sealedGenerationID: entry.commit.generationID,
      expectedFreshnessCommitment: commitment(entry.commit),
      blindConfirmation: evidence
    )
    try await complete(.recovery, values: values, ledger: ledger)
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
    let current = try #require(entry.records.signedPolicy.policy.recoveryRecipient)
    let replacement = try liveRecoveryDescriptor()
    let confirmation = try BlindRecoveryConfirmationEvidence(
      recoveryRecipientID: replacement.recoveryRecipientID,
      challengeID: UUID(), evidenceBytes: Data("operator-confirmed-rotation".utf8)
    )
    _ = try RecoveryRotationRequest(
      requestID: UUID(), scopeID: entry.commit.scopeID,
      currentRecoveryRecipientID: current.recoveryRecipientID,
      replacementRecoveryRecipient: replacement,
      currentGenerationID: entry.commit.generationID,
      replacementGenerationID: SecretGenerationID(UUID()),
      expectedFreshnessCommitment: commitment(entry.commit),
      blindConfirmation: confirmation
    )
    try await complete(.recovery, values: values, ledger: ledger)
  }

  private func liveRecoveryDescriptor() throws -> RecoveryRecipientDescriptor {
    let agreement = P256.KeyAgreement.PrivateKey()
    let signing = P256.Signing.PrivateKey()
    return try RecoveryRecipientDescriptor(
      recoveryRecipientID: UUID(),
      keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: RecoveryRecipientDescriptor.agreementAlgorithmIdentifier,
        keyIdentifier: Data("u7-rotation-agreement".utf8),
        publicKeyBytes: agreement.publicKey.x963Representation
      ),
      authorizationSigningPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: RecoveryRecipientDescriptor.authorizationSigningAlgorithmIdentifier,
        keyIdentifier: Data("u7-rotation-signing".utf8),
        publicKeyBytes: signing.publicKey.x963Representation
      )
    )
  }

  private func cleanup(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let credential = try await loadArtifact(
      SecretSyncLiveCredentialEvidence.self, kind: "credential",
      role: values.deviceRole, values: values
    )
    if values.deviceRole == .a {
      try await requirePhase(.audit, role: .a, values: values)
      try await requirePhase(.cleanup, role: .b, values: values)
      try await requirePhase(.cleanup, role: .c, values: values)
    }
    try await SecretSyncSecureEnclaveCustody().removeCredentialForPhysicalProof(
      credential.credential.credentialID
    )
    guard values.deviceRole == .a else {
      try await complete(
        .cleanup, relation: .none, values: values, ledger: ledger
      )
      return
    }
    let manifest = try await loadArtifact(
      [SecretSyncLiveRecordReference].self, kind: "manifest", role: .a,
      values: values
    )
    var exactIDs = manifest.map {
      CKRecord.ID(
        recordName: $0.recordName,
        zoneID: CKRecordZone.ID(
          zoneName: $0.zoneName, ownerName: CKCurrentUserDefaultName
        )
      )
    }
    exactIDs.append(contentsOf: try proofArtifactIDs(values: values))
    exactIDs = Array(Set(exactIDs))
    let database = CKContainer(identifier: values.containerIdentifier).privateCloudDatabase
    var unresolved: [CKRecord.ID] = []
    for ids in Dictionary(grouping: exactIDs, by: \.zoneID).values {
      let result: (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
      )
      do {
        result = try await database.modifyRecords(
          saving: [], deleting: ids,
          savePolicy: .ifServerRecordUnchanged, atomically: false
        )
      } catch {
        unresolved.append(contentsOf: ids)
        continue
      }
      for id in ids {
        guard case .success? = result.deleteResults[id] else {
          unresolved.append(id)
          continue
        }
      }
    }
    try await ledger.retainUnresolved(unresolved)
    guard unresolved.isEmpty else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unresolvedCleanupRecords
    }
    try await ledger.complete(
      phase: .cleanup, role: .a,
      evidence: SecretSyncLiveEvidence(
        timestamp: Date(), deviceRole: .a, operation: .cleanup,
        resultCode: .passed, headRelation: .none
      )
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
    var evidenceIDs = Set<String>()
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
      guard evidenceIDs.insert(credential.evidenceID).inserted,
        try P256.KeyAgreement.PrivateKey(rawRepresentation: verifierPrivateKey)
          .publicKey.x963Representation == verifierPublic.publicKey,
        try SecretSyncLiveAttestation.verify(
          credential, namespace: values.runNamespace, role: role,
          credentialRecordName: try artifactRecordID(
            kind: "credential", role: role, values: values
          ).recordName,
          verifierRecordName: try artifactRecordID(
            kind: "agreement-verifier", role: role, values: values
          ).recordName,
          agreementVerifierPrivateKey: verifierPrivateKey
        )
      else { throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit }
      let proof = try await loadArtifact(
        SecretSyncLiveEvidence.self, kind: "phase-verify", role: role,
        values: values
      )
      let expected: SecretSyncLiveEvidence.Operation = role == .c ? .deny : .authorize
      guard proof.operation == expected, proof.resultCode == .passed else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
    }
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
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    let evidence = SecretSyncLiveEvidence(
      timestamp: Date(), deviceRole: values.deviceRole, operation: operation,
      resultCode: .passed, headRelation: relation
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

private struct SecretSyncLiveRecordingDatabase: CloudKitDatabaseProtocol {
  let database: CKDatabase
  let ledger: SecretSyncLiveCleanupLedger

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
    try await database.fetch(withRecordIDs: ids)
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
  enum Mutation: CaseIterable { case signingChallenge, signingProof, agreementChallenge
    case agreementProof, attestationChallenge, attestationProof }

  let namespace: String
  let credentialRecordName: String
  let verifierRecordName: String
  let verifier: P256.KeyAgreement.PrivateKey
  let evidence: SecretSyncLiveCredentialEvidence

  static func make() throws -> SecretSyncLiveAttestationFixture {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
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
      namespace: namespace, credentialRecordName: credentialRecordName,
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

private actor SecretSyncLiveArtifactDatabaseFake: CloudKitDatabaseProtocol {
  private(set) var savePolicies: [CKModifyRecordsOperation.RecordSavePolicy] = []
  private(set) var zoneMutationCount = 0
  private var records: [CKRecord.ID: CKRecord] = [:]

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
    return (saves, Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
  }

  func fetch(
    withRecordIDs ids: [CKRecord.ID]
  ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
    Dictionary(uniqueKeysWithValues: ids.compactMap { id in
      records[id].map { (id, .success($0)) }
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

private enum SecretSyncLiveArtifactFakeError: Error { case exists }
