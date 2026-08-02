import CloudKit
import ConvergenceKitCloudKit
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
    let deviceEvidenceID: String
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
    case cleanup
  }

  static let optInKey = "MOOT_SECRET_SYNC_LIVE_PROOF"
  static let namespaceKey = "MOOT_SECRET_SYNC_RUN_NAMESPACE"
  static let roleKey = "MOOT_SECRET_SYNC_DEVICE_ROLE"
  static let phaseKey = "MOOT_SECRET_SYNC_PHASE"
  static let attestationKey = "MOOT_SECRET_SYNC_OPERATOR_ATTESTATION"
  static let deviceEvidenceKey = "MOOT_SECRET_SYNC_DEVICE_EVIDENCE_ID"
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
    guard let evidenceID = environment[deviceEvidenceKey], valid(evidenceID: evidenceID) else {
      return .invalid(.invalidDeviceEvidenceID)
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
        deviceEvidenceID: evidenceID,
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

  private static func valid(evidenceID: String) -> Bool {
    evidenceID.hasPrefix("device-") && evidenceID.count == 43
      && evidenceID.dropFirst(7).allSatisfy { $0.isHexDigit }
  }
}

extension SecretSyncLiveCloudKitProofConfiguration.Phase {
  fileprivate func isAdmitted(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> Bool {
    switch self {
    case .credential, .verify, .cleanup: return true
    case .stage, .conditionalHead, .offline, .backgroundDenied,
         .recovery, .rotation, .restart: return role == .a
    case .revoke: return role == .c
    }
  }
}

enum SecretSyncLiveCloudKitProofConfigurationError: Error, Sendable, Equatable {
  case operatorAttestationMissing
  case invalidRunNamespace
  case invalidDeviceRole
  case invalidPhase
  case invalidDeviceEvidenceID
  case invalidLedgerPath
  case rolePhaseMismatch
  case ledgerNamespaceMismatch
  case deviceEvidenceReused
  case missingDistinctDeviceEvidence
  case missingPrerequisitePhase
  case backgroundAuthorizationGranted
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
  private var state: State

  init(url: URL, namespace: String) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
      guard state.namespace == namespace else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerNamespaceMismatch
      }
    } else {
      state = State(
        namespace: namespace,
        deviceEvidenceByRole: [:],
        completedPhasesByRole: [:],
        recordNamesByZone: [:],
        evidence: []
      )
    }
  }

  /// Records an exact run-owned ID before any live save is issued.
  func recordBeforeSave(_ recordID: CKRecord.ID) throws {
    var names = state.recordNamesByZone[recordID.zoneID.zoneName, default: []]
    if !names.contains(recordID.recordName) { names.append(recordID.recordName) }
    state.recordNamesByZone[recordID.zoneID.zoneName] = names
    try persist()
  }

  /// Returns only exact IDs recorded by this process; it never derives IDs by query.
  func exactRecordIDs() -> [CKRecord.ID] {
    state.recordNamesByZone.flatMap { zoneName, names in
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

  func admitDevice(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    evidenceID: String
  ) throws {
    guard !state.deviceEvidenceByRole.values.contains(evidenceID)
      || state.deviceEvidenceByRole[role.rawValue] == evidenceID else {
      throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
    }
    state.deviceEvidenceByRole[role.rawValue] = evidenceID
    try persist()
  }

  func requireDistinctABC() throws {
    let values = SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases.compactMap {
      state.deviceEvidenceByRole[$0.rawValue]
    }
    guard values.count == 3, Set(values).count == 3 else {
      throw SecretSyncLiveCloudKitProofConfigurationError.missingDistinctDeviceEvidence
    }
  }

  func complete(
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    evidence: SecretSyncLiveEvidence
  ) throws {
    state.completedPhasesByRole[role.rawValue, default: []].append(phase.rawValue)
    state.evidence.append(evidence)
    try persist()
  }

  func require(
    _ phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    guard state.completedPhasesByRole[role.rawValue, default: []].contains(phase.rawValue) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
    }
  }

  private func persist() throws {
    let data = try JSONEncoder().encode(state)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
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
