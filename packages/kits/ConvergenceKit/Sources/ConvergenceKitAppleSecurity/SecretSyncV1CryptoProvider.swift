import ConvergenceKit
import CryptoKit
import Foundation

/// Stable payload-free failures emitted by SecretSync v1 crypto providers.
public enum SecretSyncV1CryptoError: Error, Sendable, Equatable {
  case invalidBinding
  case invalidPublicKeyEncoding
  case invalidSignatureEncoding
  case highSSignature
  case signatureFailure
  case invalidGenerationKey
  case invalidEnvelope
  case invalidPayload
  case authenticationFailed
}

/// Immutable metadata authenticated by every SecretSync v1 ciphertext.
public struct SecretSyncV1BoundContext: Sendable {
  public let scopeID: SecretScopeID
  public let scopeSnapshotDigest: SecretRecordDigest
  public let policyEpoch: UInt64
  public let policyDigest: SecretRecordDigest
  public let generationID: SecretGenerationID
  public let formatVersion: UInt16

  /// Creates a validated v1 context from authoritative policy metadata.
  public init(
    scopeID: SecretScopeID,
    scopeSnapshotDigest: SecretRecordDigest,
    policyEpoch: UInt64,
    policyDigest: SecretRecordDigest,
    generationID: SecretGenerationID,
    formatVersion: UInt16
  ) throws {
    guard policyEpoch > 0, formatVersion == 1 else {
      throw SecretSyncV1CryptoError.invalidBinding
    }
    self.scopeID = scopeID
    self.scopeSnapshotDigest = scopeSnapshotDigest
    self.policyEpoch = policyEpoch
    self.policyDigest = policyDigest
    self.generationID = generationID
    self.formatVersion = formatVersion
  }
}

/// Typed routine-recipient HPKE context.
public struct SecretSyncRecipientEnvelopeContext: Sendable {
  public let boundContext: SecretSyncV1BoundContext
  public let recipientCredentialID: DeviceCredentialID

  /// Creates a recipient-only binding context.
  public init(
    boundContext: SecretSyncV1BoundContext,
    recipientCredentialID: DeviceCredentialID
  ) {
    self.boundContext = boundContext
    self.recipientCredentialID = recipientCredentialID
  }
}

/// Typed break-glass-recovery HPKE context.
public struct SecretSyncRecoveryEnvelopeContext: Sendable {
  public let boundContext: SecretSyncV1BoundContext
  public let recoveryRecipientID: UUID

  /// Creates a recovery-only binding context.
  public init(
    boundContext: SecretSyncV1BoundContext,
    recoveryRecipientID: UUID
  ) {
    self.boundContext = boundContext
    self.recoveryRecipientID = recoveryRecipientID
  }
}

/// Opaque provider-owned 256-bit generation key.
public struct SecretSyncGenerationKey: Sendable {
  let symmetricKey: SymmetricKey

  /// Creates exactly 256 fresh random bits using CryptoKit.
  public static func generate() -> SecretSyncGenerationKey {
    SecretSyncGenerationKey(
      symmetricKey: SymmetricKey(size: .bits256)
    )
  }

  init(openedBytes: Data) throws {
    guard openedBytes.count == 32 else {
      throw SecretSyncV1CryptoError.invalidGenerationKey
    }
    self.init(symmetricKey: SymmetricKey(data: openedBytes))
  }

  // Test-only fixed OPEN fixtures need a known expected key. This remains
  // internal and creates no public raw-key or entropy-injection surface.
  init(fixtureBytes: Data) throws {
    try self.init(openedBytes: fixtureBytes)
  }

  init(symmetricKey: SymmetricKey) {
    self.symmetricKey = symmetricKey
  }

  var bitCount: Int { symmetricKey.bitCount }

  func withUnsafeBytes<Result>(
    _ body: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    try symmetricKey.withUnsafeBytes(body)
  }
}

/// Composition root for the four non-negotiating SecretSync v1 providers.
public struct SecretSyncV1CryptoProvider: Sendable {
  public let digestProvider: SecretSyncSHA256DigestProvider
  public let signatureProvider: SecretSyncP256SignatureProvider
  public let hpkeEnvelopeProvider: SecretSyncHPKEEnvelopeProvider
  public let aesGCMProvider: SecretSyncAESGCMProvider

