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
    let launchGrant: SecretSyncLiveHostLaunchGrant
    let launchGrantDigest: Data
    let hostAuthorityPublicKey: Data
  }

  enum DeviceRole: String, Codable, Sendable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
  }

  enum Phase: String, Codable, Sendable, CaseIterable {
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
  static let hostAuthorityPublicKeyKey =
    "MOOT_SECRET_SYNC_HOST_AUTHORITY_PUBLIC_KEY"
  static let hostLaunchGrantKey = "MOOT_SECRET_SYNC_HOST_LAUNCH_GRANT"
  static let canonicalContainerIdentifier = "iCloud.com.codedaptive.simplemachines"

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtimePlatform: SecretSyncLiveRuntimePlatform = .current,
    now: Date = Date()
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    guard environment[optInKey] == "1" else { return .disabled }
    guard environment[attestationKey] == "AUTHORIZED_U7_HOST_LAUNCH_GRANT" else {
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
    guard let authorityText = environment[hostAuthorityPublicKeyKey],
      let authorityPublicKey = Data(base64Encoded: authorityText)
    else { return .invalid(.hostAuthorityMissing) }
    guard let grantText = environment[hostLaunchGrantKey],
      let grantData = Data(base64Encoded: grantText),
      let grant = try? JSONDecoder().decode(SecretSyncLiveHostLaunchGrant.self, from: grantData)
    else { return .invalid(.hostLaunchGrantMissing) }
    let launchGrantDigest: Data
    do {
      launchGrantDigest = try SecretSyncLiveHostLaunchGrantVerifier.verify(
        grant, trustedAuthorityPublicKey: authorityPublicKey,
        namespace: namespace, role: role, phase: phase,
        runtimePlatform: runtimePlatform, now: now
      )
    } catch let error as SecretSyncLiveCloudKitProofConfigurationError {
      return .invalid(error)
    } catch {
      return .invalid(.hostLaunchGrantMalformed)
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
        ledgerURL: URL(fileURLWithPath: ledgerPath), launchGrant: grant,
        launchGrantDigest: launchGrantDigest,
        hostAuthorityPublicKey: authorityPublicKey
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
  case hostAuthorityMissing
  case hostLaunchGrantMissing
  case hostLaunchGrantMalformed
  case hostLaunchGrantSignatureInvalid
  case hostLaunchGrantExpired
  case hostLaunchGrantBindingMismatch
  case matrixPlatformMismatch
  case launchGrantReplay
  case launchGrantCredentialMismatch
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

enum SecretSyncLivePlatformMatrix {
  static func expectedPlatform(
    for role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> SecretSyncLiveRuntimePlatform {
    switch role {
    case .a: .mac
    case .b: .iPhone
    case .c: .iPad
    }
  }

}

/// A host-issued authorization for one exact external-device test launch.
/// Physical device selection remains host evidence in the G-RUNTIME log; the
/// in-device process proves only this signed grant and its runtime idiom.
struct SecretSyncLiveHostLaunchGrant: Codable, Sendable, Equatable {
  struct Manifest: Codable, Sendable, Equatable {
    let version: Int
    let runNamespace: String
    let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
    let phase: SecretSyncLiveCloudKitProofConfiguration.Phase
    let platform: SecretSyncLiveRuntimePlatform
    let nonce: UUID
    let expiresAtUnixSeconds: Int64
    let credentialBindingDigest: Data?
  }

  let manifest: Manifest
  let signature: Data
}

enum SecretSyncLiveHostLaunchGrantVerifier {
  static func verify(
    _ grant: SecretSyncLiveHostLaunchGrant,
    trustedAuthorityPublicKey: Data,
    namespace: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date
  ) throws -> Data {
    let manifest = grant.manifest
    guard manifest.version == 1, manifest.runNamespace == namespace,
      manifest.role == role, manifest.phase == phase
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantBindingMismatch
    }
    guard manifest.platform == runtimePlatform,
      runtimePlatform == SecretSyncLivePlatformMatrix.expectedPlatform(for: role)
    else { throw SecretSyncLiveCloudKitProofConfigurationError.matrixPlatformMismatch }
    guard manifest.expiresAtUnixSeconds > Int64(now.timeIntervalSince1970) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantExpired
    }
    guard (phase == .credential) == (manifest.credentialBindingDigest == nil) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantBindingMismatch
    }
    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      publicKey = try P256.Signing.PublicKey(x963Representation: trustedAuthorityPublicKey)
      signature = try P256.Signing.ECDSASignature(derRepresentation: grant.signature)
    } catch {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantMalformed
    }
    let body = try canonicalManifestBytes(manifest)
    guard publicKey.isValidSignature(signature, for: body) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantSignatureInvalid
    }
    return digest(
      authorityPublicKey: trustedAuthorityPublicKey,
      manifestBytes: body, signature: grant.signature
    )
  }

  static func canonicalManifestBytes(
    _ manifest: SecretSyncLiveHostLaunchGrant.Manifest
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  static func digest(
    authorityPublicKey: Data, manifestBytes: Data, signature: Data
  ) -> Data {
    var framed = Data("mootx01.u7.host-launch-grant.v1".utf8)
    for field in [authorityPublicKey, manifestBytes, signature] {
      var length = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
      framed.append(field)
    }
    return Data(SHA256.hash(data: framed))
  }
}

