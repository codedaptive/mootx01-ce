import ConvergenceKit
import CryptoKit
import Foundation

/// Complete, versioned enrollment transcript bound by both possession roles.
public struct SecretSyncProofOfPossessionTranscript: Sendable, Hashable {
  public let challengeID: UUID
  public let sessionID: UUID
  public let issuedAt: Date
  public let expiresAt: Date
  public let deviceID: TrustedDeviceID
  public let credentialID: DeviceCredentialID
  public let signingPublicKey: SigningPublicKeyDescriptor
  public let agreementPublicKey: KeyAgreementPublicKeyDescriptor
  public let authorityCredentialID: DeviceCredentialID
  public let freshnessCommitment: SecretBootstrapFreshnessCommitment

  /// Creates the exact v1 enrollment transcript.
  public init(
    challengeID: UUID,
    sessionID: UUID,
    issuedAt: Date,
    expiresAt: Date,
    deviceID: TrustedDeviceID,
    credentialID: DeviceCredentialID,
    signingPublicKey: SigningPublicKeyDescriptor,
    agreementPublicKey: KeyAgreementPublicKeyDescriptor,
    authorityCredentialID: DeviceCredentialID,
    freshnessCommitment: SecretBootstrapFreshnessCommitment
  ) throws {
    guard
      expiresAt > issuedAt,
      authorityCredentialID != credentialID,
      signingPublicKey.keyIdentifier != agreementPublicKey.keyIdentifier,
      signingPublicKey.publicKeyBytes != agreementPublicKey.publicKeyBytes,
      signingPublicKey.algorithmIdentifier
        == SecretSyncAlgorithmRegistry.publicKeyEncoding,
      agreementPublicKey.algorithmIdentifier
        == SecretSyncAlgorithmRegistry.publicKeyEncoding
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    self.challengeID = challengeID
    self.sessionID = sessionID
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.deviceID = deviceID
    self.credentialID = credentialID
    self.signingPublicKey = signingPublicKey
    self.agreementPublicKey = agreementPublicKey
    self.authorityCredentialID = authorityCredentialID
    self.freshnessCommitment = freshnessCommitment
  }

  /// Returns a validated copy with selected public bindings replaced.
  public func replacing(
    challengeID: UUID? = nil,
    expiresAt: Date? = nil,
    credentialID: DeviceCredentialID? = nil,
    freshnessCommitment: SecretBootstrapFreshnessCommitment? = nil
  ) throws -> SecretSyncProofOfPossessionTranscript {
    try SecretSyncProofOfPossessionTranscript(
      challengeID: challengeID ?? self.challengeID,
      sessionID: sessionID,
      issuedAt: issuedAt,
      expiresAt: expiresAt ?? self.expiresAt,
      deviceID: deviceID,
      credentialID: credentialID ?? self.credentialID,
      signingPublicKey: signingPublicKey,
      agreementPublicKey: agreementPublicKey,
      authorityCredentialID: authorityCredentialID,
      freshnessCommitment:
        freshnessCommitment ?? self.freshnessCommitment
    )
  }

  var canonicalBytes: Data {
    get throws {
      try SecretSyncProofOfPossession.transcriptBytes(self)
    }
  }
}

/// Role-separated signing challenge for one exact enrollment transcript.
public struct SecretSyncSigningProofChallenge: Sendable, Hashable {
  public let transcript: SecretSyncProofOfPossessionTranscript
  public let canonicalBytes: Data

  public init(
    transcript: SecretSyncProofOfPossessionTranscript
  ) throws {
    self.transcript = transcript
    canonicalBytes = try SecretSyncProofOfPossession.challengeBytes(
      role: .signing,
      transcript: transcript,
      verifierPublicKey: nil
    )
  }
}

/// Externally verifiable agreement challenge for one exact transcript.
public struct SecretSyncAgreementProofChallenge: Sendable, Hashable {
  public let transcript: SecretSyncProofOfPossessionTranscript
  public let verifierPublicKeyBytes: Data
  public let canonicalBytes: Data

