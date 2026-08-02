import CloudKit
import ConvergenceKit
import ConvergenceKitCloudKit
import Darwin
import Foundation

enum SecretSyncLiveCloudKitProofConfiguration: Sendable, Equatable {
  case disabled
  case invalid(SecretSyncLiveCloudKitProofConfigurationError)
  case configured(Values)

  struct Values: Sendable, Equatable {
    let containerIdentifier: String
    let databaseScope: CKDatabase.Scope
    let controlZoneID: CKRecordZone.ID
    let payloadZoneID: CKRecordZone.ID
    let runNamespace: String
    let deviceRole: DeviceRole
    let phase: Phase
    let ledgerURL: URL
  }

  enum DeviceRole: String, Codable, Sendable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
  }

  enum Phase: String, Sendable, CaseIterable {
    case credential
    case backgroundDenied
    case stage
    case conditionalHead
    case verify
    case offline
    case revoke
    case recovery
    case rotation
    case restart
    case audit
    case cleanup
  }

  static let optInKey = "MOOT_SECRET_SYNC_LIVE_PROOF"
  static let namespaceKey = "MOOT_SECRET_SYNC_RUN_NAMESPACE"
  static let roleKey = "MOOT_SECRET_SYNC_DEVICE_ROLE"
  static let phaseKey = "MOOT_SECRET_SYNC_PHASE"
  static let attestationKey = "MOOT_SECRET_SYNC_OPERATOR_ATTESTATION"
  static let ledgerPathKey = "MOOT_SECRET_SYNC_LEDGER_PATH"
  static let canonicalContainerIdentifier = "iCloud.com.codedaptive.simplemachines"

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    guard environment[optInKey] == "1" else { return .disabled }
    guard environment[attestationKey] == "AUTHORIZED_U7_FIXED_MATRIX" else {
      return .invalid(.operatorAttestationMissing)
    }
    guard let namespace = environment[namespaceKey], valid(namespace: namespace) else {
      return .invalid(.invalidRunNamespace)
    }
    guard let rawRole = environment[roleKey], let role = DeviceRole(rawValue: rawRole) else {
      return .invalid(.invalidDeviceRole)
    }
    guard let rawPhase = environment[phaseKey], let phase = Phase(rawValue: rawPhase) else {
      return .invalid(.invalidPhase)
    }
    guard let ledgerPath = environment[ledgerPathKey], ledgerPath.hasPrefix("/") else {
      return .invalid(.invalidLedgerPath)
    }
    guard phase.isAdmitted(for: role) else { return .invalid(.rolePhaseMismatch) }
    return .configured(
      Values(
        containerIdentifier: canonicalContainerIdentifier,
        databaseScope: .private,
        controlZoneID: SecretSyncCloudKitZones.controlZoneID,
        payloadZoneID: SecretSyncCloudKitZones.payloadZoneID,
        runNamespace: namespace,
        deviceRole: role,
        phase: phase,
        ledgerURL: URL(fileURLWithPath: ledgerPath)
      )
    )
  }

  static var isExplicitlyRequested: Bool {
    ProcessInfo.processInfo.environment[optInKey] == "1"
  }

  private static func valid(namespace: String) -> Bool {
    guard namespace.hasPrefix("u7-"), namespace.count <= 80 else { return false }
    let suffix = namespace.dropFirst(3)
    return UUID(uuidString: String(suffix)) != nil
  }

}

