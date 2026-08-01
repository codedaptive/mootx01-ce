import ConvergenceKit
import CryptoKit
import Foundation

enum SecretSyncRecoveryKeyRole: Sendable {
  case agreement
  case authorizationSigning

  var label: String {
    switch self {
    case .agreement:
      return "mootx01.secret-sync/global-recovery/agreement-p256/v2"
    case .authorizationSigning:
      return "mootx01.secret-sync/global-recovery/authorization-signing-p256/v2"
    }
  }

  var keyIdentifierDomain: String {
    switch self {
    case .agreement:
      return "mootx01.secret-recovery.agreement-key-id.v1"
    case .authorizationSigning:
      return "mootx01.secret-recovery.authorization-signing-key-id.v1"
    }
  }

  var algorithmIdentifier: String {
    switch self {
    case .agreement:
      return RecoveryRecipientDescriptor.agreementAlgorithmIdentifier
    case .authorizationSigning:
      return RecoveryRecipientDescriptor.authorizationSigningAlgorithmIdentifier
    }
  }
}

struct SecretSyncRecoveryDerivedMaterial: Sendable {
  let descriptor: RecoveryRecipientDescriptor
  let agreementPrivateKey: P256.KeyAgreement.PrivateKey
  let authorizationSigningPrivateKey: P256.Signing.PrivateKey
  let agreementCounter: UInt32
  let authorizationSigningCounter: UInt32
}

/// Frozen HKDF-SHA256/P-256 rejection derivation for both recovery roles.
struct SecretSyncRecoverySeedDerivation: Sendable {
  typealias Expand = @Sendable (
    Data,
    SecretSyncRecoveryKeyRole,
    UInt32
  ) throws -> Data

  static let suiteIdentifier =
    "mootx01.secret-recovery.hkdf-sha256-p256-rejection.v2"
  static let salt = Data(
    "mootx01.secret-sync/global-recovery/master-seed/v2".utf8
  )
  private static let p256Order = Data([
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
    0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
  ])

  private let expand: Expand

  init(expand: @escaping Expand = Self.hkdfExpand) {
    self.expand = expand
  }

  func derive(
    masterSeed: Data,
    recoveryRecipientID: UUID
  ) throws -> SecretSyncRecoveryDerivedMaterial {
    guard masterSeed.count == 32 else {
      throw SecretSyncRecoveryError.invalidMasterSeed
    }
    let agreement = try deriveScalar(seed: masterSeed, role: .agreement)
    let authorization = try deriveScalar(
      seed: masterSeed,
      role: .authorizationSigning
    )
    guard agreement.scalar != authorization.scalar else {
      throw SecretSyncRecoveryError.roleCollision
    }
    let agreementKey: P256.KeyAgreement.PrivateKey
    let authorizationKey: P256.Signing.PrivateKey
    do {
      agreementKey = try P256.KeyAgreement.PrivateKey(
        rawRepresentation: agreement.scalar
      )
      authorizationKey = try P256.Signing.PrivateKey(
        rawRepresentation: authorization.scalar
      )
    } catch {
      throw SecretSyncRecoveryError.derivationExhausted
    }
    let agreementPublic = agreementKey.publicKey.x963Representation
    let authorizationPublic = authorizationKey.publicKey.x963Representation
    guard agreementPublic != authorizationPublic else {
      throw SecretSyncRecoveryError.roleCollision
    }
    guard
      let agreementID = Self.keyIdentifier(
        role: .agreement,
        publicKey: agreementPublic
      ),
      let authorizationID = Self.keyIdentifier(
        role: .authorizationSigning,
        publicKey: authorizationPublic
      ),
      agreementID != authorizationID
    else {
      throw SecretSyncRecoveryError.roleCollision
    }
    let agreementDescriptor = try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncRecoveryKeyRole.agreement
        .algorithmIdentifier,
      keyIdentifier: agreementID,
      publicKeyBytes: agreementPublic
    )
    let authorizationDescriptor = try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncRecoveryKeyRole.authorizationSigning
        .algorithmIdentifier,
      keyIdentifier: authorizationID,
      publicKeyBytes: authorizationPublic
    )
    return try SecretSyncRecoveryDerivedMaterial(
      descriptor: RecoveryRecipientDescriptor(
        recoveryRecipientID: recoveryRecipientID,
        keyAgreementPublicKey: agreementDescriptor,
        authorizationSigningPublicKey: authorizationDescriptor
      ),
      agreementPrivateKey: agreementKey,
      authorizationSigningPrivateKey: authorizationKey,
      agreementCounter: agreement.counter,
      authorizationSigningCounter: authorization.counter
    )
  }

  static func keyIdentifier(
    role: SecretSyncRecoveryKeyRole,
    publicKey: Data
  ) -> Data? {
    guard publicKey.count == 65, publicKey.first == 0x04 else {
      return nil
    }
    let domain = Data(role.keyIdentifierDomain.utf8)
    let algorithm = Data(role.algorithmIdentifier.utf8)
    guard
      domain.count <= Int(UInt16.max),
      algorithm.count <= Int(UInt16.max),
      publicKey.count <= Int(UInt16.max)
    else {
      return nil
    }
    var frame = Data()
    frame.append(uint16(UInt16(domain.count)))
    frame.append(domain)
    frame.append(uint16(UInt16(algorithm.count)))
    frame.append(algorithm)
    frame.append(uint16(UInt16(publicKey.count)))
    frame.append(publicKey)
    return Data(SHA256.hash(data: frame))
  }

  private func deriveScalar(
    seed: Data,
    role: SecretSyncRecoveryKeyRole
  ) throws -> (scalar: Data, counter: UInt32) {
    var counter: UInt32 = 0
    while true {
      let candidate = try expand(seed, role, counter)
      guard candidate.count == 32 else {
        throw SecretSyncRecoveryError.derivationExhausted
      }
      if !candidate.allSatisfy({ $0 == 0 }),
         candidate.lexicographicallyPrecedes(Self.p256Order)
      {
        return (candidate, counter)
      }
      guard counter < UInt32.max else {
        throw SecretSyncRecoveryError.derivationExhausted
      }
      counter += 1
    }
  }

  private static func hkdfExpand(
    seed: Data,
    role: SecretSyncRecoveryKeyRole,
    counter: UInt32
  ) throws -> Data {
    var counterBE = counter.bigEndian
    let counterBytes = withUnsafeBytes(of: &counterBE) { Data($0) }
    let info = Data(role.label.utf8) + Data([0]) + counterBytes
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: seed),
      salt: Self.salt,
      info: info,
      outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
  }

  private static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }
}
