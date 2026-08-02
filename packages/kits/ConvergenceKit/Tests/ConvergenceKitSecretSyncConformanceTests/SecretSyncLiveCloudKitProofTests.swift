import CloudKit
import ConvergenceKit
@_spi(SecretSyncPhysicalProof) import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import CryptoKit
import Foundation
import Testing

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

  private func completeEnvironment(role: String, phase: String) -> [String: String] {
    [
      SecretSyncLiveCloudKitProofConfiguration.optInKey: "1",
      SecretSyncLiveCloudKitProofConfiguration.attestationKey: "AUTHORIZED_U7_FIXED_MATRIX",
      SecretSyncLiveCloudKitProofConfiguration.namespaceKey:
        "u7-00112233-4455-6677-8899-aabbccddeeff",
      SecretSyncLiveCloudKitProofConfiguration.roleKey: role,
      SecretSyncLiveCloudKitProofConfiguration.phaseKey: phase,
      SecretSyncLiveCloudKitProofConfiguration.deviceEvidenceKey:
        "device-00112233445566778899aabbccddeeff0011",
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
    try await ledger.admitDevice(role: values.deviceRole, evidenceID: values.deviceEvidenceID)

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
    let generation = try await custody.createCredential(for: TrustedDeviceID(UUID()))
    do {
      try await verifyHardwareProof(custody: custody, generation: generation)
      try await custody.removeCredentialForPhysicalProof(generation.credentialID)
      try await complete(.hardwareCustody, values: values, ledger: ledger)
    } catch {
      try? await custody.removeCredentialForPhysicalProof(generation.credentialID)
      throw error
    }
  }

  private func verifyHardwareProof(
    custody: SecretSyncSecureEnclaveCustody,
    generation: SecretSyncCustodyCredentialGeneration
  ) async throws {
    let transcript = try possessionTranscript(generation)
    let signingChallenge = try SecretSyncSigningProofChallenge(transcript: transcript)
    let agreement = try SecretSyncAgreementProofChallenge.create(transcript: transcript)
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
        challengeBytes: agreement.challenge.canonicalBytes
      )
    )
    guard
      try signingChallenge.verify(
        signing.proofBytes,
        publicKey: generation.signingPublicKey
      ),
      try agreement.verifier.verify(
        agreementProof.proofBytes,
        challenge: agreement.challenge,
        candidatePublicKey: generation.agreementPublicKey
      )
    else { throw SecretSyncCustodyError.invalidProof }
  }

  private func stageCompleteGraph(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.require(.backgroundDenied, role: .a)
    let fixture = try U7PolicyFixture.make(scopeID: scopeID(values))
    let context = try liveStore(values, ledger: ledger)
    try await context.store.appendStagedPolicy(fixture.entry)
    let rebuilt = try await context.store.reconstructPolicy(
      commitDigest: fixture.entry.commit.recordDigest
    )
    guard rebuilt == fixture.entry else {
      throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
    }
    try await complete(.immutableStage, values: values, ledger: ledger)
  }

  private func proveBackgroundDenial(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.require(.credential, role: .a)
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
    try await ledger.require(.stage, role: .a)
    let context = try liveStore(values, ledger: ledger)
    let entry = try #require(
      try await context.store.stagedPolicy(for: try scopeID(values), epoch: 1)
    )
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
    guard case .advanced = try await context.store.compareAndAdvance(precondition) else {
      throw SecretSyncCloudKitPolicyStoreError.conditionalWriteConflict
    }
    try await complete(.conditionalHead, values: values, ledger: ledger)
  }

  private func verifyCommittedGraph(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.requireDistinctABC()
    try await ledger.require(.conditionalHead, role: .a)
    try await ledger.require(.revoke, role: .c)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    let rebuilt = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    guard rebuilt.commit.recordDigest == head.commitDigest else {
      throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
    }
    try await complete(.reconstruct, values: values, ledger: ledger)
  }

  private func verifyOfflineFloor(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.require(.conditionalHead, role: .a)
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
    try await ledger.require(.credential, role: .c)
    try await complete(.deny, values: values, ledger: ledger)
  }

  private func verifyRecoveryBinding(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.require(.offline, role: .a)
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
    try await ledger.require(.rotation, role: .a)
    let context = try liveStore(values, ledger: ledger)
    let head = try #require(try await context.store.policyHead(for: try scopeID(values)))
    _ = try await context.store.reconstructPolicy(commitDigest: head.commitDigest)
    try await complete(.restart, values: values, ledger: ledger)
  }

  private func verifyRecoveryRotation(
    _ values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.require(.recovery, role: .a)
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
    try await ledger.require(.restart, role: .a)
    let database = CKContainer(identifier: values.containerIdentifier).privateCloudDatabase
    for ids in Dictionary(grouping: await ledger.exactRecordIDs(), by: \.zoneID).values {
      let result = try await database.modifyRecords(
        saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: true
      )
      guard Set(result.deleteResults.keys) == Set(ids) else {
        throw SecretSyncCloudKitError.incompleteModifyResults
      }
    }
    try await complete(.cleanup, values: values, ledger: ledger)
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
    _ generation: SecretSyncCustodyCredentialGeneration
  ) throws -> SecretSyncProofOfPossessionTranscript {
    let now = Date()
    return try SecretSyncProofOfPossessionTranscript(
      challengeID: UUID(), sessionID: UUID(),
      issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
      deviceID: generation.deviceID, credentialID: generation.credentialID,
      signingPublicKey: generation.signingPublicKey,
      agreementPublicKey: generation.agreementPublicKey,
      authorityCredentialID: DeviceCredentialID(UUID()),
      freshnessCommitment: SecretBootstrapFreshnessCommitment(
        scopeID: U7GoldenVectors.scopeID, latestPolicyEpoch: 1,
        headCommitDigest: U7GoldenVectors.digest(0xF1),
        policyDigest: U7GoldenVectors.digest(0xF2)
      )
    )
  }

  private func complete(
    _ operation: SecretSyncLiveEvidence.Operation,
    values: SecretSyncLiveCloudKitProofConfiguration.Values,
    ledger: SecretSyncLiveCleanupLedger
  ) async throws {
    try await ledger.complete(
      phase: values.phase,
      role: values.deviceRole,
      evidence: SecretSyncLiveEvidence(
        timestamp: Date(), deviceRole: values.deviceRole, operation: operation,
        resultCode: .passed, headRelation: .exact
      )
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
    try await database.modifyRecordZones(saving: zones, deleting: ids)
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
