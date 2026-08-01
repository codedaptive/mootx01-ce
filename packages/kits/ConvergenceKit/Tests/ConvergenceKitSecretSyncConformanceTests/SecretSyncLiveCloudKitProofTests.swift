import CloudKit
import ConvergenceKit
import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import Foundation
import Testing

@Suite("SecretSync live proof configuration contract")
struct SecretSyncLiveCloudKitProofConfigurationTests {
  @Test("normal prompt-free runs remain explicitly non-proof")
  func disabledIsNotProof() {
    let configuration = SecretSyncLiveCloudKitProofConfiguration.load(environment: [:])
    #expect(configuration == .disabled)
  }

  @Test("partial live opt-in fails closed instead of becoming a skip")
  func partialOptInIsInvalid() {
    let configuration = SecretSyncLiveCloudKitProofConfiguration.load(
      environment: [SecretSyncLiveCloudKitProofConfiguration.optInKey: "1"]
    )
    #expect(configuration == .invalid(.operatorAttestationMissing))
  }

  @Test("canonical private database and exact zones are frozen")
  func canonicalBoundary() throws {
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let configuration = SecretSyncLiveCloudKitProofConfiguration.load(
      environment: [
        SecretSyncLiveCloudKitProofConfiguration.optInKey: "1",
        SecretSyncLiveCloudKitProofConfiguration.attestationKey:
          "AUTHORIZED_U7_FIXED_MATRIX",
        SecretSyncLiveCloudKitProofConfiguration.namespaceKey: namespace,
        SecretSyncLiveCloudKitProofConfiguration.roleKey: "A",
        SecretSyncLiveCloudKitProofConfiguration.phaseKey: "conditionalHead",
      ]
    )
    let values: SecretSyncLiveCloudKitProofConfiguration.Values
    switch configuration {
    case .configured(let loaded): values = loaded
    default: Issue.record("complete explicit configuration must load"); return
    }

    #expect(values.containerIdentifier == "iCloud.com.codedaptive.simplemachines")
    #expect(values.databaseScope == .private)
    #expect(values.controlZoneID.zoneName == "moot-secret-control-v1")
    #expect(values.payloadZoneID.zoneName == "moot-secret-payload-v1")
    #expect(values.runNamespace == namespace)
  }
}

@Suite(
  "SecretSync authorized live private-CloudKit proof",
  .serialized,
  .enabled(
    if: SecretSyncLiveCloudKitProofConfiguration.isExplicitlyRequested,
    "Requires explicit authorized U7 operator configuration; a disabled leg is not proof"
  )
)
struct SecretSyncLiveCloudKitProofTests {
  @Test("immutable payload staging and conditional head CAS use exact-ID cleanup")
  func liveImmutableStageConditionalHeadAndCleanup() async throws {
    let values = try requiredConfiguration()
    let containerA = CKContainer(identifier: values.containerIdentifier)
    let containerB = CKContainer(identifier: values.containerIdentifier)
    let databaseA = containerA.privateCloudDatabase
    let databaseB = containerB.privateCloudDatabase
    let ledger = SecretSyncLiveCleanupLedger()
    let suite = try U7GoldenVectors.suite()
    let digester = try SecretSyncSHA256DigestProvider(suite: suite)
    let scopeID = try liveScopeID(values.runNamespace)
    let payloadRecord = try livePayloadRecord(scopeID: scopeID, digester: digester)
    let headRecord = try liveHeadRecord(
      scopeID: scopeID,
      epoch: 1,
      commitDigest: U7GoldenVectors.digest(0xA1),
      policyDigest: U7GoldenVectors.digest(0xA2)
    )
    await ledger.recordBeforeSave(payloadRecord.recordID)
    await ledger.recordBeforeSave(headRecord.recordID)

    do {
      try requireSuccess(
        try await databaseA.modifySecretSyncRecords(
          saving: [payloadRecord],
          digester: digester
        ),
        expectedID: payloadRecord.recordID
      )
      try requireSuccess(
        try await databaseA.modifySecretSyncRecords(
          saving: [headRecord],
          digester: digester
        ),
        expectedID: headRecord.recordID
      )

      let fetched = try await databaseA.fetch(withRecordIDs: [headRecord.recordID])
      let base = try fetchedRecord(fetched, id: headRecord.recordID)
      let candidateA = try detachedCopy(base)
      let candidateB = try detachedCopy(base)
      try applyHeadFields(
        to: candidateA,
        scopeID: scopeID,
        epoch: 2,
        commitDigest: U7GoldenVectors.digest(0xB1),
        policyDigest: U7GoldenVectors.digest(0xB2)
      )
      try applyHeadFields(
        to: candidateB,
        scopeID: scopeID,
        epoch: 2,
        commitDigest: U7GoldenVectors.digest(0xC1),
        policyDigest: U7GoldenVectors.digest(0xC2)
      )

      async let resultA = databaseA.modifySecretSyncRecords(
        saving: [candidateA],
        digester: digester
      )
      async let resultB = databaseB.modifySecretSyncRecords(
        saving: [candidateB],
        digester: digester
      )
      let outcomes = try await [resultA, resultB]
      let winnerCount = outcomes.filter { result in
        if case .success? = result.saveResults[headRecord.recordID] { return true }
        return false
      }.count
      #expect(winnerCount == 1)

      let finalHead = try #require(
        try await SecretSyncHeadCAS(database: databaseA, digester: digester)
          .currentHead(for: scopeID)
      )
      #expect(finalHead.policyEpoch == 2)
    } catch {
      try await cleanup(ledger: ledger, database: databaseA)
      throw error
    }
    try await cleanup(ledger: ledger, database: databaseA)
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

