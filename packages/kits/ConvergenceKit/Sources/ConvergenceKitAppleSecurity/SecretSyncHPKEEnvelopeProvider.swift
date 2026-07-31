import ConvergenceKit
import CryptoKit
import Foundation

/// CryptoKit HPKE P-256 envelope operations for the closed v1 suite.
public struct SecretSyncHPKEEnvelopeProvider: Sendable {
  private static let encapsulatedKeyByteCount = 65
  private static let wrappedKeyByteCount = 113

  /// Creates an HPKE provider only for the registry-resolved v1 suite.
  public init(suite: SecretSyncAlgorithmSuite) throws {
    try SecretSyncV1SuiteValidator.requireExact(suite)
  }

  /// Wraps one 256-bit generation key for a routine recipient.
  public func sealGenerationKey(
    _ generationKey: SecretSyncGenerationKey,
    for recipientPublicKey: KeyAgreementPublicKeyDescriptor,
    context: SecretSyncRecipientEnvelopeContext
  ) throws -> Data {
    let publicKey = try Self.publicKey(from: recipientPublicKey)
    let bindingBytes = try Self.recipientBinding(context)
    return try Self.seal(
      generationKey,
      for: publicKey,
      bindingBytes: bindingBytes
    )
  }

  /// Opens one routine-recipient envelope into an opaque generation key.
  public func openRecipientGenerationKey(
    _ wrappedKeyBytes: Data,
    using privateKey: P256.KeyAgreement.PrivateKey,
    context: SecretSyncRecipientEnvelopeContext
  ) throws -> SecretSyncGenerationKey {
    let bindingBytes = try Self.recipientBinding(context)
    return try Self.open(
      wrappedKeyBytes,
      using: privateKey,
      bindingBytes: bindingBytes
    )
  }

  /// Wraps one 256-bit generation key for the break-glass recipient.
  public func sealRecoveryGenerationKey(
    _ generationKey: SecretSyncGenerationKey,
    for recoveryPublicKey: KeyAgreementPublicKeyDescriptor,
    context: SecretSyncRecoveryEnvelopeContext
  ) throws -> Data {
    let publicKey = try Self.publicKey(from: recoveryPublicKey)
    let bindingBytes = try Self.recoveryBinding(context)
    return try Self.seal(
      generationKey,
      for: publicKey,
      bindingBytes: bindingBytes
    )
  }

  /// Opens one recovery envelope into an opaque generation key.
  public func openRecoveryGenerationKey(
    _ wrappedKeyBytes: Data,
    using privateKey: P256.KeyAgreement.PrivateKey,
    context: SecretSyncRecoveryEnvelopeContext
  ) throws -> SecretSyncGenerationKey {
    let bindingBytes = try Self.recoveryBinding(context)
    return try Self.open(
      wrappedKeyBytes,
      using: privateKey,
      bindingBytes: bindingBytes
    )
  }

  private static func publicKey(
    from descriptor: KeyAgreementPublicKeyDescriptor
  ) throws -> P256.KeyAgreement.PublicKey {
    guard
      descriptor.algorithmIdentifier
        == SecretSyncAlgorithmRegistry.publicKeyEncoding,
      descriptor.publicKeyBytes.count == encapsulatedKeyByteCount,
      descriptor.publicKeyBytes.first == 0x04
    else {
      throw SecretSyncV1CryptoError.invalidPublicKeyEncoding
    }
    do {
      return try P256.KeyAgreement.PublicKey(
        x963Representation: descriptor.publicKeyBytes
      )
    } catch {
      throw SecretSyncV1CryptoError.invalidPublicKeyEncoding
    }
  }

  private static func seal(
    _ generationKey: SecretSyncGenerationKey,
    for publicKey: P256.KeyAgreement.PublicKey,
    bindingBytes: Data
  ) throws -> Data {
    do {
      var sender = try HPKE.Sender(
        recipientKey: publicKey,
        ciphersuite: .P256_SHA256_AES_GCM_256,
        info: bindingBytes
      )
      // The temporary key bytes exist only for this CryptoKit call and
      // are not retained, returned, logged, or exposed by the wrapper.
      let ciphertext = try generationKey.withUnsafeBytes { bytes in
        try sender.seal(Data(bytes), authenticating: bindingBytes)
      }
      let wrapped = sender.encapsulatedKey + ciphertext
      guard
        sender.encapsulatedKey.count == encapsulatedKeyByteCount,
        sender.encapsulatedKey.first == 0x04,
        wrapped.count == wrappedKeyByteCount
      else {
        throw SecretSyncV1CryptoError.invalidEnvelope
      }
      return wrapped
    } catch let error as SecretSyncV1CryptoError {
      throw error
    } catch {
      throw SecretSyncV1CryptoError.invalidEnvelope
    }
  }

  private static func open(
    _ wrappedKeyBytes: Data,
    using privateKey: P256.KeyAgreement.PrivateKey,
    bindingBytes: Data
  ) throws -> SecretSyncGenerationKey {
    // Keep structural parsing and authenticated opening contiguous so each
    // failure class collapses to its fixed public error without retaining a
    // CryptoKit error or partially constructed generation key.
    guard
      wrappedKeyBytes.count == wrappedKeyByteCount,
      wrappedKeyBytes.first == 0x04
    else {
      throw SecretSyncV1CryptoError.invalidEnvelope
    }
    let encapsulatedKey = Data(
      wrappedKeyBytes.prefix(encapsulatedKeyByteCount)
    )
    let ciphertext = Data(
      wrappedKeyBytes.dropFirst(encapsulatedKeyByteCount)
    )

    var recipient: HPKE.Recipient
    do {
      recipient = try HPKE.Recipient(
        privateKey: privateKey,
        ciphersuite: .P256_SHA256_AES_GCM_256,
        info: bindingBytes,
        encapsulatedKey: encapsulatedKey
      )
    } catch {
      throw SecretSyncV1CryptoError.invalidEnvelope
    }

    let opened: Data
    do {
      opened = try recipient.open(
        ciphertext,
        authenticating: bindingBytes
      )
    } catch {
      throw SecretSyncV1CryptoError.authenticationFailed
    }
    guard opened.count == 32 else {
      throw SecretSyncV1CryptoError.invalidGenerationKey
    }
    return try SecretSyncGenerationKey(openedBytes: opened)
  }

  private static func recipientBinding(
    _ context: SecretSyncRecipientEnvelopeContext
  ) throws -> Data {
    do {
      return try SecretSyncV1Binding.recipientBytes(context: context)
    } catch {
      throw SecretSyncV1CryptoError.invalidBinding
    }
  }

  private static func recoveryBinding(
    _ context: SecretSyncRecoveryEnvelopeContext
  ) throws -> Data {
    do {
      return try SecretSyncV1Binding.recoveryBytes(context: context)
    } catch {
      throw SecretSyncV1CryptoError.invalidBinding
    }
  }
}
