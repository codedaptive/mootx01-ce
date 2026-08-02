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
    let signedRunManifest: SecretSyncLiveSignedRunManifest
    let runManifestDigest: Data
    let launchGrant: SecretSyncLiveHostLaunchGrant
    let launchGrantDigest: Data
    let trustedHostAuthorityPublicKey: Data
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
  static let signedRunManifestKey = "MOOT_SECRET_SYNC_SIGNED_RUN_MANIFEST"
  static let hostLaunchGrantKey = "MOOT_SECRET_SYNC_HOST_LAUNCH_GRANT"
  static let hostAuthorityBundleKey = "MOOTSecretSyncHostAuthorityPublicKey"
  static let canonicalContainerIdentifier = "iCloud.com.codedaptive.simplemachines"

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtimePlatform: SecretSyncLiveRuntimePlatform = .current,
    now: Date = Date()
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    guard let anchor = SecretSyncLiveHostAuthorityTrustAnchor.signedTestBundlePublicKey()
    else { return .invalid(.hostAuthorityMissing) }
    return load(
      environment: environment, runtimePlatform: runtimePlatform, now: now,
      independentlyAuthenticatedHostAuthorityPublicKey: anchor
    )
  }

  /// Deterministic tests inject an authority directly; the live entry point
  /// above can only obtain authority from the code-signed XCTest bundle.
  static func loadForDeterministicTesting(
    environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date = Date(),
    independentlyAuthenticatedHostAuthorityPublicKey: Data
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    load(
      environment: environment, runtimePlatform: runtimePlatform, now: now,
      independentlyAuthenticatedHostAuthorityPublicKey:
        independentlyAuthenticatedHostAuthorityPublicKey
    )
  }

  private static func load(
    environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date,
    independentlyAuthenticatedHostAuthorityPublicKey authorityPublicKey: Data
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
    guard let runManifestText = environment[signedRunManifestKey],
      let runManifestData = Data(base64Encoded: runManifestText),
      let signedRunManifest = try? JSONDecoder().decode(
        SecretSyncLiveSignedRunManifest.self, from: runManifestData
      )
    else { return .invalid(.signedRunManifestMissing) }
    let runManifestDigest: Data
    do {
      runManifestDigest = try SecretSyncLiveSignedRunManifestVerifier.verify(
        signedRunManifest, trustedAuthorityPublicKey: authorityPublicKey,
        namespace: namespace
      )
    } catch let error as SecretSyncLiveCloudKitProofConfigurationError {
      return .invalid(error)
    } catch {
      return .invalid(.signedRunManifestMalformed)
    }
    guard let grantText = environment[hostLaunchGrantKey],
      let grantData = Data(base64Encoded: grantText),
      let grant = try? JSONDecoder().decode(SecretSyncLiveHostLaunchGrant.self, from: grantData)
    else { return .invalid(.hostLaunchGrantMissing) }
    let launchGrantDigest: Data
    do {
      launchGrantDigest = try SecretSyncLiveHostLaunchGrantVerifier.verify(
        grant, trustedAuthorityPublicKey: authorityPublicKey,
        expectedRunManifestDigest: runManifestDigest,
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
        ledgerURL: signedRunManifest.manifest.ledgerURL,
        signedRunManifest: signedRunManifest,
        runManifestDigest: runManifestDigest, launchGrant: grant,
        launchGrantDigest: launchGrantDigest,
        trustedHostAuthorityPublicKey: authorityPublicKey
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

private final class SecretSyncLiveProofBundleToken {}

enum SecretSyncLiveHostAuthorityTrustAnchor {
  static func signedTestBundlePublicKey() -> Data? {
    let bundle = Bundle(for: SecretSyncLiveProofBundleToken.self)
    guard let encoded = bundle.object(
      forInfoDictionaryKey: SecretSyncLiveCloudKitProofConfiguration
        .hostAuthorityBundleKey
    ) as? String else { return nil }
    return Data(base64Encoded: encoded)
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
  case signedRunManifestMissing
  case signedRunManifestMalformed
  case signedRunManifestSignatureInvalid
  case signedRunManifestBindingMismatch
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
  case ledgerAuthenticationFailed
  case unauthorizedRunRecord
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

struct SecretSyncLiveSignedRunManifest: Codable, Sendable, Equatable {
  struct Manifest: Codable, Sendable, Equatable {
    let version: Int
    let runNamespace: String
    let ledgerDirectoryPath: String
    let ledgerIdentifier: String
    let artifactRecordNames: [String]
    let cleanupRecords: [SecretSyncLiveRecordReference]

    var ledgerURL: URL {
      URL(fileURLWithPath: ledgerDirectoryPath, isDirectory: true)
        .appendingPathComponent("\(ledgerIdentifier).json", isDirectory: false)
    }
  }

  let manifest: Manifest
  let signature: Data
}

enum SecretSyncLiveSignedRunManifestVerifier {
  static func verify(
    _ signed: SecretSyncLiveSignedRunManifest,
    trustedAuthorityPublicKey: Data,
    namespace: String
  ) throws -> Data {
    let manifest = signed.manifest
    guard manifest.version == 1, manifest.runNamespace == namespace,
      manifest.ledgerDirectoryPath.hasPrefix("/"),
      manifest.ledgerIdentifier == expectedLedgerIdentifier(namespace: namespace),
      Set(manifest.artifactRecordNames).count == manifest.artifactRecordNames.count,
      Set(manifest.cleanupRecords).count == manifest.cleanupRecords.count
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .signedRunManifestBindingMismatch
    }
    for recordName in manifest.artifactRecordNames {
      try SecretSyncLiveRunOwnedRecordGrammar.requireArtifact(
        recordName: recordName, namespace: namespace
      )
    }
    for reference in manifest.cleanupRecords {
      try SecretSyncLiveRunOwnedRecordGrammar.requireCleanup(
        reference, namespace: namespace
      )
    }
    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      publicKey = try P256.Signing.PublicKey(
        x963Representation: trustedAuthorityPublicKey
      )
      signature = try P256.Signing.ECDSASignature(
        derRepresentation: signed.signature
      )
    } catch {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .signedRunManifestMalformed
    }
    let body = try canonicalManifestBytes(manifest)
    guard publicKey.isValidSignature(signature, for: body) else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .signedRunManifestSignatureInvalid
    }
    return digest(manifestBytes: body, signature: signed.signature)
  }

  static func canonicalManifestBytes(
    _ manifest: SecretSyncLiveSignedRunManifest.Manifest
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  static func digest(manifestBytes: Data, signature: Data) -> Data {
    SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.signed-run-manifest.v1",
      fields: [manifestBytes, signature]
    )
  }

  static func expectedLedgerIdentifier(namespace: String) -> String {
    let digest = SHA256.hash(data: Data(namespace.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "u7-ledger-\(digest)"
  }
}

enum SecretSyncLiveRunOwnedRecordGrammar {
  private static let artifactKinds: Set<String> = [
    "agreement-verifier", "credential", "phase-credential",
    "phase-backgroundDenied", "candidate", "manifest", "phase-stage",
    "cas", "phase-conditionalHead", "phase-verify", "phase-revoke",
    "phase-offline", "phase-recovery", "phase-rotation", "phase-restart",
    "phase-audit", "phase-cleanup",
  ]

  static func requireArtifact(recordName: String, namespace: String) throws {
    let role = try requiredRoleSuffix(recordName)
    let prefix = "\(namespace)-"
    guard recordName.hasPrefix(prefix) else { throw unauthorized() }
    let kindEnd = recordName.index(
      recordName.endIndex, offsetBy: -(role.rawValue.count + 1)
    )
    let kindStart = recordName.index(recordName.startIndex, offsetBy: prefix.count)
    let kind = String(recordName[kindStart..<kindEnd])
    guard artifactKinds.contains(kind) else { throw unauthorized() }
  }

  static func requireCleanup(
    _ reference: SecretSyncLiveRecordReference,
    namespace: String
  ) throws {
    if reference.zoneName == SecretSyncCloudKitZones.controlZoneID.zoneName {
      if reference.recordName.hasPrefix("\(namespace)-") {
        try requireArtifact(recordName: reference.recordName, namespace: namespace)
      } else {
        try requireLowercaseHex(reference.recordName)
      }
    } else if reference.zoneName == SecretSyncCloudKitZones.payloadZoneID.zoneName {
      try requireLowercaseHex(reference.recordName)
    } else {
      throw unauthorized()
    }
  }

  private static func requiredRoleSuffix(
    _ recordName: String
  ) throws -> SecretSyncLiveCloudKitProofConfiguration.DeviceRole {
    guard let role = SecretSyncLiveCloudKitProofConfiguration.DeviceRole.allCases
      .first(where: { recordName.hasSuffix("-\($0.rawValue)") })
    else { throw unauthorized() }
    return role
  }

  private static func requireLowercaseHex(_ value: String) throws {
    guard (value.count == 32 || value.count == 64),
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw unauthorized() }
  }

  private static func unauthorized() -> SecretSyncLiveCloudKitProofConfigurationError {
    .unauthorizedRunRecord
  }
}

enum SecretSyncLiveFraming {
  static func digest(domain: String, fields: [Data]) -> Data {
    var framed = Data(domain.utf8)
    for field in fields {
      var length = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
      framed.append(field)
    }
    return Data(SHA256.hash(data: framed))
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
    let runManifestDigest: Data
    let expectedLedgerContentDigest: Data
    let prerequisiteArtifactDigests: [Data]
    let trustedCredentialGrantDigestsByRole: [String: Data]
    let credentialBindingDigest: Data?
  }

  let manifest: Manifest
  let signature: Data
}

enum SecretSyncLiveHostLaunchGrantVerifier {
  static func verify(
    _ grant: SecretSyncLiveHostLaunchGrant,
    trustedAuthorityPublicKey: Data,
    expectedRunManifestDigest: Data,
    namespace: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    phase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date
  ) throws -> Data {
    let manifest = grant.manifest
    guard manifest.version == 1, manifest.runNamespace == namespace,
      manifest.role == role, manifest.phase == phase,
      manifest.runManifestDigest == expectedRunManifestDigest,
      manifest.expectedLedgerContentDigest.count == SHA256.byteCount,
      manifest.prerequisiteArtifactDigests.allSatisfy({ $0.count == SHA256.byteCount }),
      manifest.trustedCredentialGrantDigestsByRole.values.allSatisfy({
        $0.count == SHA256.byteCount
      })
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
    SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.host-launch-grant.v1",
      fields: [authorityPublicKey, manifestBytes, signature]
    )
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
  struct CredentialCheckpoint: Codable, Sendable, Equatable {
    let deviceID: TrustedDeviceID
    let credentialID: DeviceCredentialID
    let signingHandle: SigningPrivateKeyHandle
    let agreementHandle: KeyAgreementPrivateKeyHandle
    let signingPublicKey: SigningPublicKeyDescriptor
    let agreementPublicKey: KeyAgreementPublicKeyDescriptor
    var published: Bool
  }

  struct State: Codable, Sendable {
    var namespace: String
    var deviceEvidenceByRole: [String: String]
    var completedPhasesByRole: [String: [String]]
    var recordNamesByZone: [String: [String]]
    var evidence: [SecretSyncLiveEvidence]
    var agreementVerifierPrivateKeysByRole: [String: Data]
    var protectedCommitment: SecretBootstrapFreshnessCommitment?
    var transitionOutcomeBytesByPhase: [String: Data]
    var signedRunManifestDigest: Data?
    var launchGrantDigestByNonce: [String: Data]?
    var credentialBindingDigestByRole: [String: Data]?
    var credentialIDByRole: [String: UUID]?
    var removedCredentialRoles: Set<String>?
    var cleanupPrepared: Bool?
    var frozenCleanupRecordNamesByZone: [String: [String]]?
    var cleanupPrerequisitesCheckpointed: Bool?
    var cleanupMarkersByRole: [String: SecretSyncLiveEvidence]?
    var locallyCompletedCleanupRoles: Set<String>?
    var credentialCheckpointsByRole: [String: CredentialCheckpoint]?
    var activeSignedCleanupRecords: [SecretSyncLiveRecordReference]?
    var admittedLaunchGrantsByDigest: [String: SecretSyncLiveHostLaunchGrant]?
    var trustedCredentialsByRole: [String: TrustedDeviceCredential]?
    var pendingAuditEnvelope: SecretSyncLiveSignedArtifactEnvelope?
  }

  private let url: URL
  private let namespace: String

  init(url: URL, namespace: String) throws {
    self.url = url
    self.namespace = namespace
    guard url.isFileURL, url.path.hasPrefix("/"),
      url.lastPathComponent
        == "\(SecretSyncLiveSignedRunManifestVerifier.expectedLedgerIdentifier(namespace: namespace)).json"
    else { throw SecretSyncLiveCloudKitProofConfigurationError.invalidLedgerPath }
  }

  /// Records an exact run-owned ID before any live save is issued.
  func recordBeforeSave(_ recordID: CKRecord.ID) throws {
    try SecretSyncLiveRunOwnedRecordGrammar.requireCleanup(
      SecretSyncLiveRecordReference(
        recordName: recordID.recordName, zoneName: recordID.zoneID.zoneName
      ),
      namespace: namespace
    )
    return try transaction { state in
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

  /// Atomically records successful prerequisite verification and freezes the
  /// first exact cleanup set before any local or CloudKit deletion begins.
  func checkpointCleanupPrerequisites(
    including recordIDs: [CKRecord.ID],
    signedRunManifest: SecretSyncLiveSignedRunManifest
  ) throws -> [CKRecord.ID] {
    let signedReferences = Set(signedRunManifest.manifest.cleanupRecords)
    let candidateReferences = Set(recordIDs.map {
      SecretSyncLiveRecordReference(
        recordName: $0.recordName, zoneName: $0.zoneID.zoneName
      )
    })
    guard candidateReferences == signedReferences else {
      throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedRunRecord
    }
    for reference in candidateReferences {
      try SecretSyncLiveRunOwnedRecordGrammar.requireCleanup(
        reference, namespace: namespace
      )
    }
    return try transaction { state in
      guard state.signedRunManifestDigest != nil,
        state.activeSignedCleanupRecords.map(Set.init) == signedReferences
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerAuthenticationFailed
      }
      if state.cleanupPrepared != true {
        for recordID in recordIDs {
          var names = state.recordNamesByZone[recordID.zoneID.zoneName, default: []]
          if !names.contains(recordID.recordName) { names.append(recordID.recordName) }
          state.recordNamesByZone[recordID.zoneID.zoneName] = names
        }
        state.cleanupPrepared = true
        state.cleanupPrerequisitesCheckpointed = true
        state.frozenCleanupRecordNamesByZone = state.recordNamesByZone
      }
      return Self.recordIDs(from: state)
    }
  }

  /// Returns the unresolved remainder only after the prerequisite+freeze
  /// checkpoint is durable. A retry uses this without touching CloudKit first.
  func preparedCleanupRecordIDs() throws -> [CKRecord.ID]? {
    try transaction { state in
      guard state.cleanupPrepared == true,
        state.cleanupPrerequisitesCheckpointed == true,
        state.frozenCleanupRecordNamesByZone != nil
      else { return nil }
      return Self.recordIDs(from: state)
    }
  }

  func frozenCleanupRecordIDs() throws -> [CKRecord.ID] {
    try transaction { state in
      guard let frozen = state.frozenCleanupRecordNamesByZone else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      var copy = state
      copy.recordNamesByZone = frozen
      return Self.recordIDs(from: copy)
    }
  }

  /// Pins the host authority on first use, rejects nonce substitution, and
  /// requires every post-enrollment grant to bind the role's exact credential.
  func admitLaunchGrant(
    values: SecretSyncLiveCloudKitProofConfiguration.Values
  ) throws {
    try transaction { state in
      guard url.standardizedFileURL == values.ledgerURL.standardizedFileURL else {
        throw SecretSyncLiveCloudKitProofConfigurationError.invalidLedgerPath
      }
      if let pinned = state.signedRunManifestDigest {
        guard pinned == values.runManifestDigest else {
          throw SecretSyncLiveCloudKitProofConfigurationError
            .signedRunManifestBindingMismatch
        }
      }
      var grants = state.launchGrantDigestByNonce ?? [:]
      let nonce = values.launchGrant.manifest.nonce.uuidString.lowercased()
      if grants[nonce] != nil {
        throw SecretSyncLiveCloudKitProofConfigurationError.launchGrantReplay
      }
      guard Self.contentDigest(state) == values.launchGrant.manifest
        .expectedLedgerContentDigest
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerAuthenticationFailed
      }
      state.signedRunManifestDigest = values.runManifestDigest
      grants[nonce] = values.launchGrantDigest
      state.launchGrantDigestByNonce = grants
      var admitted = state.admittedLaunchGrantsByDigest ?? [:]
      let digestKey = values.launchGrantDigest.base64EncodedString()
      guard admitted[digestKey] == nil || admitted[digestKey] == values.launchGrant else {
        throw SecretSyncLiveCloudKitProofConfigurationError
          .hostLaunchGrantBindingMismatch
      }
      admitted[digestKey] = values.launchGrant
      state.admittedLaunchGrantsByDigest = admitted
      if values.phase == .cleanup {
        state.activeSignedCleanupRecords = values.signedRunManifest.manifest
          .cleanupRecords
      }
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

  func approvedLaunchGrant(
    digest: Data
  ) throws -> SecretSyncLiveHostLaunchGrant {
    try transaction(writeBack: false) { state in
      guard let grant = (state.admittedLaunchGrantsByDigest ?? [:])[
        digest.base64EncodedString()
      ] else {
        throw SecretSyncLiveCloudKitProofConfigurationError
          .missingPrerequisitePhase
      }
      return grant
    }
  }

  static func initialContentDigest(namespace: String) -> Data {
    contentDigest(initialState(namespace: namespace))
  }

  func currentContentDigest() throws -> Data {
    try transaction(writeBack: false) { state in Self.contentDigest(state) }
  }

  func checkpointProvisionalCredential(
    _ generation: SecretSyncCustodyCredentialGeneration,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      var checkpoints = state.credentialCheckpointsByRole ?? [:]
      guard checkpoints[role.rawValue] == nil else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      checkpoints[role.rawValue] = CredentialCheckpoint(
        deviceID: generation.deviceID, credentialID: generation.credentialID,
        signingHandle: generation.signingHandle,
        agreementHandle: generation.agreementHandle,
        signingPublicKey: generation.signingPublicKey,
        agreementPublicKey: generation.agreementPublicKey, published: false
      )
      state.credentialCheckpointsByRole = checkpoints
    }
  }

  func credentialCheckpoint(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> CredentialCheckpoint? {
    try transaction(writeBack: false) { state in
      (state.credentialCheckpointsByRole ?? [:])[role.rawValue]
    }
  }

  func markCredentialPublished(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    try transaction { state in
      guard var checkpoint = (state.credentialCheckpointsByRole ?? [:])[
        role.rawValue
      ] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      checkpoint.published = true
      state.credentialCheckpointsByRole?[role.rawValue] = checkpoint
    }
  }

  func clearCredentialCheckpoint(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    _ = try transaction { state in
      state.credentialCheckpointsByRole?.removeValue(forKey: role.rawValue)
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
      var credentials = state.trustedCredentialsByRole ?? [:]
      guard credentials[role.rawValue] == nil
        || credentials[role.rawValue] == credential else {
        throw SecretSyncLiveCloudKitProofConfigurationError.deviceEvidenceReused
      }
      credentials[role.rawValue] = credential
      state.trustedCredentialsByRole = credentials
    }
  }

  func approvedCredential(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> TrustedDeviceCredential {
    try transaction(writeBack: false) { state in
      guard let credential = (state.trustedCredentialsByRole ?? [:])[
        role.rawValue
      ] else {
        throw SecretSyncLiveCloudKitProofConfigurationError
          .missingPrerequisitePhase
      }
      return credential
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

  func credentialBindingDigest(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> Data {
    try transaction(writeBack: false) { state in
      guard let digest = (state.credentialBindingDigestByRole ?? [:])[
        role.rawValue
      ] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return digest
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

  /// Persists one stable create-only cleanup marker before publication so a
  /// post-save crash can retry by validating the exact same payload.
  func cleanupMarker(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    now: Date = Date()
  ) throws -> SecretSyncLiveEvidence {
    try transaction { state in
      var markers = state.cleanupMarkersByRole ?? [:]
      if let existing = markers[role.rawValue] { return existing }
      let marker = SecretSyncLiveEvidence(
        timestamp: now, deviceRole: role, operation: .cleanup,
        resultCode: .passed, headRelation: .none,
        productionSeam: nil, outcomeDigest: nil
      )
      markers[role.rawValue] = marker
      state.cleanupMarkersByRole = markers
      return marker
    }
  }

  func checkpointLocalCleanupCompletion(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    evidence: SecretSyncLiveEvidence
  ) throws {
    try transaction { state in
      var completed = state.locallyCompletedCleanupRoles ?? []
      guard !completed.contains(role.rawValue) else { return }
      completed.insert(role.rawValue)
      state.locallyCompletedCleanupRoles = completed
      var phases = state.completedPhasesByRole[role.rawValue, default: []]
      if !phases.contains(SecretSyncLiveCloudKitProofConfiguration.Phase.cleanup.rawValue) {
        phases.append(SecretSyncLiveCloudKitProofConfiguration.Phase.cleanup.rawValue)
      }
      state.completedPhasesByRole[role.rawValue] = phases
      state.evidence.append(evidence)
    }
  }

  func localCleanupCompleted(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> Bool {
    try transaction { state in
      (state.locallyCompletedCleanupRoles ?? []).contains(role.rawValue)
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
  private func transaction<T>(
    writeBack: Bool = true,
    _ body: (inout State) throws -> T
  ) throws -> T {
    let directoryURL = url.deletingLastPathComponent()
    try Self.requirePrivateDirectory(directoryURL)
    let directoryDescriptor = open(
      directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else { throw corrupt() }
    defer { close(directoryDescriptor) }

    let lockName = url.lastPathComponent + ".lock"
    let lockDescriptor = openat(
      directoryDescriptor, lockName, O_CREAT | O_RDWR | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard lockDescriptor >= 0,
      Self.requirePrivateRegularFile(lockDescriptor),
      flock(lockDescriptor, LOCK_EX) == 0
    else {
      if lockDescriptor >= 0 { close(lockDescriptor) }
      throw corrupt()
    }
    defer {
      _ = flock(lockDescriptor, LOCK_UN)
      close(lockDescriptor)
    }

    let ledgerDescriptor = openat(
      directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW
    )
    var state: State
    if ledgerDescriptor >= 0 {
      defer { close(ledgerDescriptor) }
      guard Self.requirePrivateRegularFile(ledgerDescriptor) else { throw corrupt() }
      state = try JSONDecoder().decode(
        State.self, from: Self.readAll(from: ledgerDescriptor)
      )
      guard state.namespace == namespace else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerNamespaceMismatch
      }
    } else if errno == ENOENT {
      state = Self.initialState(namespace: namespace)
    } else {
      throw corrupt()
    }

    let result = try body(&state)
    if writeBack {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try Self.replace(
        try encoder.encode(state), name: url.lastPathComponent,
        directoryDescriptor: directoryDescriptor
      )
    }
    return result
  }

  private static func initialState(namespace: String) -> State {
    State(
      namespace: namespace, deviceEvidenceByRole: [:],
      completedPhasesByRole: [:], recordNamesByZone: [:], evidence: [],
      agreementVerifierPrivateKeysByRole: [:], protectedCommitment: nil,
      transitionOutcomeBytesByPhase: [:], signedRunManifestDigest: nil,
      launchGrantDigestByNonce: nil, credentialBindingDigestByRole: nil,
      credentialIDByRole: nil, removedCredentialRoles: nil,
      cleanupPrepared: nil, frozenCleanupRecordNamesByZone: nil,
      cleanupPrerequisitesCheckpointed: nil, cleanupMarkersByRole: nil,
      locallyCompletedCleanupRoles: nil, credentialCheckpointsByRole: nil,
      activeSignedCleanupRecords: nil, admittedLaunchGrantsByDigest: nil,
      trustedCredentialsByRole: nil, pendingAuditEnvelope: nil
    )
  }

  private static func contentDigest(_ state: State) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.cleanup-ledger-content.v1",
      fields: [(try? encoder.encode(state)) ?? Data()]
    )
  }

  private static func requirePrivateDirectory(_ directoryURL: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch { throw corrupt() }
    var status = stat()
    guard lstat(directoryURL.path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == geteuid(),
      (status.st_mode & 0o777) == 0o700
    else { throw corrupt() }
  }

  private static func requirePrivateRegularFile(_ descriptor: Int32) -> Bool {
    var status = stat()
    return fstat(descriptor, &status) == 0
      && (status.st_mode & S_IFMT) == S_IFREG
      && status.st_uid == geteuid()
      && (status.st_mode & 0o777) == 0o600
  }

  private static func readAll(from descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw corrupt() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      guard count > 0 else { throw corrupt() }
      result.append(contentsOf: buffer.prefix(Int(count)))
    }
  }

  private static func replace(
    _ data: Data, name: String, directoryDescriptor: Int32
  ) throws {
    let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
    let descriptor = openat(
      directoryDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw corrupt() }
    var succeeded = false
    defer {
      close(descriptor)
      if !succeeded { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    try data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = write(descriptor, pointer, remaining)
        guard count > 0 else { throw corrupt() }
        remaining -= count
        pointer = pointer.advanced(by: count)
      }
    }
    guard fsync(descriptor) == 0,
      renameat(directoryDescriptor, temporaryName, directoryDescriptor, name) == 0,
      fsync(directoryDescriptor) == 0
    else { throw corrupt() }
    succeeded = true
  }

  private static func corrupt() -> SecretSyncLiveCloudKitProofConfigurationError {
    .corruptLocalLedger
  }

  private func corrupt() -> SecretSyncLiveCloudKitProofConfigurationError {
    Self.corrupt()
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

  /// Persists the one immutable audit envelope before create-only publication.
  func stageAuditEnvelope(
    _ envelope: SecretSyncLiveSignedArtifactEnvelope
  ) throws {
    try transaction { state in
      if let existing = state.pendingAuditEnvelope {
        guard existing == envelope else {
          throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
        }
      } else {
        state.pendingAuditEnvelope = envelope
      }
    }
  }

  func stagedAuditEnvelope() throws -> SecretSyncLiveSignedArtifactEnvelope? {
    try transaction(writeBack: false) { state in state.pendingAuditEnvelope }
  }

  /// Atomically records audit completion/evidence and destroys the complete
  /// verifier-key set. Any durability failure leaves the prior ledger intact.
  func completeAuditAndEraseVerifierKeys(
    evidence: SecretSyncLiveEvidence
  ) throws {
    try transaction { state in
      guard state.pendingAuditEnvelope != nil else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      var phases = state.completedPhasesByRole[
        SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a.rawValue,
        default: []
      ]
      let audit = SecretSyncLiveCloudKitProofConfiguration.Phase.audit.rawValue
      if !phases.contains(audit) {
        phases.append(audit)
        state.completedPhasesByRole[
          SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a.rawValue
        ] = phases
        state.evidence.append(evidence)
      }
      state.agreementVerifierPrivateKeysByRole.removeAll(
        keepingCapacity: false
      )
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

struct SecretSyncLiveSignedArtifactEnvelope: Codable, Sendable, Equatable {
  let version: Int
  let namespace: String
  let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let phase: SecretSyncLiveCloudKitProofConfiguration.Phase
  let kind: String
  let recordName: String
  let launchNonce: UUID
  let verifiedLaunchGrant: SecretSyncLiveHostLaunchGrant
  let launchGrantDigest: Data
  let runManifestDigest: Data
  let prerequisiteArtifactDigests: [Data]
  let credentialBindingDigest: Data
  let signingPublicKey: SigningPublicKeyDescriptor
  let agreementPublicKey: KeyAgreementPublicKeyDescriptor
  let payload: Data
  let payloadDigest: Data
  let signingTranscript: SecretSyncLivePossessionTranscript
  let signature: Data

  func canonicalBody() throws -> Data {
    try SecretSyncCanonicalEncoding.encode(
      domain: .deviceEnrollmentProof,
      fields: [
        .init(tag: 1, value: Self.uint16(UInt16(version))),
        .init(tag: 2, value: Data("secret-sync/u7-phase-artifact/v1".utf8)),
        .init(tag: 3, value: Data(namespace.utf8)),
        .init(tag: 4, value: Data(role.rawValue.utf8)),
        .init(tag: 5, value: Data(phase.rawValue.utf8)),
        .init(tag: 6, value: Data(kind.utf8)),
        .init(tag: 7, value: Data(recordName.utf8)),
        .init(tag: 8, value: Data(launchNonce.uuidString.lowercased().utf8)),
        .init(tag: 9, value: launchGrantDigest),
        .init(tag: 10, value: runManifestDigest),
        .init(tag: 11, value: Self.frame(prerequisiteArtifactDigests)),
        .init(tag: 12, value: credentialBindingDigest),
        .init(tag: 13, value: signingPublicKey.publicKeyBytes),
        .init(tag: 14, value: agreementPublicKey.publicKeyBytes),
        .init(tag: 15, value: payloadDigest),
      ]
    )
  }

  func artifactDigest() throws -> Data {
    SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.signed-phase-artifact.v1",
      fields: [try canonicalBody(), signature]
    )
  }

  private static func frame(_ fields: [Data]) -> Data {
    var result = Data()
    for field in fields {
      var length = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
      result.append(field)
    }
    return result
  }

  private static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }
}

enum SecretSyncLiveSignedArtifactVerifier {
  static func verify(
    _ envelope: SecretSyncLiveSignedArtifactEnvelope,
    expectedNamespace: String,
    expectedRole: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    expectedPhase: SecretSyncLiveCloudKitProofConfiguration.Phase,
    expectedKind: String,
    expectedRecordName: String,
    approvedLaunchGrant: SecretSyncLiveHostLaunchGrant,
    approvedLaunchGrantDigest: Data,
    approvedRunManifestDigest: Data,
    approvedCredential: TrustedDeviceCredential,
    trustedHostAuthorityPublicKey: Data
  ) throws -> Bool {
    let manifest = approvedLaunchGrant.manifest
    let embeddedBody = try SecretSyncLiveHostLaunchGrantVerifier
      .canonicalManifestBytes(envelope.verifiedLaunchGrant.manifest)
    let embeddedSignature = try P256.Signing.ECDSASignature(
      derRepresentation: envelope.verifiedLaunchGrant.signature
    )
    let authority = try P256.Signing.PublicKey(
      x963Representation: trustedHostAuthorityPublicKey
    )
    let embeddedDigest = SecretSyncLiveHostLaunchGrantVerifier.digest(
      authorityPublicKey: trustedHostAuthorityPublicKey,
      manifestBytes: embeddedBody,
      signature: envelope.verifiedLaunchGrant.signature
    )
    let approvedBody = try SecretSyncLiveHostLaunchGrantVerifier
      .canonicalManifestBytes(approvedLaunchGrant.manifest)
    let approvedDigest = SecretSyncLiveHostLaunchGrantVerifier.digest(
      authorityPublicKey: trustedHostAuthorityPublicKey,
      manifestBytes: approvedBody,
      signature: approvedLaunchGrant.signature
    )
    let credentialBinding = SecretSyncLiveCredentialBinding.digest(
      approvedCredential
    )
    guard envelope.version == 1,
      authority.isValidSignature(embeddedSignature, for: embeddedBody),
      envelope.verifiedLaunchGrant == approvedLaunchGrant,
      approvedDigest == approvedLaunchGrantDigest,
      envelope.verifiedLaunchGrant.manifest.runManifestDigest
        == approvedRunManifestDigest,
      embeddedDigest == envelope.launchGrantDigest,
      envelope.namespace == expectedNamespace,
      envelope.role == expectedRole,
      envelope.phase == expectedPhase,
      envelope.kind == expectedKind,
      envelope.recordName == expectedRecordName,
      manifest.runNamespace == expectedNamespace,
      manifest.role == expectedRole,
      manifest.phase == expectedPhase,
      envelope.launchNonce == manifest.nonce,
      envelope.launchGrantDigest == approvedLaunchGrantDigest,
      envelope.runManifestDigest == approvedRunManifestDigest,
      envelope.prerequisiteArtifactDigests == manifest.prerequisiteArtifactDigests,
      (manifest.phase == .credential
        ? manifest.credentialBindingDigest == nil
          && envelope.credentialBindingDigest == credentialBinding
        : manifest.credentialBindingDigest == credentialBinding
          && envelope.credentialBindingDigest == credentialBinding),
      envelope.payloadDigest == Data(SHA256.hash(data: envelope.payload)),
      envelope.signingPublicKey == approvedCredential.signingPublicKey,
      envelope.agreementPublicKey == approvedCredential.keyAgreementPublicKey,
      envelope.signingTranscript.deviceID == approvedCredential.deviceID,
      envelope.signingTranscript.credentialID == approvedCredential.credentialID,
      envelope.signingTranscript.authorityCredentialID
        == DeviceCredentialID(manifest.nonce),
      envelope.signingTranscript.signingPublicKey
        == approvedCredential.signingPublicKey,
      envelope.signingTranscript.agreementPublicKey
        == approvedCredential.keyAgreementPublicKey,
      envelope.signingTranscript.freshnessCommitment.headCommitDigest.bytes
        == Data(SHA256.hash(data: try envelope.canonicalBody())),
      envelope.signingTranscript.freshnessCommitment.policyDigest.bytes
        == envelope.payloadDigest
    else { return false }
    let challenge = try SecretSyncSigningProofChallenge(
      transcript: envelope.signingTranscript.productionValue()
    )
    let key = try P256.Signing.PublicKey(
      x963Representation: approvedCredential.signingPublicKey.publicKeyBytes
    )
    let signature = try P256.Signing.ECDSASignature(
      rawRepresentation: envelope.signature
    )
    return key.isValidSignature(signature, for: challenge.canonicalBytes)
  }
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

struct SecretSyncLiveRecordReference: Codable, Sendable, Hashable {
  let recordName: String
  let zoneName: String
}
