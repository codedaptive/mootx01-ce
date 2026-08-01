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
  }

  enum DeviceRole: String, Sendable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
  }

  enum Phase: String, Sendable, CaseIterable {
    case prepare
    case conditionalHead
    case verify
    case cleanup
  }

  static let optInKey = "MOOT_SECRET_SYNC_LIVE_PROOF"
  static let namespaceKey = "MOOT_SECRET_SYNC_RUN_NAMESPACE"
  static let roleKey = "MOOT_SECRET_SYNC_DEVICE_ROLE"
  static let phaseKey = "MOOT_SECRET_SYNC_PHASE"
  static let attestationKey = "MOOT_SECRET_SYNC_OPERATOR_ATTESTATION"
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
    return .configured(
      Values(
        containerIdentifier: canonicalContainerIdentifier,
        databaseScope: .private,
        controlZoneID: SecretSyncCloudKitZones.controlZoneID,
        payloadZoneID: SecretSyncCloudKitZones.payloadZoneID,
        runNamespace: namespace,
        deviceRole: role,
        phase: phase
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

enum SecretSyncLiveCloudKitProofConfigurationError: Error, Sendable, Equatable {
  case operatorAttestationMissing
  case invalidRunNamespace
  case invalidDeviceRole
  case invalidPhase
}

actor SecretSyncLiveCleanupLedger {
  private var createdRecordIDs: Set<CKRecord.ID> = []

  /// Records an exact run-owned ID before any live save is issued.
  func recordBeforeSave(_ recordID: CKRecord.ID) {
    createdRecordIDs.insert(recordID)
  }

  /// Returns only exact IDs recorded by this process; it never derives IDs by query.
  func exactRecordIDs() -> [CKRecord.ID] {
    createdRecordIDs.sorted { lhs, rhs in
      if lhs.zoneID.zoneName == rhs.zoneID.zoneName {
        return lhs.recordName < rhs.recordName
      }
      return lhs.zoneID.zoneName < rhs.zoneID.zoneName
    }
  }
}

struct SecretSyncLiveEvidence: Sendable, Equatable {
  enum Operation: String, Sendable {
    case configuration
    case immutableStage
    case conditionalHead
    case reconstruct
    case authorize
    case deny
    case cleanup
  }

  enum ResultCode: String, Sendable {
    case passed
    case rejected
    case blocked
  }

  enum HeadRelation: String, Sendable {
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