enum SecretSyncLiveCredentialBinding {
  static func digest(_ credential: TrustedDeviceCredential) -> Data {
    let fields = [
      Data(credential.credentialID.rawValue.uuidString.lowercased().utf8),
      Data(credential.signingPublicKey.algorithmIdentifier.utf8),
      credential.signingPublicKey.keyIdentifier,
      credential.signingPublicKey.publicKeyBytes,
      Data(credential.keyAgreementPublicKey.algorithmIdentifier.utf8),
      credential.keyAgreementPublicKey.keyIdentifier,
      credential.keyAgreementPublicKey.publicKeyBytes,
    ]
    var framed = Data("mootx01.u7.credential-public-binding.v1".utf8)
    for field in fields {
      var length = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
      framed.append(field)
    }
    return Data(SHA256.hash(data: framed))
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
    // Optional fields keep a locally retained pre-correction ledger readable.
    var hostAuthorityPublicKey: Data?
    var launchGrantDigestByNonce: [String: Data]?
    var credentialBindingDigestByRole: [String: Data]?
    var credentialIDByRole: [String: UUID]?
    var removedCredentialRoles: Set<String>?
    var cleanupPrepared: Bool?
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

  /// Freezes the first exact cleanup set. Retries consume only the unresolved
  /// remainder and cannot re-add records that a prior attempt proved absent.
  func prepareCleanup(
    including recordIDs: [CKRecord.ID]
  ) throws -> [CKRecord.ID] {
    try transaction { state in
      if state.cleanupPrepared != true {
        for recordID in recordIDs {
          var names = state.recordNamesByZone[recordID.zoneID.zoneName, default: []]
          if !names.contains(recordID.recordName) { names.append(recordID.recordName) }
          state.recordNamesByZone[recordID.zoneID.zoneName] = names
        }
        state.cleanupPrepared = true
      }
      return Self.recordIDs(from: state)
    }
  }

  /// Pins the host authority on first use, rejects nonce substitution, and
  /// requires every post-enrollment grant to bind the role's exact credential.
  func admitLaunchGrant(
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws {
    try transaction { state in
      if let pinned = state.hostAuthorityPublicKey {
        guard pinned == values.hostAuthorityPublicKey else {
          throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantSignatureInvalid
        }
      } else {
        state.hostAuthorityPublicKey = values.hostAuthorityPublicKey
      }
      var grants = state.launchGrantDigestByNonce ?? [:]
      let nonce = values.launchGrant.manifest.nonce.uuidString.lowercased()
      if let prior = grants[nonce], prior != values.launchGrantDigest {
        throw SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay
      }
      grants[nonce] = values.launchGrantDigest
      state.launchGrantDigestByNonce = grants
      if values.phase != .credential {
        let expected = (state.credentialBindingDigestByRole ?? [:])[
          values.deviceRole.rawValue
        ]
        guard expected != nil,
          expected == values.launchGrant.manifest.credentialBindingDigest
        else {
          throw SecretSyncLiveCloudKitProofConfigurationError.launchGrantCredentialMismatch
        }
      }
    }
  }

  func storeCredentialForCleanup(
    _ credential: TrustedDeviceCredential,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      var bindings = state.credentialBindingDigestByRole ?? [:]
      var identifiers = state.credentialIDByRole ?? [:]
      let digest = SecretSyncLiveCredentialBinding.digest(credential)
      guard bindings[role.rawValue] == nil || bindings[role.rawValue] == digest,
        identifiers[role.rawValue] == nil
          || identifiers[role.rawValue] == credential.credentialID.rawValue
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      bindings[role.rawValue] = digest
      identifiers[role.rawValue] = credential.credentialID.rawValue
      state.credentialBindingDigestByRole = bindings
      state.credentialIDByRole = identifiers
    }
  }

  func credentialIDForCleanup(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> DeviceCredentialID? {
    try transaction { state in
      if (state.removedCredentialRoles ?? []).contains(role.rawValue) { return nil }
      guard let rawValue = (state.credentialIDByRole ?? [:])[role.rawValue] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return DeviceCredentialID(rawValue)
    }
  }

  func markCredentialRemoved(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      var roles = state.removedCredentialRoles ?? []
      roles.insert(role.rawValue)
      state.removedCredentialRoles = roles
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
        transitionOutcomeBytesByPhase: [:], hostAuthorityPublicKey: nil,
        launchGrantDigestByNonce: nil, credentialBindingDigestByRole: nil,
        credentialIDByRole: nil, removedCredentialRoles: nil,
        cleanupPrepared: nil
      )
    }
    let result = try body(&state)
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
      throw SecretSyncLiveCloudKitProofConfigurationError.corruptLocalLedger
    }
    return result
  }

  private static func recordIDs(from state: State) -> [CKRecord.ID] {
    state.recordNamesByZone.flatMap { zoneName, names in
      names.map {
        CKRecord.ID(
          recordName: $0,
          zoneID: CKRecordZone.ID(
            zoneName: zoneName, ownerName: CKCurrentUserDefaultName
          )
        )
      }
    }.sorted { lhs, rhs in
      if lhs.zoneID.zoneName == rhs.zoneID.zoneName {
        return lhs.recordName < rhs.recordName
      }
      return lhs.zoneID.zoneName < rhs.zoneID.zoneName
    }
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
  /// Digest of the signed host launch grant. Raw host device selectors remain
  /// exclusively in the external G-RUNTIME evidence.
  let launchGrantDigest: Data
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