  fileprivate init(
    transcript: SecretSyncProofOfPossessionTranscript,
    verifierPublicKeyBytes: Data
  ) throws {
    guard
      verifierPublicKeyBytes.count == 65,
      verifierPublicKeyBytes.first == 0x04
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    self.transcript = transcript
    self.verifierPublicKeyBytes = verifierPublicKeyBytes
    canonicalBytes = try SecretSyncProofOfPossession.challengeBytes(
      role: .agreement,
      transcript: transcript,
      verifierPublicKey: verifierPublicKeyBytes
    )
  }

  /// Creates one challenge and its verifier-held ephemeral state.
  public static func create(
    transcript: SecretSyncProofOfPossessionTranscript
  ) throws -> (
    challenge: SecretSyncAgreementProofChallenge,
    verifier: SecretSyncAgreementProofVerifier
  ) {
    let privateKey = P256.KeyAgreement.PrivateKey()
    let challenge = try SecretSyncAgreementProofChallenge(
      transcript: transcript,
      verifierPublicKeyBytes: privateKey.publicKey.x963Representation
    )
    return (
      challenge,
      SecretSyncAgreementProofVerifier(
        privateKey: privateKey,
        challengeBytes: challenge.canonicalBytes
      )
    )
  }
}

/// Verifier-held ephemeral state for an agreement possession challenge.
public struct SecretSyncAgreementProofVerifier: Sendable {
  private let privateKey: P256.KeyAgreement.PrivateKey
  private let challengeBytes: Data

  fileprivate init(
    privateKey: P256.KeyAgreement.PrivateKey,
    challengeBytes: Data
  ) {
    self.privateKey = privateKey
    self.challengeBytes = challengeBytes
  }

