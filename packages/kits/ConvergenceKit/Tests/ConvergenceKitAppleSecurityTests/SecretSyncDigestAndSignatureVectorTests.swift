import ConvergenceKit
import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync v1 digest and signature vectors")
struct SecretSyncDigestAndSignatureVectorTests {
  @Test("SHA-256 matches the fixed digest vector")
  func fixedDigest() throws {
    let provider = try SecretSyncSHA256DigestProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let digest = try provider.digest(
      canonicalBytes: SecretSyncV1GoldenVectors.digestInput
    )
    #expect(digest.bytes == SecretSyncV1GoldenVectors.digestOutput)
  }

  @Test("fixed raw64 low-S signature verifies")
  func fixedSignatureVerify() throws {
    let provider = try SecretSyncP256SignatureProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let verified = try provider.verify(
      signature: SecretSyncV1GoldenVectors.lowSRawSignature,
      canonicalBytes: SecretSyncV1GoldenVectors.signatureMessage,
      signingPublicKey: SecretSyncV1GoldenVectors.signingDescriptor()
    )
    #expect(verified)
  }

  @Test("runtime signatures are raw64, low-S, and verifiable")
  func runtimeSignatures() throws {
    let provider = try SecretSyncP256SignatureProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let privateKey = P256.Signing.PrivateKey()
    let descriptor = try SecretSyncV1GoldenVectors.signingDescriptor(
      bytes: privateKey.publicKey.x963Representation
    )

    for message in [Data("runtime-one".utf8), Data("runtime-two".utf8)] {
      let signature = try provider.sign(
        canonicalBytes: message,
        using: privateKey
      )
      #expect(signature.count == 64)
      #expect(SecretSyncP256SignatureProvider.isLowS(signature))
      #expect(
        try provider.verify(
          signature: signature,
          canonicalBytes: message,
          signingPublicKey: descriptor
        )
      )
    }
  }
}
