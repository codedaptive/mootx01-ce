import CryptoKit
import Foundation

/// CryptoKit AES-256-GCM payload operations for SecretSync v1.
public struct SecretSyncAESGCMProvider: Sendable {
  private static let minimumCombinedByteCount = 28

  /// Creates a payload provider only for the registry-resolved v1 suite.
  public init(suite: SecretSyncAlgorithmSuite) throws {
    try SecretSyncV1SuiteValidator.requireExact(suite)
  }

  /// Seals plaintext with a fresh CryptoKit-generated nonce and bound AAD.
  public func seal(
    plaintext: Data,
    using generationKey: SecretSyncGenerationKey,
    context: SecretSyncV1BoundContext
  ) throws -> Data {
    let bindingBytes = try Self.payloadBinding(context)
    do {
      let sealed = try AES.GCM.seal(
        plaintext,
        using: generationKey.symmetricKey,
        authenticating: bindingBytes
      )
      guard let combined = sealed.combined else {
        throw SecretSyncV1CryptoError.invalidPayload
      }
      return combined
    } catch let error as SecretSyncV1CryptoError {
      throw error
    } catch {
      throw SecretSyncV1CryptoError.invalidPayload
    }
  }

  /// Opens exact `nonce[12] || ciphertext || tag[16]` payload bytes.
  public func open(
    sealedBytes: Data,
    using generationKey: SecretSyncGenerationKey,
    context: SecretSyncV1BoundContext
  ) throws -> Data {
    guard sealedBytes.count >= Self.minimumCombinedByteCount else {
      throw SecretSyncV1CryptoError.invalidPayload
    }
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.SealedBox(combined: sealedBytes)
    } catch {
      throw SecretSyncV1CryptoError.invalidPayload
    }
    let bindingBytes = try Self.payloadBinding(context)
    do {
      return try AES.GCM.open(
        box,
        using: generationKey.symmetricKey,
        authenticating: bindingBytes
      )
    } catch {
      throw SecretSyncV1CryptoError.authenticationFailed
    }
  }

  private static func payloadBinding(
    _ context: SecretSyncV1BoundContext
  ) throws -> Data {
    do {
      return try SecretSyncV1Binding.payloadBytes(context: context)
    } catch {
      throw SecretSyncV1CryptoError.invalidBinding
    }
  }
}
