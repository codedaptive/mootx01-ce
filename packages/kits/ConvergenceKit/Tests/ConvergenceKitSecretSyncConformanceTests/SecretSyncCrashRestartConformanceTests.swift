import CloudKit
import ConvergenceKit
import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import Foundation
import Testing

@Suite("SecretSync crash restart and conditional-head conformance")
struct SecretSyncCrashRestartConformanceTests {
  @Test("concurrent initial head writers produce one conditional winner")
  func concurrentHeadCAS() async throws {
    let database = U7ScriptedCloudKitDatabase()
    let first = try U7HeadRecord.make(epoch: 1, commit: 0x61, policy: 0x62)
    let second = try U7HeadRecord.make(epoch: 1, commit: 0x71, policy: 0x72)
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())

    async let a = attemptSave(first, database: database, digester: digester)
    async let b = attemptSave(second, database: database, digester: digester)
    let results = await [a, b]

    #expect(results.filter(\.self).count == 1)
    #expect(await database.conditionalAttemptCount == 2)
    let restarted = SecretSyncHeadCAS(database: database, digester: digester)
    let head = try #require(try await restarted.currentHead(for: U7GoldenVectors.scopeID))
    #expect(head.policyEpoch == 1)
    #expect([
      try U7GoldenVectors.digest(0x61),
      try U7GoldenVectors.digest(0x71),
    ].contains(head.commitDigest))
  }

  @Test("crash before immutable staging leaves no reconstructable candidate")
  func crashBeforeImmutableStaging() async throws {
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let fixture = try U7PolicyFixture.make()
    let database = U7ScriptedCloudKitDatabase()
    await database.failNextSaveBeforeCommit()
    let store = SecretSyncCloudKitPolicyStore(database: database, digester: digester)

    await #expect(throws: (any Error).self) {
      try await store.appendStagedPolicy(fixture.entry)
    }
    let restarted = SecretSyncCloudKitPolicyStore(database: database, digester: digester)
    #expect(try await restarted.stagedPolicy(for: fixture.entry.commit.scopeID, epoch: 1) == nil)
  }

  @Test("crash after staging preserves complete graph without authority")
  func crashAfterStagingBeforeCAS() async throws {
    let context = try await stagedContext()
    let restarted = SecretSyncCloudKitPolicyStore(
      database: context.database, digester: context.digester
    )

    #expect(try await restarted.policyHead(for: U7GoldenVectors.scopeID) == nil)
    #expect(
      try await restarted.reconstructPolicy(
        commitDigest: context.fixture.entry.commit.recordDigest
      ) == context.fixture.entry
    )
  }

  @Test("crash during CAS is classified from the durable production head")
  func crashDuringCAS() async throws {
    let context = try await stagedContext()
    await context.database.failNextSaveAfterCommit()

    await #expect(throws: (any Error).self) {
      _ = try await context.store.compareAndAdvance(
        U7PolicyFixture.precondition(context.fixture)
      )
    }
    let restarted = SecretSyncCloudKitPolicyStore(
      database: context.database, digester: context.digester
    )
    let head = try #require(try await restarted.policyHead(for: U7GoldenVectors.scopeID))
    #expect(head.commitDigest == context.fixture.entry.commit.recordDigest)
  }

  @Test("restart after accepted head reconstructs committed graph before receipt")
  func crashAfterAcceptedHeadBeforeReceipt() async throws {
    let context = try await stagedContext()
    let outcome = try await context.store.compareAndAdvance(
      U7PolicyFixture.precondition(context.fixture)
    )
    guard case .advanced = outcome else { Issue.record("initial CAS must advance"); return }
    let restarted = SecretSyncCloudKitPolicyStore(
      database: context.database, digester: context.digester
    )

    let committed = try await restarted.committedPolicy(
      for: U7GoldenVectors.scopeID, epoch: 1
    )
    #expect(committed?.commit == context.fixture.entry.commit)
    #expect(committed?.records.state == .committed)
    #expect(committed?.credentials == context.fixture.entry.credentials)
  }

  @Test("partial cross-zone graphs reject while unreferenced orphans authorize nothing")
  func partialAndOrphanGraphs() async throws {
    let partial = try await stagedContext()
    await partial.database.removeFirst(type: .sealedPayload)
    await #expect(throws: SecretSyncCloudKitPolicyStoreError.incompleteRecordSet) {
      _ = try await partial.store.reconstructPolicy(
        commitDigest: partial.fixture.entry.commit.recordDigest
      )
    }

    let orphaned = try await stagedContext()
    await orphaned.database.seedOrphan()
    let reconstructed = try await orphaned.store.reconstructPolicy(
      commitDigest: orphaned.fixture.entry.commit.recordDigest
    )
    #expect(reconstructed == orphaned.fixture.entry)
  }

  @Test("protected offline floor survives while missing restored and forked pins block")
  // The three offline outcomes share one exact commitment; separating them
  // would obscure that only protected-local equality changes admission.
  func protectedOfflineFloor() async throws {
    let commitment = try U7HeadRecord.commitment(
      epoch: 7,
      commit: 0x81,
      policy: 0x82
    )
    let offline = U7ScriptedCloudKitDatabase()
    await offline.setOffline(true)
    let transport = SecretSyncFreshnessTransport(database: offline)
    #expect(
      try await transport.normalPathCommitment(
        for: U7GoldenVectors.scopeID,
        authority: .protectedLocal(U7ProtectedHead(value: commitment))
      ) == commitment
    )

    await #expect(throws: SecretSyncFreshnessTransportError.rollbackOrRestoreMismatch) {
      _ = try await transport.normalPathCommitment(
        for: U7GoldenVectors.scopeID,
        authority: .protectedLocal(U7ProtectedHead(value: nil))
      )
    }
    await #expect(throws: SecretSyncFreshnessTransportError.rollbackOrRestoreMismatch) {
      _ = try await transport.normalPathCommitment(
        for: U7GoldenVectors.scopeID,
        authority: .protectedLocal(
          U7ProtectedHead(
            value: try U7HeadRecord.commitment(
              scopeID: SecretScopeID(U7UUID.byte(0x99)),
              epoch: 7,
              commit: 0x81,
              policy: 0x82
            )
          )
        )
      )
    }

    let forkedCloud = U7ScriptedCloudKitDatabase()
    await forkedCloud.seed(
      try U7HeadRecord.make(epoch: 7, commit: 0x91, policy: 0x92)
    )
    let forkTransport = SecretSyncFreshnessTransport(database: forkedCloud)
    await #expect(throws: SecretSyncFreshnessTransportError.forkDetected) {
      _ = try await forkTransport.normalPathCommitment(
        for: U7GoldenVectors.scopeID,
        authority: .protectedLocal(U7ProtectedHead(value: commitment))
      )
    }
  }

  private func attemptSave(
    _ record: CKRecord,
    database: U7ScriptedCloudKitDatabase,
    digester: any SecretSyncDigesting
  ) async -> Bool {
    do {
      let result = try await database.modifySecretSyncRecords(
        saving: [record],
        digester: digester
      )
      guard case .success = result.saveResults[record.recordID] else {
        return false
      }
      return true
    } catch {
      return false
    }
  }

  private func stagedContext() async throws -> (
    fixture: U7PolicyFixture,
    database: U7ScriptedCloudKitDatabase,
    digester: SecretSyncSHA256DigestProvider,
    store: SecretSyncCloudKitPolicyStore
  ) {
    let fixture = try U7PolicyFixture.make()
    let database = U7ScriptedCloudKitDatabase()
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let store = SecretSyncCloudKitPolicyStore(database: database, digester: digester)
    try await store.appendStagedPolicy(fixture.entry)
    return (fixture, database, digester, store)
  }
}

