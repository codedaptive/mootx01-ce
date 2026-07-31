import ConvergenceKit
import CryptoKit
import Foundation

@testable import ConvergenceKitAppleSecurity

/// Software-only custody used by the AppleSecurity test target.
///
/// Keeping this type under `Tests/` makes simulator coverage possible without
/// creating a software fallback in the shipping AppleSecurity product.
actor SecretSyncTestOnlyCustodyProvider:
  SecretSyncSigningPublicCredentialRetrieving,
  SecretSyncKeyAgreementPublicCredentialRetrieving,
  SecretSyncSigningKeyCustody,
  SecretSyncKeyAgreementKeyCustody
{
  struct Generation: Sendable {
    let deviceID: TrustedDeviceID
    let credentialID: DeviceCredentialID
    let signingHandle: SigningPrivateKeyHandle
    let agreementHandle: KeyAgreementPrivateKeyHandle
    let signingPublicKey: SigningPublicKeyDescriptor
    let agreementPublicKey: KeyAgreementPublicKeyDescriptor
  }

  private struct Keys: Sendable {
    let generation: Generation
    let signing: P256.Signing.PrivateKey
    let agreement: P256.KeyAgreement.PrivateKey
  }

  private var keysByCredential: [DeviceCredentialID: Keys] = [:]

  func createGeneration(for deviceID: TrustedDeviceID) throws -> Generation {
    let credentialID = DeviceCredentialID(UUID())
    let signingHandle = SigningPrivateKeyHandle(UUID())
    let agreementHandle = KeyAgreementPrivateKeyHandle(UUID())
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    let generation = Generation(
      deviceID: deviceID,
      credentialID: credentialID,
      signingHandle: signingHandle,
      agreementHandle: agreementHandle,
      signingPublicKey: try SigningPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data(signingHandle.rawValue.uuidString.utf8),
        publicKeyBytes: signing.publicKey.x963Representation
      ),
      agreementPublicKey: try KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data(agreementHandle.rawValue.uuidString.utf8),
        publicKeyBytes: agreement.publicKey.x963Representation
      )
    )
    keysByCredential[credentialID] = Keys(
      generation: generation,
      signing: signing,
      agreement: agreement
    )
    return generation
  }

  func signingPublicCredential(
    for credentialID: DeviceCredentialID
  ) throws -> SigningPublicKeyDescriptor {
    guard let keys = keysByCredential[credentialID] else {
      throw SecretSyncCustodyError.missingHandle
    }
    return keys.generation.signingPublicKey
  }

  func keyAgreementPublicCredential(
    for credentialID: DeviceCredentialID
  ) throws -> KeyAgreementPublicKeyDescriptor {
    guard let keys = keysByCredential[credentialID] else {
      throw SecretSyncCustodyError.missingHandle
    }
    return keys.generation.agreementPublicKey
  }

  func signingPrivateKeyHandle(
    for credentialID: DeviceCredentialID
  ) throws -> SigningPrivateKeyHandle {
    guard let keys = keysByCredential[credentialID] else {
      throw SecretSyncCustodyError.missingHandle
    }
    return keys.generation.signingHandle
  }

  func keyAgreementPrivateKeyHandle(
    for credentialID: DeviceCredentialID
  ) throws -> KeyAgreementPrivateKeyHandle {
    guard let keys = keysByCredential[credentialID] else {
      throw SecretSyncCustodyError.missingHandle
    }
    return keys.generation.agreementHandle
  }

  func proveSigningKeyPossession(
    _ request: SigningProofOfPossessionRequest
  ) throws -> SigningProofOfPossessionResult {
    guard
      let keys = keysByCredential[request.credentialID],
      keys.generation.signingHandle == request.privateKeyHandle,
      try SecretSyncProofOfPossession.validateSigningChallenge(
        request.challengeBytes,
        credentialID: request.credentialID,
        signingPublicKey: keys.generation.signingPublicKey,
        agreementPublicKey: keys.generation.agreementPublicKey
      )
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    let proof = try SecretSyncProofOfPossession.signSoftwareFixture(
      challengeBytes: request.challengeBytes,
      privateKey: keys.signing
    )
    return try SigningProofOfPossessionResult(
      credentialID: request.credentialID,
      challengeID: request.challengeID,
      proofBytes: proof
    )
  }

  func proveKeyAgreementKeyPossession(
    _ request: KeyAgreementProofOfPossessionRequest
  ) throws -> KeyAgreementProofOfPossessionResult {
    guard
      let keys = keysByCredential[request.credentialID],
      keys.generation.agreementHandle == request.privateKeyHandle,
      try SecretSyncProofOfPossession.validateAgreementChallenge(
        request.challengeBytes,
        credentialID: request.credentialID,
        signingPublicKey: keys.generation.signingPublicKey,
        agreementPublicKey: keys.generation.agreementPublicKey
      )
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    let proof = try SecretSyncProofOfPossession.agreementResponse(
      challengeBytes: request.challengeBytes,
      privateKey: keys.agreement
    )
    return try KeyAgreementProofOfPossessionResult(
      credentialID: request.credentialID,
      challengeID: request.challengeID,
      proofBytes: proof
    )
  }
}