  /// Verifies evidence using verifier-held state and the candidate public key.
  public func verify(
    _ proofBytes: Data,
    challenge: SecretSyncAgreementProofChallenge,
    candidatePublicKey: KeyAgreementPublicKeyDescriptor
  ) throws -> Bool {
    guard
      challenge.canonicalBytes == challengeBytes,
      candidatePublicKey.algorithmIdentifier
        == SecretSyncAlgorithmRegistry.publicKeyEncoding,
      candidatePublicKey.publicKeyBytes
        == challenge.transcript.agreementPublicKey.publicKeyBytes,
      candidatePublicKey.keyIdentifier
        == challenge.transcript.agreementPublicKey.keyIdentifier
    else {
      return false
    }
    let candidate: P256.KeyAgreement.PublicKey
    do {
      candidate = try P256.KeyAgreement.PublicKey(
        x963Representation: candidatePublicKey.publicKeyBytes
      )
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    let shared: SharedSecret
    do {
      shared = try privateKey.sharedSecretFromKeyAgreement(with: candidate)
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    return SecretSyncProofOfPossession.constantTimeEqual(
      proofBytes,
      SecretSyncProofOfPossession.response(
        sharedSecret: shared,
        challengeBytes: challengeBytes
      )
    )
  }
}

enum SecretSyncProofOfPossession {
  fileprivate enum Role: String {
    case signing = "secret-sync/signing-possession/v1"
    case agreement = "secret-sync/agreement-possession/v1"
  }

  static func transcriptBytes(
    _ transcript: SecretSyncProofOfPossessionTranscript
  ) throws -> Data {
    try SecretSyncCanonicalEncoding.encode(
      domain: .deviceEnrollmentProof,
      fields: [
        field(1, uint16(1)),
        field(2, uuid(transcript.challengeID)),
        field(3, uuid(transcript.sessionID)),
        field(4, milliseconds(transcript.issuedAt)),
        field(5, milliseconds(transcript.expiresAt)),
        field(6, uuid(transcript.deviceID.rawValue)),
        field(7, uuid(transcript.credentialID.rawValue)),
        field(8, Data(transcript.signingPublicKey.algorithmIdentifier.utf8)),
        field(9, transcript.signingPublicKey.keyIdentifier),
        field(10, transcript.signingPublicKey.publicKeyBytes),
        field(
          11,
          Data(transcript.agreementPublicKey.algorithmIdentifier.utf8)
        ),
        field(12, transcript.agreementPublicKey.keyIdentifier),
        field(13, transcript.agreementPublicKey.publicKeyBytes),
        field(14, uuid(transcript.authorityCredentialID.rawValue)),
        field(15, uint16(SecretSyncAlgorithmRegistry.suiteID)),
        field(16, Data(SecretSyncAlgorithmRegistry.suiteName.utf8)),
        field(17, uint16(SecretSyncAlgorithmRegistry.version)),
        field(18, try transcript.freshnessCommitment.canonicalBytes()),
      ]
    )
  }

  fileprivate static func challengeBytes(
    role: Role,
    transcript: SecretSyncProofOfPossessionTranscript,
    verifierPublicKey: Data?
  ) throws -> Data {
    var fields = [
      field(1, uint16(1)),
      field(2, Data(role.rawValue.utf8)),
      field(3, try transcriptBytes(transcript)),
    ]
    if let verifierPublicKey {
      fields.append(field(4, verifierPublicKey))
    }
    return try SecretSyncCanonicalEncoding.encode(
      domain: .deviceEnrollmentProof,
      fields: fields
    )
  }

  static func validateSigningChallenge(
    _ bytes: Data,
    credentialID: DeviceCredentialID,
    signingPublicKey: SigningPublicKeyDescriptor,
    agreementPublicKey: KeyAgreementPublicKeyDescriptor,
    challengeID: UUID? = nil,
    now: Date? = nil
  ) throws -> Bool {
    let parsed = try parseChallenge(bytes, role: .signing)
    return parsed.verifierPublicKey == nil
      && parsed.transcript.credentialID == credentialID
      && parsed.transcript.signingPublicKey == signingPublicKey
      && parsed.transcript.agreementPublicKey == agreementPublicKey
      && (challengeID.map { parsed.transcript.challengeID == $0 } ?? true)
      && (now.map {
        $0 >= parsed.transcript.issuedAt && $0 < parsed.transcript.expiresAt
      } ?? true)
  }

  static func validateAgreementChallenge(
    _ bytes: Data,
    credentialID: DeviceCredentialID,
    signingPublicKey: SigningPublicKeyDescriptor,
    agreementPublicKey: KeyAgreementPublicKeyDescriptor,
    challengeID: UUID? = nil,
    now: Date? = nil
  ) throws -> Bool {
    let parsed = try parseChallenge(bytes, role: .agreement)
    return parsed.verifierPublicKey?.count == 65
      && parsed.transcript.credentialID == credentialID
      && parsed.transcript.signingPublicKey == signingPublicKey
      && parsed.transcript.agreementPublicKey == agreementPublicKey
      && (challengeID.map { parsed.transcript.challengeID == $0 } ?? true)
      && (now.map {
        $0 >= parsed.transcript.issuedAt && $0 < parsed.transcript.expiresAt
      } ?? true)
  }

  static func isUnexpired(_ challengeBytes: Data, now: Date) -> Bool {
    guard
      let parsed = try? parseChallengeWithoutKnownRole(challengeBytes)
    else {
      return false
    }
    return now >= parsed.transcript.issuedAt
      && now < parsed.transcript.expiresAt
  }

  static func signSoftwareFixture(
    challengeBytes: Data,
    privateKey: P256.Signing.PrivateKey
  ) throws -> Data {
    do {
      return try canonicalRawSignature(
        try privateKey.signature(for: challengeBytes)
      )
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  static func canonicalRawSignature(
    _ signature: P256.Signing.ECDSASignature
  ) throws -> Data {
    let order = Data([
      0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
      0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ])
    let halfOrder = Data([
      0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
      0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
      0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ])
    var raw = signature.rawRepresentation
    guard raw.count == 64 else {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    let scalar = Data(raw.suffix(32))
    if compare(scalar, halfOrder) > 0 {
      raw.replaceSubrange(32..<64, with: subtract(order, scalar))
    }
    return raw
  }

  static func verifySigning(
    _ proofBytes: Data,
    challengeBytes: Data,
    publicKey: SigningPublicKeyDescriptor
  ) throws -> Bool {
    guard isLowS(proofBytes) else { return false }
    let key: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      key = try P256.Signing.PublicKey(
        x963Representation: publicKey.publicKeyBytes
      )
      signature = try P256.Signing.ECDSASignature(
        rawRepresentation: proofBytes
      )
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    return key.isValidSignature(signature, for: challengeBytes)
  }

  private static func isLowS(_ signature: Data) -> Bool {
    let halfOrder = Data([
      0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
      0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
      0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ])
    guard signature.count == 64 else { return false }
    let r = signature.prefix(32)
    let s = signature.suffix(32)
    return r.contains { $0 != 0 }
      && s.contains { $0 != 0 }
      && compare(Data(s), halfOrder) <= 0
  }

  static func agreementResponse(
    challengeBytes: Data,
    privateKey: P256.KeyAgreement.PrivateKey
  ) throws -> Data {
    let parsed = try parseChallenge(challengeBytes, role: .agreement)
    guard let verifierBytes = parsed.verifierPublicKey else {
      throw SecretSyncCustodyError.invalidProof
    }
    do {
      let verifier = try P256.KeyAgreement.PublicKey(
        x963Representation: verifierBytes
      )
      return response(
        sharedSecret: try privateKey.sharedSecretFromKeyAgreement(
          with: verifier
        ),
        challengeBytes: challengeBytes
      )
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  static func agreementResponse(
    challengeBytes: Data,
    privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
  ) throws -> Data {
    let parsed = try parseChallenge(challengeBytes, role: .agreement)
    guard let verifierBytes = parsed.verifierPublicKey else {
      throw SecretSyncCustodyError.invalidProof
    }
    do {
      let verifier = try P256.KeyAgreement.PublicKey(
        x963Representation: verifierBytes
      )
      return response(
        sharedSecret: try privateKey.sharedSecretFromKeyAgreement(
          with: verifier
        ),
        challengeBytes: challengeBytes
      )
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  fileprivate static func response(
    sharedSecret: SharedSecret,
    challengeBytes: Data
  ) -> Data {
    let key = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(),
      sharedInfo: challengeBytes,
      outputByteCount: 32
    )
    return Data(
      HMAC<SHA256>.authenticationCode(
        for: challengeBytes,
        using: key
      )
    )
  }

  fileprivate static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
      difference |= left ^ right
    }
    return difference == 0
  }

  private static func parseChallengeWithoutKnownRole(
    _ bytes: Data
  ) throws -> (
    transcript: SecretSyncProofOfPossessionTranscript,
    verifierPublicKey: Data?
  ) {
    let document = try SecretSyncCanonicalEncoding.decode(
      bytes,
      expectedDomain: .deviceEnrollmentProof
    )
    guard let roleData = value(2, in: document.fields),
      let roleText = String(data: roleData, encoding: .utf8),
      let role = Role(rawValue: roleText)
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    return try parseChallenge(bytes, role: role)
  }

  private static func parseChallenge(
    _ bytes: Data,
    role: Role
  ) throws -> (
    transcript: SecretSyncProofOfPossessionTranscript,
    verifierPublicKey: Data?
  ) {
    let document: SecretSyncCanonicalDocument
    do {
      document = try SecretSyncCanonicalEncoding.decode(
        bytes,
        expectedDomain: .deviceEnrollmentProof
      )
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    let expectedTags: [UInt16] =
      role == .signing ? [1, 2, 3] : [1, 2, 3, 4]
    guard
      document.fields.map(\.tag) == expectedTags,
      value(1, in: document.fields) == uint16(1),
      value(2, in: document.fields) == Data(role.rawValue.utf8),
      let transcriptBytes = value(3, in: document.fields)
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    let verifier = value(4, in: document.fields)
    if role == .agreement {
      guard verifier?.count == 65, verifier?.first == 0x04 else {
        throw SecretSyncCustodyError.invalidProof
      }
    } else if verifier != nil {
      throw SecretSyncCustodyError.invalidProof
    }
    return (try parseTranscript(transcriptBytes), verifier)
  }

  private static func parseTranscript(
    _ bytes: Data
  ) throws -> SecretSyncProofOfPossessionTranscript {
    let document: SecretSyncCanonicalDocument
    do {
      document = try SecretSyncCanonicalEncoding.decode(
        bytes,
        expectedDomain: .deviceEnrollmentProof
      )
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    guard document.fields.map(\.tag) == Array(1...18),
      value(1, in: document.fields) == uint16(1),
      value(15, in: document.fields)
        == uint16(SecretSyncAlgorithmRegistry.suiteID),
      value(16, in: document.fields)
        == Data(SecretSyncAlgorithmRegistry.suiteName.utf8),
      value(17, in: document.fields)
        == uint16(SecretSyncAlgorithmRegistry.version),
      let challengeID = uuidValue(2, in: document.fields),
      let sessionID = uuidValue(3, in: document.fields),
      let issuedAt = dateValue(4, in: document.fields),
      let expiresAt = dateValue(5, in: document.fields),
      let device = uuidValue(6, in: document.fields),
      let credential = uuidValue(7, in: document.fields),
      let signingAlgorithm = stringValue(8, in: document.fields),
      let signingIdentifier = value(9, in: document.fields),
      let signingBytes = value(10, in: document.fields),
      let agreementAlgorithm = stringValue(11, in: document.fields),
      let agreementIdentifier = value(12, in: document.fields),
      let agreementBytes = value(13, in: document.fields),
      let authority = uuidValue(14, in: document.fields),
      let freshnessBytes = value(18, in: document.fields)
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    return try SecretSyncProofOfPossessionTranscript(
      challengeID: challengeID,
      sessionID: sessionID,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      deviceID: TrustedDeviceID(device),
      credentialID: DeviceCredentialID(credential),
      signingPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: signingAlgorithm,
        keyIdentifier: signingIdentifier,
        publicKeyBytes: signingBytes
      ),
      agreementPublicKey: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: agreementAlgorithm,
        keyIdentifier: agreementIdentifier,
        publicKeyBytes: agreementBytes
      ),
      authorityCredentialID: DeviceCredentialID(authority),
      freshnessCommitment: try parseFreshness(freshnessBytes)
    )
  }

  private static func parseFreshness(
    _ bytes: Data
  ) throws -> SecretBootstrapFreshnessCommitment {
    let document: SecretSyncCanonicalDocument
    do {
      document = try SecretSyncCanonicalEncoding.decode(
        bytes,
        expectedDomain: .bootstrapFreshnessCommitment
      )
    } catch {
      throw SecretSyncCustodyError.invalidProof
    }
    guard document.fields.map(\.tag) == [1, 2, 3, 4],
      let scope = uuidValue(1, in: document.fields),
      let epoch = uint64Value(2, in: document.fields),
      let head = value(3, in: document.fields),
      let policy = value(4, in: document.fields)
    else {
      throw SecretSyncCustodyError.invalidProof
    }
    return try SecretBootstrapFreshnessCommitment(
      scopeID: SecretScopeID(scope),
      latestPolicyEpoch: epoch,
      headCommitDigest: SecretRecordDigest(bytes: head),
      policyDigest: SecretRecordDigest(bytes: policy)
    )
  }

  private static func field(
    _ tag: UInt16,
    _ value: Data
  ) -> SecretSyncCanonicalField {
    SecretSyncCanonicalField(tag: tag, value: value)
  }

  private static func value(
    _ tag: UInt16,
    in fields: [SecretSyncCanonicalField]
  ) -> Data? {
    fields.first { $0.tag == tag }?.value
  }

  private static func stringValue(
    _ tag: UInt16,
    in fields: [SecretSyncCanonicalField]
  ) -> String? {
    guard let data = value(tag, in: fields) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func uuidValue(
    _ tag: UInt16,
    in fields: [SecretSyncCanonicalField]
  ) -> UUID? {
    guard let text = stringValue(tag, in: fields) else { return nil }
    return UUID(uuidString: text)
  }

  private static func dateValue(
    _ tag: UInt16,
    in fields: [SecretSyncCanonicalField]
  ) -> Date? {
    guard let value = uint64Value(tag, in: fields) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
  }

  private static func uint64Value(
    _ tag: UInt16,
    in fields: [SecretSyncCanonicalField]
  ) -> UInt64? {
    guard let bytes = value(tag, in: fields), bytes.count == 8 else {
      return nil
    }
    return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }

  private static func uuid(_ value: UUID) -> Data {
    Data(value.uuidString.lowercased().utf8)
  }

  private static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func milliseconds(_ value: Date) -> Data {
    let interval = value.timeIntervalSince1970
    let bounded = max(0, interval)
    var milliseconds = UInt64((bounded * 1_000).rounded()).bigEndian
    return withUnsafeBytes(of: &milliseconds) { Data($0) }
  }

  private static func compare(_ lhs: Data, _ rhs: Data) -> Int {
    for (left, right) in zip(lhs, rhs) {
      if left < right { return -1 }
      if left > right { return 1 }
    }
    return 0
  }

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