private struct U7ProtectedHead: SecretSyncProtectedHeadProviding {
  let value: SecretBootstrapFreshnessCommitment?

  func protectedHead(
    for scopeID: SecretScopeID
  ) async throws -> SecretBootstrapFreshnessCommitment {
    guard let value else { throw U7ScriptedCloudError.unavailable }
    return value
  }
}

private enum U7ScriptedCloudError: Error {
  case unavailable
}

private enum U7HeadRecord {
  static func make(
    epoch: UInt64,
    commit: UInt8,
    policy: UInt8
  ) throws -> CKRecord {
    var rawUUID = U7GoldenVectors.scopeID.rawValue.uuid
    let scopeBytes = withUnsafeBytes(of: &rawUUID) { Data($0) }
    let record = CKRecord(
      recordType: SecretSyncCloudKitRecordType.scopeHead.rawValue,
      recordID: CKRecord.ID(
        recordName: scopeBytes.map { String(format: "%02x", $0) }.joined(),
        zoneID: SecretSyncCloudKitZones.controlZoneID
      )
    )
    record["ss_scope_id"] = scopeBytes as NSData
    record["ss_policy_epoch"] = uint64(epoch) as NSData
    record["ss_head_commit_digest"] = try U7GoldenVectors.digest(commit).bytes as NSData
    record["ss_policy_digest"] = try U7GoldenVectors.digest(policy).bytes as NSData
    return record
  }

