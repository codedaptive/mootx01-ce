import ConvergenceKit
import CryptoKit
import Foundation
import Security

/// Public, non-secret result of creating one role-separated credential pair.
public struct SecretSyncCustodyCredentialGeneration: Sendable, Hashable {
  public let deviceID: TrustedDeviceID
  public let credentialID: DeviceCredentialID
  public let signingHandle: SigningPrivateKeyHandle
  public let agreementHandle: KeyAgreementPrivateKeyHandle
  public let signingPublicKey: SigningPublicKeyDescriptor
  public let agreementPublicKey: KeyAgreementPublicKeyDescriptor
}

/// Production Secure Enclave custody for SecretSync signing and agreement.
public actor SecretSyncSecureEnclaveCustody:
  SecretSyncSigningPublicCredentialRetrieving,
  SecretSyncKeyAgreementPublicCredentialRetrieving,
  SecretSyncSigningKeyCustody,
  SecretSyncKeyAgreementKeyCustody
{
  private let handleStore: SecretSyncKeychainHandleStore
  private let authorization: SecretSyncLocalAuthorization

  /// Creates production custody in the default application Keychain group.
  public init() {
    handleStore = SecretSyncKeychainHandleStore()
    authorization = SecretSyncLocalAuthorization()
  }

  init(
    handleStore: SecretSyncKeychainHandleStore,
    authorization: SecretSyncLocalAuthorization
  ) {
    self.handleStore = handleStore
    self.authorization = authorization
  }

  /// Reports whether this process can reach a Secure Enclave.
  public nonisolated static var hardwareAvailable: Bool {
    SecureEnclave.isAvailable
  }

  /// Creates two independent Secure Enclave keys for a fresh credential ID.
  public func createCredential(
    for deviceID: TrustedDeviceID
  ) async throws -> SecretSyncCustodyCredentialGeneration {
    guard SecureEnclave.isAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }
    let context = try await authorization.authorityContext()
    do {
      let accessControl = try Self.privateKeyAccessControl()
      guard let rawContext = context.localAuthenticationContext else {
        throw SecretSyncCustodyError.authorizationFailed
      }
      let signing: SecureEnclave.P256.Signing.PrivateKey
      let agreement: SecureEnclave.P256.KeyAgreement.PrivateKey
      do {
        signing = try SecureEnclave.P256.Signing.PrivateKey(
          accessControl: accessControl,
          authenticationContext: rawContext
        )
        agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          accessControl: accessControl,
          authenticationContext: rawContext
        )
      } catch {
        throw SecretSyncCustodyError.cryptographicFailure
      }

      let credentialID = DeviceCredentialID(UUID())
      let signingHandle = SigningPrivateKeyHandle(UUID())
      let agreementHandle = KeyAgreementPrivateKeyHandle(UUID())
      let signingRecord = SecretSyncStoredKeyRecord(
        credentialID: credentialID,
        handleID: signingHandle.rawValue,
        role: .signing,
        opaqueKeyRepresentation: signing.dataRepresentation,
        publicKeyBytes: signing.publicKey.x963Representation
      )
      let agreementRecord = SecretSyncStoredKeyRecord(
        credentialID: credentialID,
        handleID: agreementHandle.rawValue,
        role: .agreement,
        opaqueKeyRepresentation: agreement.dataRepresentation,
        publicKeyBytes: agreement.publicKey.x963Representation
      )
      try await handleStore.insert(signingRecord)
      do {
        try await handleStore.insert(agreementRecord)
      } catch {
        await handleStore.remove(
          credentialID: credentialID,
          role: .signing
        )
        throw error
      }
      let generation = try Self.generation(
        deviceID: deviceID,
        credentialID: credentialID,
        signingRecord: signingRecord,
        agreementRecord: agreementRecord
      )
      await authorization.invalidate(context)
      return generation
    } catch let error as SecretSyncCustodyError {
      await authorization.invalidate(context)
      throw error
    } catch {
      await authorization.invalidate(context)
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  /// Replaces custody with fresh keys and a fresh credential ID.
  ///
  /// The stable device ID is caller-owned and deliberately preserved. Existing
  /// credential material is not overwritten or silently repaired.
  public func replaceCredential(
    for deviceID: TrustedDeviceID
  ) async throws -> SecretSyncCustodyCredentialGeneration {
    try await createCredential(for: deviceID)
  }

  public func signingPublicCredential(
    for credentialID: DeviceCredentialID
  ) async throws -> SigningPublicKeyDescriptor {
    let record = try await authorizedRecord(
      credentialID: credentialID,
      role: .signing
    )
    return try Self.signingDescriptor(record)
  }

  public func keyAgreementPublicCredential(
    for credentialID: DeviceCredentialID
  ) async throws -> KeyAgreementPublicKeyDescriptor {
    let record = try await authorizedRecord(
      credentialID: credentialID,
      role: .agreement
    )
    return try Self.agreementDescriptor(record)
  }

  public func signingPrivateKeyHandle(
    for credentialID: DeviceCredentialID
  ) async throws -> SigningPrivateKeyHandle {
    let record = try await authorizedRecord(
      credentialID: credentialID,
      role: .signing
    )
    return SigningPrivateKeyHandle(record.handleID)
  }

  public func keyAgreementPrivateKeyHandle(
    for credentialID: DeviceCredentialID
  ) async throws -> KeyAgreementPrivateKeyHandle {
    let record = try await authorizedRecord(
      credentialID: credentialID,
      role: .agreement
    )
    return KeyAgreementPrivateKeyHandle(record.handleID)
  }

  public func proveSigningKeyPossession(
    _ request: SigningProofOfPossessionRequest
  ) async throws -> SigningProofOfPossessionResult {
    let context = try await authorization.authorityContext()
    do {
      let signingRecord = try await handleStore.record(
        for: request.credentialID,
        role: .signing
      )
      let agreementRecord = try await handleStore.record(
        for: request.credentialID,
        role: .agreement
      )
      guard
        signingRecord.handleID == request.privateKeyHandle.rawValue,
        try SecretSyncProofOfPossession.validateSigningChallenge(
          request.challengeBytes,
          credentialID: request.credentialID,
          signingPublicKey: Self.signingDescriptor(signingRecord),
          agreementPublicKey: Self.agreementDescriptor(agreementRecord),
          challengeID: request.challengeID,
          now: Date()
        ),
        let rawContext = context.localAuthenticationContext
      else {
        throw SecretSyncCustodyError.invalidProof
      }
      let key: SecureEnclave.P256.Signing.PrivateKey
      do {
        key = try SecureEnclave.P256.Signing.PrivateKey(
          dataRepresentation: signingRecord.opaqueKeyRepresentation,
          authenticationContext: rawContext
        )
      } catch {
        throw SecretSyncCustodyError.corruptHandle
      }
      let proof: Data
      do {
        proof = try SecretSyncProofOfPossession.canonicalRawSignature(
          key.signature(for: request.challengeBytes)
        )
      } catch let error as SecretSyncCustodyError {
        throw error
      } catch {
        throw SecretSyncCustodyError.cryptographicFailure
      }
      let result = try SigningProofOfPossessionResult(
        credentialID: request.credentialID,
        challengeID: request.challengeID,
        proofBytes: proof
      )
      await authorization.invalidate(context)
      return result
    } catch let error as SecretSyncCustodyError {
      await authorization.invalidate(context)
      throw error
    } catch {
      await authorization.invalidate(context)
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  public func proveKeyAgreementKeyPossession(
    _ request: KeyAgreementProofOfPossessionRequest
  ) async throws -> KeyAgreementProofOfPossessionResult {
    let context = try await authorization.authorityContext()
    do {
      let signingRecord = try await handleStore.record(
        for: request.credentialID,
        role: .signing
      )
      let agreementRecord = try await handleStore.record(
        for: request.credentialID,
        role: .agreement
      )
      guard
        agreementRecord.handleID == request.privateKeyHandle.rawValue,
        try SecretSyncProofOfPossession.validateAgreementChallenge(
          request.challengeBytes,
          credentialID: request.credentialID,
          signingPublicKey: Self.signingDescriptor(signingRecord),
          agreementPublicKey: Self.agreementDescriptor(agreementRecord),
          challengeID: request.challengeID,
          now: Date()
        ),
        let rawContext = context.localAuthenticationContext
      else {
        throw SecretSyncCustodyError.invalidProof
      }
      let key: SecureEnclave.P256.KeyAgreement.PrivateKey
      do {
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          dataRepresentation: agreementRecord.opaqueKeyRepresentation,
          authenticationContext: rawContext
        )
      } catch {
        throw SecretSyncCustodyError.corruptHandle
      }
      let proof = try SecretSyncProofOfPossession.agreementResponse(
        challengeBytes: request.challengeBytes,
        privateKey: key
      )
      let result = try KeyAgreementProofOfPossessionResult(
        credentialID: request.credentialID,
        challengeID: request.challengeID,
        proofBytes: proof
      )
      await authorization.invalidate(context)
      return result
    } catch let error as SecretSyncCustodyError {
      await authorization.invalidate(context)
      throw error
    } catch {
      await authorization.invalidate(context)
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  /// Starts one reusable foreground-only hydration authorization.
  public func beginForegroundHydrationSession()
    async throws -> SecretSyncForegroundAuthorizationSession
  {
    try await authorization.beginForegroundSession()
  }

  /// Opens a routine HPKE envelope inside custody for one foreground session.
  public func openRecipientGenerationKey(
    _ wrappedKeyBytes: Data,
    privateKeyHandle: KeyAgreementPrivateKeyHandle,
    credentialID: DeviceCredentialID,
    context envelopeContext: SecretSyncRecipientEnvelopeContext,
    session: SecretSyncForegroundAuthorizationSession
  ) async throws -> SecretSyncGenerationKey {
    let authorizedContext = try await session.authorizedContext()
    guard let rawContext = authorizedContext.localAuthenticationContext else {
      throw SecretSyncCustodyError.authorizationFailed
    }
    let record = try await handleStore.record(
      for: credentialID,
      role: .agreement
    )
    guard record.handleID == privateKeyHandle.rawValue else {
      throw SecretSyncCustodyError.corruptHandle
    }
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    do {
      key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: record.opaqueKeyRepresentation,
        authenticationContext: rawContext
      )
    } catch {
      throw SecretSyncCustodyError.corruptHandle
    }
    let binding: Data
    do {
      binding = try SecretSyncV1Binding.recipientBytes(
        context: envelopeContext
      )
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    guard wrappedKeyBytes.count == 113, wrappedKeyBytes.first == 0x04 else {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    let encapsulatedKey = Data(wrappedKeyBytes.prefix(65))
    let ciphertext = Data(wrappedKeyBytes.dropFirst(65))
    do {
      var recipient = try HPKE.Recipient(
        privateKey: key,
        ciphersuite: .P256_SHA256_AES_GCM_256,
        info: binding,
        encapsulatedKey: encapsulatedKey
      )
      let opened = try recipient.open(
        ciphertext,
        authenticating: binding
      )
      return try SecretSyncGenerationKey(openedBytes: opened)
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  func removeCredentialForHardwareProof(
    _ credentialID: DeviceCredentialID
  ) async {
    await handleStore.remove(
      credentialID: credentialID,
      role: .signing
    )
    await handleStore.remove(
      credentialID: credentialID,
      role: .agreement
    )
  }

  private func authorizedRecord(
    credentialID: DeviceCredentialID,
    role: SecretSyncStoredKeyRole
  ) async throws -> SecretSyncStoredKeyRecord {
    let context = try await authorization.authorityContext()
    do {
      let record = try await handleStore.record(
        for: credentialID,
        role: role
      )
      await authorization.invalidate(context)
      return record
    } catch let error as SecretSyncCustodyError {
      await authorization.invalidate(context)
      throw error
    } catch {
      await authorization.invalidate(context)
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  private static func generation(
    deviceID: TrustedDeviceID,
    credentialID: DeviceCredentialID,
    signingRecord: SecretSyncStoredKeyRecord,
    agreementRecord: SecretSyncStoredKeyRecord
  ) throws -> SecretSyncCustodyCredentialGeneration {
    SecretSyncCustodyCredentialGeneration(
      deviceID: deviceID,
      credentialID: credentialID,
      signingHandle: SigningPrivateKeyHandle(signingRecord.handleID),
      agreementHandle: KeyAgreementPrivateKeyHandle(agreementRecord.handleID),
      signingPublicKey: try signingDescriptor(signingRecord),
      agreementPublicKey: try agreementDescriptor(agreementRecord)
    )
  }

  private static func signingDescriptor(
    _ record: SecretSyncStoredKeyRecord
  ) throws -> SigningPublicKeyDescriptor {
    guard record.role == .signing else {
      throw SecretSyncCustodyError.corruptHandle
    }
    return try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data(record.handleID.uuidString.lowercased().utf8),
      publicKeyBytes: record.publicKeyBytes
    )
  }

  private static func agreementDescriptor(
    _ record: SecretSyncStoredKeyRecord
  ) throws -> KeyAgreementPublicKeyDescriptor {
    guard record.role == .agreement else {
      throw SecretSyncCustodyError.corruptHandle
    }
    return try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data(record.handleID.uuidString.lowercased().utf8),
      publicKeyBytes: record.publicKeyBytes
    )
  }

  private static func privateKeyAccessControl() throws -> SecAccessControl {
    var creationError: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.userPresence, .privateKeyUsage],
        &creationError
      )
    else {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    return accessControl
  }
}
