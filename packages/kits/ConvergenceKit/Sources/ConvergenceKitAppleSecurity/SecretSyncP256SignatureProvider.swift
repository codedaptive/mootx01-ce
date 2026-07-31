import ConvergenceKit
import CryptoKit
import Foundation

/// CryptoKit P-256 signer and strict raw64 verifier for SecretSync v1.
public struct SecretSyncP256SignatureProvider:
  SecretSignatureVerifying,
  Sendable
{
  // SEC 2 P-256 order and its floor-divided-by-two low-S ceiling. These
  // constants validate representation scalars; CryptoKit still performs all
  // signing and signature verification arithmetic.
  private static let order = Data([
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
    0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
  ])
  private static let halfOrder = Data([
    0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
    0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
  ])

  /// Creates a signature provider only for the registry-resolved v1 suite.
  public init(suite: SecretSyncAlgorithmSuite) throws {
    try SecretSyncV1SuiteValidator.requireExact(suite)
  }

  /// Signs canonical bytes and returns exactly `r[32] || s[32]` with low-S.
  public func sign(
    canonicalBytes: Data,
    using privateKey: P256.Signing.PrivateKey
  ) throws -> Data {
    let created: P256.Signing.ECDSASignature
    do {
      created = try privateKey.signature(for: canonicalBytes)
    } catch {
      throw SecretSyncV1CryptoError.signatureFailure
    }

    var raw = created.rawRepresentation
    guard raw.count == 64 else {
      throw SecretSyncV1CryptoError.signatureFailure
    }
    let s = Data(raw.suffix(32))
    if Self.compare(s, Self.halfOrder) > 0 {
      raw.replaceSubrange(32..<64, with: Self.subtract(Self.order, s))
    }

    do {
      let canonical = try P256.Signing.ECDSASignature(
        rawRepresentation: raw
      )
      guard
        privateKey.publicKey.isValidSignature(
          canonical,
          for: canonicalBytes
        )
      else {
        throw SecretSyncV1CryptoError.signatureFailure
      }
    } catch let error as SecretSyncV1CryptoError {
      throw error
    } catch {
      throw SecretSyncV1CryptoError.signatureFailure
    }
    return raw
  }

  /// Verifies one exact raw64 low-S signature and exact X9.63 public key.
  public func verify(
    signature: Data,
    canonicalBytes: Data,
    signingPublicKey: SigningPublicKeyDescriptor
  ) throws -> Bool {
    let publicKey = try Self.publicKey(from: signingPublicKey)
    try Self.validateRawSignature(signature)
    let parsed: P256.Signing.ECDSASignature
    do {
      parsed = try P256.Signing.ECDSASignature(
        rawRepresentation: signature
      )
    } catch {
      throw SecretSyncV1CryptoError.invalidSignatureEncoding
    }
    return publicKey.isValidSignature(parsed, for: canonicalBytes)
  }

  static func isLowS(_ signature: Data) -> Bool {
    guard signature.count == 64 else { return false }
    let s = Data(signature.suffix(32))
    return !Self.isZero(s) && Self.compare(s, Self.halfOrder) <= 0
  }

  static func highSTwin(_ signature: Data) -> Data {
    precondition(signature.count == 64)
    var result = signature
    let lowS = Data(signature.suffix(32))
    result.replaceSubrange(32..<64, with: Self.subtract(Self.order, lowS))
    return result
  }

  private static func publicKey(
    from descriptor: SigningPublicKeyDescriptor
  ) throws -> P256.Signing.PublicKey {
    guard
      descriptor.algorithmIdentifier
        == SecretSyncAlgorithmRegistry.publicKeyEncoding,
      descriptor.publicKeyBytes.count == 65,
      descriptor.publicKeyBytes.first == 0x04
    else {
      throw SecretSyncV1CryptoError.invalidPublicKeyEncoding
    }
    do {
      return try P256.Signing.PublicKey(
        x963Representation: descriptor.publicKeyBytes
      )
    } catch {
      throw SecretSyncV1CryptoError.invalidPublicKeyEncoding
    }
  }

  private static func validateRawSignature(_ signature: Data) throws {
    guard signature.count == 64 else {
      throw SecretSyncV1CryptoError.invalidSignatureEncoding
    }
    let r = Data(signature.prefix(32))
    let s = Data(signature.suffix(32))
    guard
      !isZero(r),
      !isZero(s),
      compare(r, order) < 0,
      compare(s, order) < 0
    else {
      throw SecretSyncV1CryptoError.invalidSignatureEncoding
    }
    guard compare(s, halfOrder) <= 0 else {
      throw SecretSyncV1CryptoError.highSSignature
    }
  }

  private static func isZero(_ scalar: Data) -> Bool {
    scalar.allSatisfy { $0 == 0 }
  }

  private static func compare(_ lhs: Data, _ rhs: Data) -> Int {
    for (left, right) in zip(lhs, rhs) {
      if left < right { return -1 }
      if left > right { return 1 }
    }
    return 0
  }

  // Fixed-width subtraction is limited to representation canonicalization;
  // it does not implement ECDSA signing or verification.
  private static func subtract(_ lhs: Data, _ rhs: Data) -> Data {
    let left = [UInt8](lhs)
    let right = [UInt8](rhs)
    var output = [UInt8](repeating: 0, count: left.count)
    var borrow = 0
    for index in stride(from: left.count - 1, through: 0, by: -1) {
      var value = Int(left[index]) - Int(right[index]) - borrow
      if value < 0 {
        value += 256
        borrow = 1
      } else {
        borrow = 0
      }
      output[index] = UInt8(value)
    }
    return Data(output)
  }
}
