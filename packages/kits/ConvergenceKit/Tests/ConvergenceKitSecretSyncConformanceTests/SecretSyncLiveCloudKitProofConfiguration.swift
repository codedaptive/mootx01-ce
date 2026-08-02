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
    let cleanupAuthorization: SecretSyncLiveSignedCleanupAuthorization?
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
  static let cleanupAuthorizationKey = "MOOT_SECRET_SYNC_CLEANUP_AUTHORIZATION"
  static let hostAuthorityBundleKey = "MOOTSecretSyncHostAuthorityPublicKey"
  static let canonicalContainerIdentifier = "iCloud.com.codedaptive.simplemachines"

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtimePlatform: SecretSyncLiveRuntimePlatform = .current,
    now: Date = Date()
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    guard let anchor = SecretSyncLiveHostAuthorityTrustAnchor.signedTestBundlePublicKey()
    else { return .invalid(.hostAuthorityMissing) }
    guard let applicationSupportRoot = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first else { return .invalid(.invalidLedgerPath) }
    return load(
      environment: environment, runtimePlatform: runtimePlatform, now: now,
      independentlyAuthenticatedHostAuthorityPublicKey: anchor,
      applicationSupportRoot: applicationSupportRoot
    )
  }

  /// Deterministic tests inject an authority directly; the live entry point
  /// above can only obtain authority from the code-signed XCTest bundle.
  static func loadForDeterministicTesting(
    environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date = Date(),
    independentlyAuthenticatedHostAuthorityPublicKey: Data,
    applicationSupportRoot: URL
  ) -> SecretSyncLiveCloudKitProofConfiguration {
    load(
      environment: environment, runtimePlatform: runtimePlatform, now: now,
      independentlyAuthenticatedHostAuthorityPublicKey:
        independentlyAuthenticatedHostAuthorityPublicKey,
      applicationSupportRoot: applicationSupportRoot
    )
  }

  private static func load(
    environment: [String: String],
    runtimePlatform: SecretSyncLiveRuntimePlatform,
    now: Date,
    independentlyAuthenticatedHostAuthorityPublicKey authorityPublicKey: Data,
    applicationSupportRoot: URL
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
    let cleanupAuthorization: SecretSyncLiveSignedCleanupAuthorization?
    if phase == .cleanup {
      guard let encoded = environment[cleanupAuthorizationKey],
        let data = Data(base64Encoded: encoded),
        let decoded = try? JSONDecoder().decode(
          SecretSyncLiveSignedCleanupAuthorization.self, from: data
        )
      else { return .invalid(.cleanupAuthorizationMissing) }
      let body: Data
      let signature: P256.Signing.ECDSASignature
      let authority: P256.Signing.PublicKey
      do {
        body = try SecretSyncLiveCleanupAuthorizationVerifier
          .canonicalManifestBytes(decoded.manifest)
        signature = try P256.Signing.ECDSASignature(
          derRepresentation: decoded.signature
        )
        authority = try P256.Signing.PublicKey(
          x963Representation: authorityPublicKey
        )
      } catch { return .invalid(.cleanupAuthorizationMalformed) }
      guard authority.isValidSignature(signature, for: body),
        decoded.manifest.version == 1,
        decoded.manifest.namespace == namespace,
        decoded.manifest.runManifestDigest == runManifestDigest,
        decoded.manifest.allowedZones
          == SecretSyncLiveCleanupAuthorizationVerifier.exactZones,
        decoded.manifest.issuedAtUnixSeconds <= Int64(now.timeIntervalSince1970),
        Int64(now.timeIntervalSince1970) < decoded.manifest.expiresAtUnixSeconds,
        decoded.manifest.expiresAtUnixSeconds
          - decoded.manifest.issuedAtUnixSeconds <= 300,
        SecretSyncLiveCleanupAuthorizationVerifier.digest(
          manifestBytes: body, signature: decoded.signature
        ) == grant.manifest.cleanupAuthorizationDigest
      else { return .invalid(.cleanupAuthorizationBindingMismatch) }
      cleanupAuthorization = decoded
    } else {
      guard environment[cleanupAuthorizationKey] == nil else {
        return .invalid(.cleanupAuthorizationBindingMismatch)
      }
      cleanupAuthorization = nil
    }
    return .configured(
      Values(
        containerIdentifier: canonicalContainerIdentifier,
        databaseScope: .private,
        controlZoneID: SecretSyncCloudKitZones.controlZoneID,
        payloadZoneID: SecretSyncCloudKitZones.payloadZoneID,
        runNamespace: namespace,
        deviceRole: role,
        phase: phase,
        ledgerURL: SecretSyncLiveCleanupLedger.derivedURL(
          applicationSupportRoot: applicationSupportRoot,
          logicalLedgerIdentifier: signedRunManifest.manifest.ledgerIdentifier,
          role: role
        ),
        signedRunManifest: signedRunManifest,
        runManifestDigest: runManifestDigest, launchGrant: grant,
        launchGrantDigest: launchGrantDigest,
        cleanupAuthorization: cleanupAuthorization,
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
  case cleanupAuthorizationMissing
  case cleanupAuthorizationMalformed
  case cleanupAuthorizationSignatureInvalid
  case cleanupAuthorizationExpired
  case cleanupAuthorizationBindingMismatch
  case attachmentMalformed
  case attachmentBindingMismatch
  case foreignRoleState
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
    let ledgerIdentifier: String
    let artifactRecordNames: [String]
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
    guard manifest.version == 2, manifest.runNamespace == namespace,
      manifest.ledgerIdentifier == expectedLedgerIdentifier(namespace: namespace),
      !manifest.artifactRecordNames.isEmpty,
      Set(manifest.artifactRecordNames).count == manifest.artifactRecordNames.count
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .signedRunManifestBindingMismatch
    }
    for recordName in manifest.artifactRecordNames {
      try SecretSyncLiveRunOwnedRecordGrammar.requireArtifact(
        recordName: recordName, namespace: namespace
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
      domain: "mootx01.u7.signed-run-manifest.v2",
      fields: [manifestBytes]
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

enum SecretSyncLiveExactJSON {
  static func decode<T: Decodable>(
    _ type: T.Type, from data: Data, exactKeys: Set<String>
  ) throws -> T {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == exactKeys
    else { throw SecretSyncLiveCloudKitProofConfigurationError.attachmentMalformed }
    return try JSONDecoder().decode(type, from: data)
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

struct SecretSyncLiveLedgerProbeAttachment: Codable, Sendable, Equatable {
  static let filename = "u7-ledger-probe-v1.json"
  let version: Int
  let namespace: String
  let ledgerIdentifier: String
  let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let contentDigest: Data

  func validated(
    namespace expectedNamespace: String,
    ledgerIdentifier expectedLedgerIdentifier: String,
    role expectedRole: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> Self {
    guard version == 1, namespace == expectedNamespace,
      ledgerIdentifier == expectedLedgerIdentifier, role == expectedRole,
      contentDigest.count == SHA256.byteCount
    else { throw SecretSyncLiveCloudKitProofConfigurationError.attachmentBindingMismatch }
    return self
  }

  static func decodeExact(_ data: Data) throws -> Self {
    try SecretSyncLiveExactJSON.decode(
      Self.self, from: data,
      exactKeys: ["version", "namespace", "ledgerIdentifier", "role", "contentDigest"]
    )
  }
}

struct SecretSyncLivePhaseReceiptAttachment: Codable, Sendable, Equatable {
  static let filename = "u7-phase-receipt-v1.json"
  let version: Int
  let namespace: String
  let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let phase: SecretSyncLiveCloudKitProofConfiguration.Phase
  let runManifestDigest: Data
  let launchGrantDigest: Data
  let destinationBindingDigest: Data
  let artifactDigest: Data
  let inventoryDigest: Data?
}

struct SecretSyncLiveStageInventoryAttachment: Codable, Sendable, Equatable {
  static let filename = "u7-stage-inventory-v1.json"
  let version: Int
  let namespace: String
  let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  let runManifestDigest: Data
  let launchGrantDigest: Data
  let destinationBindingDigest: Data
  let records: [SecretSyncLiveRecordReference]

  func canonicalDigest() throws -> Data {
    SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.stage-inventory.v1",
      fields: [try SecretSyncLiveExactJSON.encode(self)]
    )
  }

  static func decodeExact(_ data: Data) throws -> Self {
    try SecretSyncLiveExactJSON.decode(
      Self.self, from: data,
      exactKeys: [
        "version", "namespace", "role", "runManifestDigest",
        "launchGrantDigest", "destinationBindingDigest", "records",
      ]
    )
  }
}

struct SecretSyncLiveSignedCleanupAuthorization: Codable, Sendable, Equatable {
  struct Manifest: Codable, Sendable, Equatable {
    let version: Int
    let namespace: String
    let runManifestDigest: Data
    let records: [SecretSyncLiveRecordReference]
    let allowedZones: [String]
    let inventoryDigest: Data
    let issuedAtUnixSeconds: Int64
    let expiresAtUnixSeconds: Int64
    let nonce: UUID
  }

  let manifest: Manifest
  let signature: Data
}

enum SecretSyncLiveCleanupAuthorizationVerifier {
  static let exactZones = [
    SecretSyncCloudKitZones.controlZoneID.zoneName,
    SecretSyncCloudKitZones.payloadZoneID.zoneName,
  ].sorted()

  static func verify(
    _ authorization: SecretSyncLiveSignedCleanupAuthorization,
    trustedAuthorityPublicKey: Data,
    signedRunManifest: SecretSyncLiveSignedRunManifest,
    runManifestDigest: Data,
    inventory: SecretSyncLiveStageInventoryAttachment,
    deterministicHeadRecordName: String,
    now: Date
  ) throws -> Data {
    let manifest = authorization.manifest
    let nowSeconds = Int64(now.timeIntervalSince1970)
    guard manifest.version == 1,
      manifest.namespace == signedRunManifest.manifest.runNamespace,
      manifest.runManifestDigest == runManifestDigest,
      manifest.allowedZones == exactZones,
      manifest.inventoryDigest == (try inventory.canonicalDigest()),
      manifest.issuedAtUnixSeconds <= nowSeconds,
      nowSeconds < manifest.expiresAtUnixSeconds,
      manifest.expiresAtUnixSeconds - manifest.issuedAtUnixSeconds <= 300
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .cleanupAuthorizationBindingMismatch
    }
    let records = manifest.records
    guard !records.isEmpty, Set(records).count == records.count,
      records == records.sorted(by: recordOrder),
      inventory.version == 1, inventory.namespace == manifest.namespace,
      inventory.role == .a, inventory.runManifestDigest == runManifestDigest,
      !inventory.records.isEmpty,
      Set(inventory.records).count == inventory.records.count
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .cleanupAuthorizationBindingMismatch
    }
    let deterministic = signedRunManifest.manifest.artifactRecordNames.map {
      SecretSyncLiveRecordReference(
        recordName: $0,
        zoneName: SecretSyncCloudKitZones.controlZoneID.zoneName
      )
    } + [SecretSyncLiveRecordReference(
      recordName: deterministicHeadRecordName,
      zoneName: SecretSyncCloudKitZones.controlZoneID.zoneName
    )]
    guard Set(inventory.records).isDisjoint(with: Set(deterministic)),
      Set(records) == Set(inventory.records + deterministic)
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .cleanupAuthorizationBindingMismatch
    }
    for record in records {
      try SecretSyncLiveRunOwnedRecordGrammar.requireCleanup(
        record, namespace: manifest.namespace
      )
    }
    let authority: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      authority = try P256.Signing.PublicKey(
        x963Representation: trustedAuthorityPublicKey
      )
      signature = try P256.Signing.ECDSASignature(
        derRepresentation: authorization.signature
      )
    } catch {
      throw SecretSyncLiveCloudKitProofConfigurationError.cleanupAuthorizationMalformed
    }
    let body = try canonicalManifestBytes(manifest)
    guard authority.isValidSignature(signature, for: body) else {
      throw SecretSyncLiveCloudKitProofConfigurationError
        .cleanupAuthorizationSignatureInvalid
    }
    return digest(manifestBytes: body, signature: authorization.signature)
  }

  static func canonicalManifestBytes(
    _ manifest: SecretSyncLiveSignedCleanupAuthorization.Manifest
  ) throws -> Data {
    try SecretSyncLiveExactJSON.encode(manifest)
  }

  static func digest(manifestBytes: Data, signature: Data) -> Data {
    SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.cleanup-authorization.v1",
      fields: [manifestBytes, signature]
    )
  }

  static func recordOrder(
    _ lhs: SecretSyncLiveRecordReference,
    _ rhs: SecretSyncLiveRecordReference
  ) -> Bool {
    lhs.zoneName == rhs.zoneName
      ? lhs.recordName < rhs.recordName
      : lhs.zoneName < rhs.zoneName
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
    let issuedAtUnixSeconds: Int64
    let expiresAtUnixSeconds: Int64
    let runManifestDigest: Data
    let destinationBindingDigest: Data
    let expectedLedgerContentDigest: Data
    let prerequisiteArtifactDigests: [Data]
    let trustedCredentialGrantDigestsByRole: [String: Data]
    let credentialBindingDigest: Data?
    let cleanupAuthorizationDigest: Data?
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
    guard manifest.version == 2, manifest.runNamespace == namespace,
      manifest.role == role, manifest.phase == phase,
      manifest.runManifestDigest == expectedRunManifestDigest,
      manifest.destinationBindingDigest.count == SHA256.byteCount,
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
    let nowSeconds = Int64(now.timeIntervalSince1970)
    guard manifest.issuedAtUnixSeconds <= nowSeconds,
      nowSeconds < manifest.expiresAtUnixSeconds,
      manifest.expiresAtUnixSeconds - manifest.issuedAtUnixSeconds <= 300
    else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantExpired
    }
    guard (phase == .credential) == (manifest.credentialBindingDigest == nil) else {
      throw SecretSyncLiveCloudKitProofConfigurationError.hostLaunchGrantBindingMismatch
    }
    guard (phase == .cleanup) == (manifest.cleanupAuthorizationDigest != nil),
      manifest.cleanupAuthorizationDigest?.count == nil
        || manifest.cleanupAuthorizationDigest?.count == SHA256.byteCount
    else {
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
      domain: "mootx01.u7.host-launch-grant.v2",
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

enum SecretSyncLiveAuditLedgerFault: String, CaseIterable, Sendable {
  case serialization
  case fileSync
  case rename
  case directorySync
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
    var logicalLedgerIdentifier: String
    var role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
    var deviceEvidenceByRole: [String: String]
    var completedPhasesByRole: [String: [String]]
    var recordNamesByZone: [String: [String]]
    var evidence: [SecretSyncLiveEvidence]
    var agreementVerifierPrivateKeysByRole: [String: Data]
    var protectedCommitment: SecretBootstrapFreshnessCommitment?
    var transitionOutcomeBytesByPhase: [String: Data]
    var signedRunManifestDigest: Data
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
    var activeCleanupAuthorizationDigest: Data?
    var activeCleanupRecords: [SecretSyncLiveRecordReference]?
    var pendingAuditEnvelope: SecretSyncLiveSignedArtifactEnvelope?
  }

  private let url: URL
  private let namespace: String
  private let logicalLedgerIdentifier: String
  private let role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  private let signedRunManifestDigest: Data

  init(
    url: URL,
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data
  ) throws {
    self.url = url
    self.namespace = namespace
    self.logicalLedgerIdentifier = logicalLedgerIdentifier
    self.role = role
    self.signedRunManifestDigest = signedRunManifestDigest
    guard url.isFileURL, url.path.hasPrefix("/"),
      logicalLedgerIdentifier
        == SecretSyncLiveSignedRunManifestVerifier.expectedLedgerIdentifier(
          namespace: namespace
        ),
      signedRunManifestDigest.count == SHA256.byteCount,
      url.lastPathComponent == "ledger.json",
      url.deletingLastPathComponent().lastPathComponent == role.rawValue,
      url.deletingLastPathComponent().deletingLastPathComponent()
        .lastPathComponent == logicalLedgerIdentifier
    else { throw SecretSyncLiveCloudKitProofConfigurationError.invalidLedgerPath }
  }

  static func derivedURL(
    applicationSupportRoot: URL,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> URL {
    applicationSupportRoot
      .appendingPathComponent("MOOTSecretSync", isDirectory: true)
      .appendingPathComponent("U7", isDirectory: true)
      .appendingPathComponent(logicalLedgerIdentifier, isDirectory: true)
      .appendingPathComponent(role.rawValue, isDirectory: true)
      .appendingPathComponent("ledger.json", isDirectory: false)
  }

  static func derivedURLForDeterministicTesting(
    applicationSupportRoot: URL,
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) -> URL {
    precondition(
      logicalLedgerIdentifier
        == SecretSyncLiveSignedRunManifestVerifier.expectedLedgerIdentifier(
          namespace: namespace
        )
    )
    return derivedURL(
      applicationSupportRoot: applicationSupportRoot,
      logicalLedgerIdentifier: logicalLedgerIdentifier,
      role: role
    )
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
      let current = Set(Self.recordIDs(from: state))
      guard Set(recordIDs).isSubset(of: current) else {
        throw SecretSyncLiveCloudKitProofConfigurationError.unauthorizedRunRecord
      }
      state.recordNamesByZone = Dictionary(grouping: recordIDs, by: { $0.zoneID.zoneName })
        .mapValues { $0.map(\.recordName).sorted() }
    }
  }

  /// Atomically records successful prerequisite verification and freezes the
  /// first exact cleanup set before any local or CloudKit deletion begins.
  func checkpointCleanupPrerequisites(
    including recordIDs: [CKRecord.ID],
    cleanupAuthorization: SecretSyncLiveSignedCleanupAuthorization
  ) throws -> [CKRecord.ID] {
    let signedReferences = Set(cleanupAuthorization.manifest.records)
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
      let authorizationBytes = try SecretSyncLiveCleanupAuthorizationVerifier
        .canonicalManifestBytes(cleanupAuthorization.manifest)
      let authorizationDigest = SecretSyncLiveCleanupAuthorizationVerifier.digest(
        manifestBytes: authorizationBytes,
        signature: cleanupAuthorization.signature
      )
      guard state.activeCleanupAuthorizationDigest == authorizationDigest,
        state.activeCleanupRecords.map(Set.init) == signedReferences
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
      guard state.role == values.deviceRole,
        state.logicalLedgerIdentifier
          == values.signedRunManifest.manifest.ledgerIdentifier,
        state.signedRunManifestDigest == values.runManifestDigest
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
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
      grants[nonce] = values.launchGrantDigest
      state.launchGrantDigestByNonce = grants
      if values.phase == .cleanup {
        guard let authorization = values.cleanupAuthorization else {
          throw SecretSyncLiveCloudKitProofConfigurationError
            .cleanupAuthorizationMissing
        }
        let body = try SecretSyncLiveCleanupAuthorizationVerifier
          .canonicalManifestBytes(authorization.manifest)
        let digest = SecretSyncLiveCleanupAuthorizationVerifier.digest(
          manifestBytes: body, signature: authorization.signature
        )
        guard digest == values.launchGrant.manifest.cleanupAuthorizationDigest,
          state.activeCleanupAuthorizationDigest == nil
            || state.activeCleanupAuthorizationDigest == digest,
          state.activeCleanupRecords == nil
            || state.activeCleanupRecords == authorization.manifest.records
        else {
          throw SecretSyncLiveCloudKitProofConfigurationError
            .cleanupAuthorizationBindingMismatch
        }
        state.activeCleanupAuthorizationDigest = digest
        state.activeCleanupRecords = authorization.manifest.records
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

  func authorizeCleanup(
    _ authorization: SecretSyncLiveSignedCleanupAuthorization,
    inventory: SecretSyncLiveStageInventoryAttachment,
    signedRunManifest: SecretSyncLiveSignedRunManifest,
    trustedAuthorityPublicKey: Data,
    deterministicHeadRecordName: String,
    now: Date
  ) throws -> Data {
    let digest = try SecretSyncLiveCleanupAuthorizationVerifier.verify(
      authorization,
      trustedAuthorityPublicKey: trustedAuthorityPublicKey,
      signedRunManifest: signedRunManifest,
      runManifestDigest: signedRunManifestDigest,
      inventory: inventory,
      deterministicHeadRecordName: deterministicHeadRecordName,
      now: now
    )
    try transaction { state in
      guard state.role == role,
        state.signedRunManifestDigest == signedRunManifestDigest
      else { throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState }
      if let existing = state.activeCleanupAuthorizationDigest {
        guard existing == digest,
          state.activeCleanupRecords == authorization.manifest.records
        else {
          throw SecretSyncLiveCloudKitProofConfigurationError
            .cleanupAuthorizationBindingMismatch
        }
      } else {
        state.activeCleanupAuthorizationDigest = digest
        state.activeCleanupRecords = authorization.manifest.records
      }
    }
    return digest
  }

  static func initialContentDigest(
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data
  ) -> Data {
    contentDigest(initialState(
      namespace: namespace,
      logicalLedgerIdentifier: logicalLedgerIdentifier,
      role: role,
      signedRunManifestDigest: signedRunManifestDigest
    ))
  }

  func currentContentDigest() throws -> Data {
    try transaction(writeBack: false) { state in Self.contentDigest(state) }
  }

  /// The non-protected probe reads only authenticated local state. A missing
  /// ledger returns the canonical role-bound initial digest without creating it.
  func probeAttachment() throws -> SecretSyncLiveLedgerProbeAttachment {
    SecretSyncLiveLedgerProbeAttachment(
      version: 1, namespace: namespace,
      ledgerIdentifier: logicalLedgerIdentifier, role: role,
      contentDigest: try currentContentDigest()
    )
  }

  static func probeAttachment(
    applicationSupportRoot: URL,
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data
  ) async throws -> SecretSyncLiveLedgerProbeAttachment {
    let url = derivedURL(
      applicationSupportRoot: applicationSupportRoot,
      logicalLedgerIdentifier: logicalLedgerIdentifier, role: role
    )
    var status = stat()
    if lstat(url.path, &status) != 0 {
      guard errno == ENOENT else { throw corrupt() }
      return SecretSyncLiveLedgerProbeAttachment(
        version: 1, namespace: namespace,
        ledgerIdentifier: logicalLedgerIdentifier, role: role,
        contentDigest: initialContentDigest(
          namespace: namespace,
          logicalLedgerIdentifier: logicalLedgerIdentifier,
          role: role,
          signedRunManifestDigest: signedRunManifestDigest
        )
      )
    }
    let ledger = try Self(
      url: url, namespace: namespace,
      logicalLedgerIdentifier: logicalLedgerIdentifier,
      role: role, signedRunManifestDigest: signedRunManifestDigest
    )
    return try await ledger.probeAttachment()
  }

  func checkpointProvisionalCredential(
    _ generation: SecretSyncCustodyCredentialGeneration,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
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
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
    return try transaction(writeBack: false) { state in
      (state.credentialCheckpointsByRole ?? [:])[role.rawValue]
    }
  }

  func markCredentialPublished(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
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
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
    _ = try transaction { state in
      state.credentialCheckpointsByRole?.removeValue(forKey: role.rawValue)
    }
  }

  func storeCredentialForCleanup(
    _ credential: TrustedDeviceCredential,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws {
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
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
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
    return try transaction { state -> DeviceCredentialID? in
      if (state.removedCredentialRoles ?? Set<String>()).contains(role.rawValue) {
        return nil
      }
      guard let rawValue = (state.credentialIDByRole ?? [:])[role.rawValue] else {
        throw SecretSyncLiveCloudKitProofConfigurationError.missingPrerequisitePhase
      }
      return DeviceCredentialID(rawValue)
    }
  }

  func credentialBindingDigest(
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole
  ) throws -> Data {
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
    return try transaction(writeBack: false) { state in
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
    guard role == self.role else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
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
    try withLockedDirectory { directoryDescriptor in
      try Self.materializeCommittedAudit(
        name: url.lastPathComponent,
        namespace: namespace,
        logicalLedgerIdentifier: logicalLedgerIdentifier,
        role: role,
        signedRunManifestDigest: signedRunManifestDigest,
        directoryDescriptor: directoryDescriptor
      )
      var state = try Self.loadState(
        name: url.lastPathComponent,
        namespace: namespace,
        logicalLedgerIdentifier: logicalLedgerIdentifier,
        role: role,
        signedRunManifestDigest: signedRunManifestDigest,
        directoryDescriptor: directoryDescriptor
      )
      let result = try body(&state)
      if writeBack {
        try Self.replace(
          try Self.encode(state), name: url.lastPathComponent,
          directoryDescriptor: directoryDescriptor
        )
      }
      return result
    }
  }

  private func withLockedDirectory<T>(
    _ body: (Int32) throws -> T
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
    return try body(directoryDescriptor)
  }

  private static func loadState(
    name: String,
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data,
    directoryDescriptor: Int32
  ) throws -> State {
    let descriptor = openat(
      directoryDescriptor, name, O_RDONLY | O_NOFOLLOW
    )
    if descriptor >= 0 {
      defer { close(descriptor) }
      guard requirePrivateRegularFile(descriptor) else { throw corrupt() }
      let state = try JSONDecoder().decode(
        State.self, from: readAll(from: descriptor)
      )
      guard state.namespace == namespace,
        state.logicalLedgerIdentifier == logicalLedgerIdentifier,
        state.role == role,
        state.signedRunManifestDigest == signedRunManifestDigest
      else {
        throw SecretSyncLiveCloudKitProofConfigurationError.ledgerNamespaceMismatch
      }
      return state
    }
    guard errno == ENOENT else { throw corrupt() }
    return initialState(
      namespace: namespace,
      logicalLedgerIdentifier: logicalLedgerIdentifier,
      role: role,
      signedRunManifestDigest: signedRunManifestDigest
    )
  }

  private static func encode(_ state: State) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(state)
  }

  private static func auditCandidateName(_ name: String) -> String {
    ".\(name).audit-next"
  }

  private static func auditPreparedName(_ name: String) -> String {
    ".\(name).audit-prepared"
  }

  private static func auditCommittedName(_ name: String) -> String {
    ".\(name).audit-committed"
  }

  private static let auditJournalBytes = Data(
    "mootx01.u7.audit-ledger-commit.v1".utf8
  )

  /// A committed marker selects the key-erased candidate. The canonical
  /// key-bearing slot remains authoritative while only PREPARED exists.
  /// This remains one cohesive lock-held recovery transition so validation,
  /// canonical replacement, and journal cleanup expose no intermediate seam.
  private static func materializeCommittedAudit(
    name: String,
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data,
    directoryDescriptor: Int32
  ) throws {
    let committedName = auditCommittedName(name)
    let committedDescriptor = openat(
      directoryDescriptor, committedName, O_RDONLY | O_NOFOLLOW
    )
    if committedDescriptor < 0 {
      guard errno == ENOENT else { throw corrupt() }
      return
    }
    defer { close(committedDescriptor) }
    guard requirePrivateRegularFile(committedDescriptor),
      try readAll(from: committedDescriptor) == auditJournalBytes
    else { throw corrupt() }

    let candidateName = auditCandidateName(name)
    let candidateDescriptor = openat(
      directoryDescriptor, candidateName, O_RDONLY | O_NOFOLLOW
    )
    guard candidateDescriptor >= 0 else { throw corrupt() }
    defer { close(candidateDescriptor) }
    guard requirePrivateRegularFile(candidateDescriptor) else { throw corrupt() }
    let candidateBytes = try readAll(from: candidateDescriptor)
    let candidate = try JSONDecoder().decode(State.self, from: candidateBytes)
    let audit = SecretSyncLiveCloudKitProofConfiguration.Phase.audit.rawValue
    guard candidate.namespace == namespace,
      candidate.logicalLedgerIdentifier == logicalLedgerIdentifier,
      candidate.role == role,
      candidate.signedRunManifestDigest == signedRunManifestDigest,
      candidate.completedPhasesByRole[
        SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a.rawValue,
        default: []
      ].contains(audit),
      candidate.agreementVerifierPrivateKeysByRole.isEmpty
    else { throw corrupt() }

    // The committed marker and candidate remain recoverable until the
    // canonical replacement and its directory entry are both durable.
    try replace(
      candidateBytes, name: name,
      directoryDescriptor: directoryDescriptor
    )
    try unlinkIfPresent(committedName, directoryDescriptor: directoryDescriptor)
    guard fsync(directoryDescriptor) == 0 else { throw corrupt() }
    try unlinkIfPresent(candidateName, directoryDescriptor: directoryDescriptor)
    try unlinkIfPresent(
      auditPreparedName(name), directoryDescriptor: directoryDescriptor
    )
    guard fsync(directoryDescriptor) == 0 else { throw corrupt() }
  }

  private static func initialState(
    namespace: String,
    logicalLedgerIdentifier: String,
    role: SecretSyncLiveCloudKitProofConfiguration.DeviceRole,
    signedRunManifestDigest: Data
  ) -> State {
    State(
      namespace: namespace, logicalLedgerIdentifier: logicalLedgerIdentifier,
      role: role, deviceEvidenceByRole: [:],
      completedPhasesByRole: [:], recordNamesByZone: [:], evidence: [],
      agreementVerifierPrivateKeysByRole: [:], protectedCommitment: nil,
      transitionOutcomeBytesByPhase: [:],
      signedRunManifestDigest: signedRunManifestDigest,
      launchGrantDigestByNonce: nil, credentialBindingDigestByRole: nil,
      credentialIDByRole: nil, removedCredentialRoles: nil,
      cleanupPrepared: nil, frozenCleanupRecordNamesByZone: nil,
      cleanupPrerequisitesCheckpointed: nil, cleanupMarkersByRole: nil,
      locallyCompletedCleanupRoles: nil, credentialCheckpointsByRole: nil,
      activeCleanupAuthorizationDigest: nil, activeCleanupRecords: nil,
      pendingAuditEnvelope: nil
    )
  }

  private static func contentDigest(_ state: State) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SecretSyncLiveFraming.digest(
      domain: "mootx01.u7.role-local-ledger-content.v2",
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
    _ data: Data,
    name: String,
    directoryDescriptor: Int32,
    failBeforeFileSync: Bool = false
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
    guard !failBeforeFileSync,
      fsync(descriptor) == 0,
      renameat(directoryDescriptor, temporaryName, directoryDescriptor, name) == 0,
      fsync(directoryDescriptor) == 0
    else { throw corrupt() }
    succeeded = true
  }

  private static func unlinkIfPresent(
    _ name: String,
    directoryDescriptor: Int32
  ) throws {
    if unlinkat(directoryDescriptor, name, 0) != 0, errno != ENOENT {
      throw corrupt()
    }
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
    guard self.role == .a else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
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
    guard self.role == .a else {
      throw SecretSyncLiveCloudKitProofConfigurationError.foreignRoleState
    }
    return try transaction { state in
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

  /// Commits audit completion and verifier-key erasure through a two-slot
  /// journal. Until COMMITTED is directory-durable, the prior key-bearing
  /// canonical slot remains authoritative and a retry can safely converge.
  func completeAuditAndEraseVerifierKeys(
    evidence: SecretSyncLiveEvidence,
    injecting fault: SecretSyncLiveAuditLedgerFault? = nil
  ) throws {
    try withLockedDirectory { directoryDescriptor in
      let name = url.lastPathComponent
      try Self.materializeCommittedAudit(
        name: name, namespace: namespace,
        logicalLedgerIdentifier: logicalLedgerIdentifier, role: role,
        signedRunManifestDigest: signedRunManifestDigest,
        directoryDescriptor: directoryDescriptor
      )
      var state = try Self.loadState(
        name: name, namespace: namespace,
        logicalLedgerIdentifier: logicalLedgerIdentifier, role: role,
        signedRunManifestDigest: signedRunManifestDigest,
        directoryDescriptor: directoryDescriptor
      )
      let audit = SecretSyncLiveCloudKitProofConfiguration.Phase.audit.rawValue
      let auditRoleKey = SecretSyncLiveCloudKitProofConfiguration.DeviceRole.a.rawValue
      if state.completedPhasesByRole[auditRoleKey, default: []].contains(audit) {
        guard state.agreementVerifierPrivateKeysByRole.isEmpty else {
          throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
        }
        return
      }
      guard state.pendingAuditEnvelope != nil else {
        throw SecretSyncLiveCloudKitProofConfigurationError.incompleteAudit
      }
      var phases = state.completedPhasesByRole[auditRoleKey, default: []]
      if !phases.contains(audit) {
        phases.append(audit)
        state.completedPhasesByRole[auditRoleKey] = phases
        state.evidence.append(evidence)
      }
      state.agreementVerifierPrivateKeysByRole.removeAll(
        keepingCapacity: false
      )

      guard fault != .serialization else { throw Self.corrupt() }
      let candidateBytes = try Self.encode(state)
      let candidateName = Self.auditCandidateName(name)
      let preparedName = Self.auditPreparedName(name)
      let committedName = Self.auditCommittedName(name)

      // An interrupted prior attempt can leave only PREPARED artifacts. They
      // never override canonical state and are safe to replace under the lock.
      try Self.unlinkIfPresent(preparedName, directoryDescriptor: directoryDescriptor)
      try Self.unlinkIfPresent(candidateName, directoryDescriptor: directoryDescriptor)
      guard fsync(directoryDescriptor) == 0 else { throw Self.corrupt() }
      try Self.replace(
        candidateBytes, name: candidateName,
        directoryDescriptor: directoryDescriptor,
        failBeforeFileSync: fault == .fileSync
      )
      try Self.replace(
        Self.auditJournalBytes, name: preparedName,
        directoryDescriptor: directoryDescriptor
      )
      guard fault != .rename,
        renameat(
          directoryDescriptor, preparedName,
          directoryDescriptor, committedName
        ) == 0
      else { throw Self.corrupt() }

      if fault == .directorySync || fsync(directoryDescriptor) != 0 {
        // A failed final directory sync cannot authorize the key-erased slot.
        // Roll the selector back before reporting the failure. If the host
        // dies first, recovery sees either PREPARED (old state) or COMMITTED
        // (durable candidate), both of which are deterministic and retry-safe.
        guard renameat(
          directoryDescriptor, committedName,
          directoryDescriptor, preparedName
        ) == 0,
          fsync(directoryDescriptor) == 0
        else { throw Self.corrupt() }
        throw Self.corrupt()
      }
      // The selector is now durable, so replacing canonical cannot lose the
      // commit. Finish by removing the prior key-bearing snapshot before the
      // successful call returns; any interruption is recovered from COMMITTED.
      try Self.materializeCommittedAudit(
        name: name, namespace: namespace,
        logicalLedgerIdentifier: logicalLedgerIdentifier, role: role,
        signedRunManifestDigest: signedRunManifestDigest,
        directoryDescriptor: directoryDescriptor
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
    expectedLaunchGrantDigest: Data,
    expectedRunManifestDigest: Data,
    expectedPlatform: SecretSyncLiveRuntimePlatform,
    expectedDestinationBindingDigest: Data,
    credentialArtifact: SecretSyncLiveCredentialEvidence,
    trustedHostAuthorityPublicKey: Data
  ) throws -> Bool {
    let manifest = envelope.verifiedLaunchGrant.manifest
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
    let credentialBinding = SecretSyncLiveCredentialBinding.digest(
      credentialArtifact.credential
    )
    let credentialTranscript = try credentialArtifact.possessionTranscript
      .productionValue()
    let credentialChallenge = try SecretSyncSigningProofChallenge(
      transcript: credentialTranscript
    )
    let credentialKey = try P256.Signing.PublicKey(
      x963Representation: credentialArtifact.credential.signingPublicKey
        .publicKeyBytes
    )
    let credentialSignature = try P256.Signing.ECDSASignature(
      rawRepresentation: credentialArtifact.signingProof
    )
    guard envelope.version == 1,
      authority.isValidSignature(embeddedSignature, for: embeddedBody),
      envelope.verifiedLaunchGrant.manifest.runManifestDigest
        == expectedRunManifestDigest,
      embeddedDigest == envelope.launchGrantDigest,
      embeddedDigest == expectedLaunchGrantDigest,
      envelope.namespace == expectedNamespace,
      envelope.role == expectedRole,
      envelope.phase == expectedPhase,
      envelope.kind == expectedKind,
      envelope.recordName == expectedRecordName,
      manifest.runNamespace == expectedNamespace,
      manifest.role == expectedRole,
      manifest.phase == expectedPhase,
      manifest.platform == expectedPlatform,
      manifest.destinationBindingDigest == expectedDestinationBindingDigest,
      envelope.launchNonce == manifest.nonce,
      envelope.runManifestDigest == expectedRunManifestDigest,
      envelope.prerequisiteArtifactDigests == manifest.prerequisiteArtifactDigests,
      manifest.trustedCredentialGrantDigestsByRole[expectedRole.rawValue]
        == credentialArtifact.launchGrantDigest,
      (manifest.phase == .credential
        ? manifest.credentialBindingDigest == nil
          && envelope.credentialBindingDigest == credentialBinding
        : manifest.credentialBindingDigest == credentialBinding
          && envelope.credentialBindingDigest == credentialBinding),
      envelope.payloadDigest == Data(SHA256.hash(data: envelope.payload)),
      credentialChallenge.canonicalBytes == credentialArtifact.signingChallenge,
      credentialKey.isValidSignature(
        credentialSignature, for: credentialChallenge.canonicalBytes
      ),
      credentialTranscript.deviceID == credentialArtifact.credential.deviceID,
      credentialTranscript.credentialID == credentialArtifact.credential.credentialID,
      credentialTranscript.signingPublicKey
        == credentialArtifact.credential.signingPublicKey,
      credentialTranscript.agreementPublicKey
        == credentialArtifact.credential.keyAgreementPublicKey,
      envelope.signingPublicKey == credentialArtifact.credential.signingPublicKey,
      envelope.agreementPublicKey == credentialArtifact.credential.keyAgreementPublicKey,
      envelope.signingTranscript.deviceID == credentialArtifact.credential.deviceID,
      envelope.signingTranscript.credentialID == credentialArtifact.credential.credentialID,
      envelope.signingTranscript.authorityCredentialID
        == DeviceCredentialID(manifest.nonce),
      envelope.signingTranscript.signingPublicKey
        == credentialArtifact.credential.signingPublicKey,
      envelope.signingTranscript.agreementPublicKey
        == credentialArtifact.credential.keyAgreementPublicKey,
      envelope.signingTranscript.freshnessCommitment.headCommitDigest.bytes
        == Data(SHA256.hash(data: try envelope.canonicalBody())),
      envelope.signingTranscript.freshnessCommitment.policyDigest.bytes
        == envelope.payloadDigest
    else { return false }
    let challenge = try SecretSyncSigningProofChallenge(
      transcript: envelope.signingTranscript.productionValue()
    )
    let key = try P256.Signing.PublicKey(
      x963Representation: credentialArtifact.credential.signingPublicKey.publicKeyBytes
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