  private func liveScopeID(_ namespace: String) throws -> SecretScopeID {
    guard let value = UUID(uuidString: String(namespace.dropFirst(3))) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.invalidRunNamespace
    }
    return SecretScopeID(value)
  }

  private func livePayloadRecord(
    scopeID: SecretScopeID,
    digester: any SecretSyncDigesting
  ) throws -> CKRecord {
    let placeholder = try U7GoldenVectors.digest(0)
    let payload = try SealedPayload(
      recordDigest: placeholder,
      scopeID: scopeID,
      scopeSnapshotDigest: U7GoldenVectors.snapshotDigest,
      policyEpoch: 1,
      policyDigest: U7GoldenVectors.policyDigest,
      generationID: U7GoldenVectors.generationID,
      formatVersion: 1,
      ciphertextBytes: Data("u7-live-opaque-ciphertext".utf8)
    )
    let canonical = try payload.canonicalBytes()
    let digest = try digester.digest(canonicalBytes: canonical)
    _ = try SecretSyncCloudKitImmutableRecord(
      type: .sealedPayload,
      digest: digest,
      canonicalBytes: canonical,
      digester: digester
    )
    let record = CKRecord(
      recordType: SecretSyncCloudKitRecordType.sealedPayload.rawValue,
      recordID: CKRecord.ID(
        recordName: hex(digest.bytes),
        zoneID: SecretSyncCloudKitZones.payloadZoneID
      )
    )
    record["ss_canonical_bytes"] = canonical as NSData
    record["ss_record_digest"] = digest.bytes as NSData
    return record
  }

  private func liveHeadRecord(
    scopeID: SecretScopeID,
    epoch: UInt64,
    commitDigest: SecretRecordDigest,
    policyDigest: SecretRecordDigest
  ) throws -> CKRecord {
    var raw = scopeID.rawValue.uuid
    let scopeBytes = withUnsafeBytes(of: &raw) { Data($0) }
    let record = CKRecord(
      recordType: SecretSyncCloudKitRecordType.scopeHead.rawValue,
      recordID: CKRecord.ID(
        recordName: hex(scopeBytes),
        zoneID: SecretSyncCloudKitZones.controlZoneID
      )
    )
    try applyHeadFields(
      to: record,
      scopeID: scopeID,
      epoch: epoch,
      commitDigest: commitDigest,
      policyDigest: policyDigest
    )
    return record
  }

  private func applyHeadFields(
    to record: CKRecord,
    scopeID: SecretScopeID,
    epoch: UInt64,
    commitDigest: SecretRecordDigest,
    policyDigest: SecretRecordDigest
  ) throws {
    var raw = scopeID.rawValue.uuid
    record["ss_scope_id"] = withUnsafeBytes(of: &raw) { Data($0) } as NSData
    record["ss_policy_epoch"] = Data((0..<8).map { offset in
      UInt8(truncatingIfNeeded: epoch >> UInt64((7 - offset) * 8))
    }) as NSData
    record["ss_head_commit_digest"] = commitDigest.bytes as NSData
    record["ss_policy_digest"] = policyDigest.bytes as NSData
  }

  private func fetchedRecord(
    _ results: [CKRecord.ID: Result<CKRecord, any Error>],
    id: CKRecord.ID
  ) throws -> CKRecord {
    guard case .success(let record)? = results[id] else {
      throw SecretSyncCloudKitError.incompleteModifyResults
    }
    return record
  }

  private func detachedCopy(_ record: CKRecord) throws -> CKRecord {
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: record,
      requiringSecureCoding: true
    )
    guard let copy = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: CKRecord.self,
      from: data
    ) else {
      throw SecretSyncCloudKitError.invalidFieldSchema
    }
    return copy
  }

  private func requireSuccess(
    _ result: (
      saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
      deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ),
    expectedID: CKRecord.ID
  ) throws {
    guard result.saveResults.count == 1,
          case .success? = result.saveResults[expectedID],
          result.deleteResults.isEmpty else {
      throw SecretSyncCloudKitError.incompleteModifyResults
    }
  }

  private func cleanup(
    ledger: SecretSyncLiveCleanupLedger,
    database: CKDatabase
  ) async throws {
    let grouped = Dictionary(grouping: await ledger.exactRecordIDs(), by: \.zoneID)
    for ids in grouped.values {
      let result = try await database.modifyRecords(
        saving: [],
        deleting: ids,
        savePolicy: .ifServerRecordUnchanged,
        atomically: true
      )
      guard result.saveResults.isEmpty,
            Set(result.deleteResults.keys) == Set(ids),
            result.deleteResults.values.allSatisfy({ outcome in
              if case .success = outcome { return true }
              return false
            }) else {
        throw SecretSyncCloudKitError.incompleteModifyResults
      }
    }
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