  /// Creates all providers from one registry-resolved suite.
  public init(suite: SecretSyncAlgorithmSuite) throws {
    try SecretSyncV1SuiteValidator.requireExact(suite)
    digestProvider = try SecretSyncSHA256DigestProvider(suite: suite)
    signatureProvider = try SecretSyncP256SignatureProvider(suite: suite)
    hpkeEnvelopeProvider = try SecretSyncHPKEEnvelopeProvider(suite: suite)
    aesGCMProvider = try SecretSyncAESGCMProvider(suite: suite)
  }
}

enum SecretSyncV1SuiteValidator {
  static func requireExact(_ suite: SecretSyncAlgorithmSuite) throws {
    guard
      suite.suiteID == SecretSyncAlgorithmRegistry.suiteID,
      suite.suiteName == SecretSyncAlgorithmRegistry.suiteName,
      suite.version == SecretSyncAlgorithmRegistry.version,
      suite.digestAlgorithm
        == SecretSyncAlgorithmRegistry.digestAlgorithm,
      suite.signatureAlgorithm
        == SecretSyncAlgorithmRegistry.signatureAlgorithm,
      suite.publicKeyEncoding
        == SecretSyncAlgorithmRegistry.publicKeyEncoding,
      suite.keyEnvelopeAlgorithm
        == SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm,
      suite.payloadAlgorithm
        == SecretSyncAlgorithmRegistry.payloadAlgorithm
    else {
      throw SecretSyncAppleSecurityError.unsupportedSuite
    }
  }
}

/// Sole SSCP binding construction for all SecretSync v1 crypto operations.
enum SecretSyncV1Binding {
  static func recipientBytes(
    context: SecretSyncRecipientEnvelopeContext
  ) throws -> Data {
    try bytes(
      domain: .recipientKeyEnvelope,
      boundContext: context.boundContext,
      roleAndSuiteFields: [
        field(7, uuid(context.recipientCredentialID.rawValue)),
        field(9, Data("routineRecipient".utf8)),
        field(10, uint16(SecretSyncAlgorithmRegistry.suiteID)),
        field(11, Data(SecretSyncAlgorithmRegistry.suiteName.utf8)),
        field(12, uint16(SecretSyncAlgorithmRegistry.version)),
      ]
    )
  }

  static func recoveryBytes(
    context: SecretSyncRecoveryEnvelopeContext
  ) throws -> Data {
    try bytes(
      domain: .recoveryEnvelope,
      boundContext: context.boundContext,
      roleAndSuiteFields: [
        field(7, uuid(context.recoveryRecipientID)),
        field(
          8,
          Data(
            RecoveryEnvelopeUsage.breakGlassRecoveryOnly
              .rawValue.utf8
          )
        ),
        field(10, uint16(SecretSyncAlgorithmRegistry.suiteID)),
        field(11, Data(SecretSyncAlgorithmRegistry.suiteName.utf8)),
        field(12, uint16(SecretSyncAlgorithmRegistry.version)),
      ]
    )
  }

  static func payloadBytes(
    context: SecretSyncV1BoundContext
  ) throws -> Data {
    try bytes(
      domain: .sealedPayload,
      boundContext: context,
      roleAndSuiteFields: [
        field(8, Data("sealedPayload".utf8)),
        field(9, uint16(SecretSyncAlgorithmRegistry.suiteID)),
        field(10, Data(SecretSyncAlgorithmRegistry.suiteName.utf8)),
        field(11, uint16(SecretSyncAlgorithmRegistry.version)),
      ]
    )
  }

  private static func bytes(
    domain: SecretSyncCanonicalDomain,
    boundContext: SecretSyncV1BoundContext,
    roleAndSuiteFields: [SecretSyncCanonicalField]
  ) throws -> Data {
    let boundFields = [
      field(1, uuid(boundContext.scopeID.rawValue)),
      field(2, boundContext.scopeSnapshotDigest.bytes),
      field(3, uint64(boundContext.policyEpoch)),
      field(4, boundContext.policyDigest.bytes),
      field(5, uuid(boundContext.generationID.rawValue)),
      field(6, uint16(boundContext.formatVersion)),
    ]
    return try SecretSyncCanonicalEncoding.encode(
      domain: domain,
      fields: boundFields + roleAndSuiteFields
    )
  }

  private static func field(
    _ tag: UInt16,
    _ value: Data
  ) -> SecretSyncCanonicalField {
    SecretSyncCanonicalField(tag: tag, value: value)
  }

  private static func uuid(_ value: UUID) -> Data {
    Data(value.uuidString.lowercased().utf8)
  }

  private static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func uint64(_ value: UInt64) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }
}
