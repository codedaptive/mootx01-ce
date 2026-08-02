import CloudKit
import ConvergenceKit
import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import CryptoKit
import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SecretSyncLiveCloudKitProofConfiguration: Sendable, Equatable {
  case disabled
  case invalid(SecretSyncLiveCloudKitProofConfigurationError)
  case configured(Values)

  struct Values: Sendable, Equatable {
    // These identify the authorized Fulcrum proof fixture environment. They
    // confer no shared SecretSync semantic authority.
    let containerIdentifier: String
    let databaseScope: CKDatabase.Scope
    let controlZoneID: CKRecordZone.ID
    let payloadZoneID: CKRecordZone.ID
    let runNamespace: String
    let deviceRole: DeviceRole
    let phase: Phase
    let ledgerURL: URL
    let matrixIdentityDigest: Data
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
  static let expectedDeviceIdentifierKey =
    "MOOT_SECRET_SYNC_EXPECTED_DEVICE_IDENTIFIER"
  static let canonicalContainerIdentifier = "iCloud.com.codedaptive.simplemachines"

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtimePlatform: SecretSyncLiveRuntimePlatform = .current
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
    guard let suppliedIdentifier = environment[expectedDeviceIdentifierKey] else {
      return .invalid(.expectedDeviceIdentifierMissing)
    }
    let matrixIdentityDigest: Data
    do {
      matrixIdentityDigest = try SecretSyncLivePhysicalMatrix.admit(
        role: role, suppliedIdentifier: suppliedIdentifier,
        runtimePlatform: runtimePlatform
      )
    } catch let error as SecretSyncLiveCloudKitProofConfigurationError {
      return .invalid(error)
    } catch {
      return .invalid(.matrixIdentityMismatch)
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
        ledgerURL: URL(fileURLWithPath: ledgerPath),
        matrixIdentityDigest: matrixIdentityDigest
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
  case expectedDeviceIdentifierMissing
  case matrixPlatformMismatch
  case matrixIdentityMismatch
  case rolePhaseMismatch
  case ledgerNamespaceMismatch
  case deviceEvidenceReused
  case missingDistinctDeviceEvidence
  case missingPrerequisitePhase
  case backgroundAuthorizationGranted
  case corruptLocalLedger
  case unresolvedCleanupRecords
  case incompleteAudit
  case requiredZoneMissing
  case unauthorizedArtifactZone
  case zoneMutationProhibited
}

enum SecretSyncLiveRuntimePlatform: String, Codable, Sendable {
  case mac
  case iPhone
  case iPad
  case unsupported

  static var current: SecretSyncLiveRuntimePlatform {
#if os(macOS)
    .mac
#elseif canImport(UIKit)
    switch UIDevice.current.userInterfaceIdiom {
    case .phone: .iPhone
    case .pad: .iPad
    default: .unsupported
    }
#else
    .unsupported
#endif
  }
}

enum SecretSyncLivePhysicalMatrix {
  private static let label = "u7-authorized-physical-matrix/v1"

  static func expectedPlatform(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> SecretSyncLiveRuntimePlatform {
    switch role {
    case .a: .mac
    case .b: .iPhone
    case .c: .iPad
    }
  }

  static func expectedIdentifier(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> String {
    switch role {
    case .a: "F58DA72F-02B8-5632-93D2-86B3CBAC9CB7"
    case .b: "00008150-00161D3C0192401C"
    case .c: "00008142-000A21981147801C"
    }
  }

  static func digest(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> Data {
    let bytes = Data(
      "\(label)|\(role.rawValue)|\(expectedPlatform(for: role).rawValue)|\(expectedIdentifier(for: role))"
        .utf8
    )
    return Data(SHA256.hash(data: bytes))
  }

  static func admit(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    suppliedIdentifier: String,
    runtimePlatform: SecretSyncLiveRuntimePlatform
  ) throws -> Data {
    guard runtimePlatform == expectedPlatform(for: role) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.matrixPlatformMismatch
    }
    guard suppliedIdentifier == expectedIdentifier(for: role) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.matrixIdentityMismatch
    }
    return digest(for: role)
  }
}

actor SecretSyncLiveCleanupLedger {
  struct State: Codable, Sendable {
    var namespace: String
    var deviceEvidenceByRole: [String: String]
    var completedPhasesByRole: [String: [String]]
    var recordNamesByZone: [String: [String]]
    var evidence: [SecretSyncLiveEvidence]
    var agreementVerifierPrivateKeysByRole: [String: Data]
    var protectedCommitment: SecretBootstrapFreshnessCommitment?
    var transitionOutcomeBytesByPhase: [String: Data]
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
        completedPhasesByRole: [:], recordNamesByZone: [:], evidence: [],
        agreementVerifierPrivateKeysByRole: [:], protectedCommitment: nil,
        transitionOutcomeBytesByPhase: [:]
      )
    }
    let result = try body(&state)
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
      throw SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
    }
    return result
  }

  func storeAgreementVerifierPrivateKey(
    _ key: Data,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      guard state.agreementVerifierPrivateKeysByRole[role.rawValue] == nil else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      state.agreementVerifierPrivateKeysByRole[role.rawValue] = key
    }
  }

  func agreementVerifierPrivateKey(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> Data {
    try transaction { state in
      guard let key = state.agreementVerifierPrivateKeysByRole[role.rawValue] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return key
    }
  }

  func storeProtectedCommitment(
    _ commitment: SecretBootstrapFreshnessCommitment
  ) throws {
    try transaction { state in
      guard state.protectedCommitment == nil
        || state.protectedCommitment == commitment else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      state.protectedCommitment = commitment
    }
  }

  func protectedCommitment() throws -> SecretBootstrapFreshnessCommitment {
    try transaction { state in
      guard let commitment = state.protectedCommitment else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return commitment
    }
  }

  func storeTransitionOutcome(
    _ bytes: Data,
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase
  ) throws {
    try transaction { state in
      guard state.transitionOutcomeBytesByPhase[phase.rawValue] == nil else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      state.transitionOutcomeBytesByPhase[phase.rawValue] = bytes
    }
  }

  func transitionOutcome(
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase
  ) throws -> Data {
    try transaction { state in
      guard let bytes = state.transitionOutcomeBytesByPhase[phase.rawValue] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return bytes
    }
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
    case offlineTransportFallback
    case breakGlassCustodyStaged
    case recoveryRotationCustodyStaged
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
  let productionSeam: String?
  let outcomeDigest: Data?
}

struct SecretSyncLiveCredentialEvidence: Codable, Sendable, Equatable {
  let matrixIdentityDigest: Data
  let credential: TrustedDeviceCredential
  let signingHandleID: UUID
  let agreementHandleID: UUID
  let possessionTranscript: SecretSyncLivePossessionTranscript
  let signingChallenge: Data
  let signingProof: Data
  let agreementChallenge: Data
  let agreementProof: Data
  let attestationTranscript: SecretSyncLivePossessionTranscript
  let attestationChallenge: Data
  let attestationProof: Data
  let evidenceID: String
}

struct SecretSyncLiveAgreementVerifierPublic: Codable, Sendable, Equatable {
  let publicKey: Data
}

struct SecretSyncLivePossessionTranscript: Codable, Sendable, Equatable {
  let challengeID: UUID
  let sessionID: UUID
  let issuedAt: Date
  let expiresAt: Date
  let deviceID: TrustedDeviceID
  let credentialID: DeviceCredentialID
  let signingPublicKey: SigningPublicKeyDescriptor
  let agreementPublicKey: KeyAgreementPublicKeyDescriptor
  let authorityCredentialID: DeviceCredentialID
  let freshnessCommitment: SecretBootstrapFreshnessCommitment

  func productionValue() throws -> SecretSyncProofOfPossessionTranscript {
    try SecretSyncProofOfPossessionTranscript(
      challengeID: challengeID, sessionID: sessionID,
      issuedAt: issuedAt, expiresAt: expiresAt,
      deviceID: deviceID, credentialID: credentialID,
      signingPublicKey: signingPublicKey,
      agreementPublicKey: agreementPublicKey,
      authorityCredentialID: authorityCredentialID,
      freshnessCommitment: freshnessCommitment
    )
  }
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