extension SecretSyncLiveCloudKitProofConfiguration.Phase {
  fileprivate func isAdmitted(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> Bool {
    switch self {
    case .credential, .verify, .cleanup: return true
    case .conditionalHead: return role == .a || role == .b
    case .stage, .offline, .backgroundDenied, .recovery, .rotation,
         .restart, .audit: return role == .a
    case .revoke: return role == .c
    }
  }
}

enum SecretSyncLiveCloudKitProofConfigurationError: Error, Sendable, Equatable {
  case operatorAttestationMissing
  case invalidRunNamespace
  case invalidDeviceRole
  case invalidPhase
  case invalidLedgerPath
  case rolePhaseMismatch
  case ledgerNamespaceMismatch
  case deviceEvidenceReused
  case missingDistinctDeviceEvidence
  case missingPrerequisitePhase
  case backgroundAuthorizationGranted
  case corruptLocalLedger
  case unresolvedCleanupRecords
  case incompleteAudit
}

actor SecretSyncLiveCleanupLedger {
  struct State: Codable, Sendable {
    var namespace: String
    var deviceEvidenceByRole: [String: String]
    var completedPhasesByRole: [String: [String]]
    var recordNamesByZone: [String: [String]]
    var evidence: [SecretSyncLiveEvidence]
  }

  private let url: URL
  private let namespace: String

  init(url: URL, namespace: String) throws {
    self.url = url
    self.namespace = namespace
  }

  /// Records an exact run-owned ID before any live save is issued.
  func recordBeforeSave(_ recordID: CKRecord.ID) throws {
    try transaction { state in
      var names = state.recordNamesByZone[recordID.zoneID.zoneName, default: []]
      if !names.contains(recordID.recordName) { names.append(recordID.recordName) }
      state.recordNamesByZone[recordID.zoneID.zoneName] = names
    }
  }

  /// Returns only exact IDs recorded by this process; it never derives IDs by query.
  func exactRecordIDs() throws -> [CKRecord.ID] {
    let state = try transaction { $0 }
    return state.recordNamesByZone.flatMap { zoneName, names in
      names.map {
        CKRecord.ID(
          recordName: $0,
          zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        )
      }
    }.sorted { lhs, rhs in
      if lhs.zoneID.zoneName == rhs.zoneID.zoneName {
        return lhs.recordName < rhs.recordName
      }
      return lhs.zoneID.zoneName < rhs.zoneID.zoneName
    }
  }

  /// Retains only failed run-owned deletions so a later cleanup retry has the
  /// exact unresolved IDs and never falls back to a broad CloudKit query.
  func retainUnresolved(_ recordIDs: [CKRecord.ID]) throws {
    try transaction { state in
      state.recordNamesByZone = Dictionary(grouping: recordIDs, by: { $0.zoneID.zoneName })
        .mapValues { $0.map(\.recordName).sorted() }
    }
  }

  func admitDevice(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    evidenceID: String
  ) throws {
    try transaction { state in
      guard !state.deviceEvidenceByRole.values.contains(evidenceID)
        || state.deviceEvidenceByRole[role.rawValue] == evidenceID else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      state.deviceEvidenceByRole[role.rawValue] = evidenceID
    }
  }

  func requireDistinctABC() throws {
    try transaction { state in
      let values = SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases.compactMap {
        state.deviceEvidenceByRole[$0.rawValue]
      }
      guard values.count == 3, Set(values).count == 3 else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingDistinctDeviceEvidence
      }
    }
  }

  func complete(
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    evidence: SecretSyncLiveEvidence
  ) throws {
    try transaction { state in
      var phases = state.completedPhasesByRole[role.rawValue, default: []]
      if !phases.contains(phase.rawValue) { phases.append(phase.rawValue) }
      state.completedPhasesByRole[role.rawValue] = phases
      state.evidence.append(evidence)
    }
  }

  func require(
    _ phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      guard state.completedPhasesByRole[role.rawValue, default: []].contains(phase.rawValue) else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
    }
  }

  /// Reloads under a POSIX lock for every operation; actor isolation alone does
  /// not protect two independently launched XCTest processes on one host.
  private func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let lockURL = URL(fileURLWithPath: url.path + ".lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
      if descriptor >= 0 { close(descriptor) }
      throw SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
    }
    var state: State
    if FileManager.default.fileExists(atPath: url.path) {
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
      guard state.namespace == namespace else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerNamespaceMismatch
      }
    } else {
      state = State(
        namespace: namespace, deviceEvidenceByRole: [:],
        completedPhasesByRole: [:], recordNamesByZone: [:], evidence: []
      )
    }
    let result = try body(&state)
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
    return result
  }
}

struct SecretSyncLiveEvidence: Codable, Sendable, Equatable {
  enum Operation: String, Codable, Sendable {
    case configuration
    case immutableStage
    case conditionalHead
    case reconstruct
    case authorize
    case deny
    case cleanup
    case hardwareCustody
    case proofOfPossession
    case offlineFloor
    case recovery
    case restart
  }

  enum ResultCode: String, Codable, Sendable {
    case passed
    case rejected
    case blocked
  }

  enum HeadRelation: String, Codable, Sendable {
    case none
    case exact
    case ahead
    case stale
    case fork
  }

  let timestamp: Date
  let deviceRole: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let operation: Operation
  let resultCode: ResultCode
  let headRelation: HeadRelation
}

struct SecretSyncLiveCredentialEvidence: Codable, Sendable, Equatable {
  let credential: TrustedDeviceCredential
  let signingHandleID: UUID
  let agreementHandleID: UUID
  let signingChallenge: Data
  let signingProof: Data
  let agreementChallenge: Data
  let agreementProof: Data
  let evidenceID: String
}

struct SecretSyncLiveCandidateReference: Codable, Sendable, Equatable {
  let commitDigest: Data
  let predecessorDigest: Data?
}

struct SecretSyncLiveCASResult: Codable, Sendable, Equatable {
  enum Outcome: String, Codable, Sendable, Hashable { case advanced, forkDetected }
  let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let outcome: Outcome
  let candidateDigest: Data
  let expectedPredecessorDigest: Data?
  let serverHeadDigest: Data
}

struct SecretSyncLiveRecordReference: Codable, Sendable, Equatable {
  let recordName: String
  let zoneName: String
}