  static func commitment(
    scopeID: SecretScopeID = U7GoldenVectors.scopeID,
    epoch: UInt64,
    commit: UInt8,
    policy: UInt8
  ) throws -> SecretBootstrapFreshnessCommitment {
    try SecretBootstrapFreshnessCommitment(
      scopeID: scopeID,
      latestPolicyEpoch: epoch,
      headCommitDigest: U7GoldenVectors.digest(commit),
      policyDigest: U7GoldenVectors.digest(policy)
    )
  }

  private static func uint64(_ value: UInt64) -> Data {
    Data((0..<8).map { offset in
      UInt8(truncatingIfNeeded: value >> UInt64((7 - offset) * 8))
    })
  }
}

private actor U7ScriptedCloudKitDatabase: CloudKitDatabaseProtocol {
  private var records: [CKRecord.ID: CKRecord] = [:]
  private var offline = false
  private var failBefore = false
  private var failAfter = false
  private(set) var conditionalAttemptCount = 0

  func setOffline(_ value: Bool) { offline = value }
  func failNextSaveBeforeCommit() { failBefore = true }
  func failNextSaveAfterCommit() { failAfter = true }
  func seed(_ record: CKRecord) { records[record.recordID] = record }
  func removeFirst(type: SecretSyncCloudKitRecordType) {
    guard let id = records.first(where: { $0.value.recordType == type.rawValue })?.key else {
      return
    }
    records.removeValue(forKey: id)
  }
  func seedOrphan() {
    let id = CKRecord.ID(
      recordName: "unreferenced-u7-orphan",
      zoneID: SecretSyncCloudKitZones.payloadZoneID
    )
    records[id] = CKRecord(recordType: "U7UnreferencedOrphan", recordID: id)
  }

  func modifyRecords(
    saving recordsToSave: [CKRecord],
    deleting recordIDsToDelete: [CKRecord.ID],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
    atomically: Bool
  ) async throws -> (
    saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
    deleteResults: [CKRecord.ID: Result<Void, any Error>]
  ) {
    conditionalAttemptCount += 1
    if offline || failBefore {
      failBefore = false
      throw CKError(.networkFailure)
    }
    var saves: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
    for record in recordsToSave {
      if records[record.recordID] == nil {
        records[record.recordID] = record
        saves[record.recordID] = .success(record)
      } else {
        saves[record.recordID] = .failure(CKError(.serverRecordChanged))
      }
    }
    if failAfter {
      failAfter = false
      throw CKError(.networkFailure)
    }
    return (
      saves,
      Dictionary(uniqueKeysWithValues: recordIDsToDelete.map { ($0, .success(())) })
    )
  }

  func fetch(
    withRecordIDs recordIDs: [CKRecord.ID]
  ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
    if offline { throw CKError(.networkFailure) }
    return Dictionary(uniqueKeysWithValues: recordIDs.map { id in
      if let record = records[id] { return (id, .success(record)) }
      return (id, .failure(CKError(.unknownItem)))
    })
  }

  func fetchZoneChanges(
    inZoneWith zoneID: CKRecordZone.ID,
    since token: CKServerChangeToken?
  ) async throws -> CloudKitZoneChanges {
    if offline { throw CKError(.networkFailure) }
    return CloudKitZoneChanges(
      modifiedRecords: Array(records.values),
      deletedRecordIDs: [],
      changeToken: nil
    )
  }

  func modifyRecordZones(
    saving recordZonesToSave: [CKRecordZone],
    deleting recordZoneIDsToDelete: [CKRecordZone.ID]
  ) async throws -> (
    saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
    deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
  ) {
    (
      Dictionary(uniqueKeysWithValues: recordZonesToSave.map { ($0.zoneID, .success($0)) }),
      Dictionary(uniqueKeysWithValues: recordZoneIDsToDelete.map { ($0, .success(())) })
    )
  }

  func modifySubscriptions(
    saving subscriptionsToSave: [CKSubscription],
    deleting subscriptionIDsToDelete: [CKSubscription.ID]
  ) async throws -> (
    saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
    deleteResults: [CKSubscription.ID: Result<Void, any Error>]
  ) {
    (
      Dictionary(uniqueKeysWithValues: subscriptionsToSave.map { ($0.subscriptionID, .success($0)) }),
      Dictionary(uniqueKeysWithValues: subscriptionIDsToDelete.map { ($0, .success(())) })
    )
  }
}
