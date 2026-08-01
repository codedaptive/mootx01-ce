import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync cross-provider golden vectors")
struct SecretSyncCrossProviderGoldenVectorTests {
  @Test("public digest provider matches SHA-256 and the frozen U2 vector")
  func digestVector() throws {
    let provider = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let digest = try provider.digest(canonicalBytes: U7GoldenVectors.digestInput)

    #expect(digest.bytes == U7GoldenVectors.digestOutput)
    #expect(digest.bytes == Data(SHA256.hash(data: U7GoldenVectors.digestInput)))
  }

  @Test("public signature provider accepts the frozen raw64 low-S vector")
  func signatureVector() throws {
    let provider = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())

    #expect(
      try provider.verify(
        signature: U7GoldenVectors.lowSRawSignature,
        canonicalBytes: U7GoldenVectors.signatureMessage,
        signingPublicKey: U7GoldenVectors.signingDescriptor()
      )
    )
  }

  @Test("routine and recovery U2 HPKE vectors open one usable generation key")
  func hpkeVectors() throws {
    let suite = try U7GoldenVectors.suite()
    let hpke = try SecretSyncHPKEEnvelopeProvider(suite: suite)
    let aes = try SecretSyncAESGCMProvider(suite: suite)
    let recipientKey = try hpke.openRecipientGenerationKey(
      U7GoldenVectors.recipientWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: U7GoldenVectors.recipientPrivateKeyBytes
      ),
      context: U7GoldenVectors.recipientContext()
    )
    let recoveryKey = try hpke.openRecoveryGenerationKey(
      U7GoldenVectors.recoveryWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: U7GoldenVectors.recoveryPrivateKeyBytes
      ),
      context: U7GoldenVectors.recoveryContext()
    )
    let plaintext = Data("u7-cross-provider-proof".utf8)
    let sealed = try aes.seal(
      plaintext: plaintext,
      using: recipientKey,
      context: U7GoldenVectors.boundContext()
    )

    #expect(
      try aes.open(
        sealedBytes: sealed,
        using: recoveryKey,
        context: U7GoldenVectors.boundContext()
      ) == plaintext
    )
  }
}

enum U7GoldenVectors {
  static let scopeID = SecretScopeID(
    UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
  )
  static let generationID = SecretGenerationID(
    UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  )
  static let recipientCredentialID = DeviceCredentialID(
    UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
  )
  static let recoveryRecipientID = UUID(
    uuidString: "99999999-8888-7777-6666-555555555555"
  )!
  static let snapshotDigest = try! SecretRecordDigest(bytes: Data(0x00...0x1f))
  static let policyDigest = try! SecretRecordDigest(bytes: Data(0x20...0x3f))

  static let recipientPrivateKeyBytes = data(
    "0000000000000000000000000000000000000000000000000000000000000001"
  )
  static let recipientPublicKeyBytes = data(
    "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
  )
  static let recipientWrappedKey = data(
    "04a000e65f42f8f318280803dc7cda6b856a6260000e30159b144aec05c20d8f86466ae8fa31eac834d87f7e10c6b6b2ce96d7c1d35efca965332b9bda063684ca2b37ec6a587df1cdd2464e3b673bc54e549b2ef7ba9b89ca43ba97b799abeed104fb4f7d522ac01daa3c9507858fa22d"
  )
  static let recoveryPrivateKeyBytes = data(
    "0000000000000000000000000000000000000000000000000000000000000002"
  )
  static let recoveryPublicKeyBytes = data(
    "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
  )
  static let recoveryWrappedKey = data(
    "04a81b2ed1365e61ca0d34f2c4749c44fed214d3c86e2673fa6f254fa0df39240778e1821cbdbcabb6db07ee8445c728a7568cb5de0035fab1336236bb4ac2f51102f8df1a20c0cc0bcae6797ddbc882365a6c2ebd6e61d31c6ac5c35b04223d50e59830a5f764682a1c051a643bdf48e8"
  )
  static let signingPublicKey = data(
    "045ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d5032"
  )
  static let signatureMessage = data(
    "7365637265742d73796e63206669786564207369676e6174757265206d657373616765"
  )
  static let lowSRawSignature = data(
    "6ec984e668c95ae614ed319fc1406b8adbd576fa4d72934cd525d2bbd6c0cc2b215dfcfb675a70a46cda7eb878b36d8c28d8757903ec9790c136a82f660ceda2"
  )
  static let digestInput = data(
    "7365637265742d73796e632073686132353620666978656420696e707574"
  )
  static let digestOutput = data(
    "8978a71cc74c1381ae4ca8f26adba67522d077fba45f997af7875533e023d558"
  )

  static func suite() throws -> SecretSyncAlgorithmSuite {
    try SecretSyncAlgorithmRegistry.resolve(
      SecretSyncAlgorithmSuiteIdentifiers(
        suiteID: SecretSyncAlgorithmRegistry.suiteID,
        suiteNameUTF8: Array(SecretSyncAlgorithmRegistry.suiteName.utf8),
        version: SecretSyncAlgorithmRegistry.version,
        digestUTF8: Array(SecretSyncAlgorithmRegistry.digestAlgorithm.utf8),
        signatureUTF8: Array(SecretSyncAlgorithmRegistry.signatureAlgorithm.utf8),
        publicKeyEncodingUTF8: Array(SecretSyncAlgorithmRegistry.publicKeyEncoding.utf8),
        keyEnvelopeUTF8: Array(SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm.utf8),
        payloadUTF8: Array(SecretSyncAlgorithmRegistry.payloadAlgorithm.utf8)
      ),
      availability: .available
    )
  }

  static func boundContext(
    scopeID: SecretScopeID = scopeID,
    snapshotDigest: SecretRecordDigest = snapshotDigest,
    policyEpoch: UInt64 = 42,
    policyDigest: SecretRecordDigest = policyDigest,
    generationID: SecretGenerationID = generationID
  ) throws -> SecretSyncV1BoundContext {
    try SecretSyncV1BoundContext(
      scopeID: scopeID,
      scopeSnapshotDigest: snapshotDigest,
      policyEpoch: policyEpoch,
      policyDigest: policyDigest,
      generationID: generationID,
      formatVersion: 1
    )
  }

  static func recipientContext(
    credentialID: DeviceCredentialID = recipientCredentialID,
    boundContext: SecretSyncV1BoundContext? = nil
  ) throws -> SecretSyncRecipientEnvelopeContext {
    SecretSyncRecipientEnvelopeContext(
      boundContext: try boundContext ?? self.boundContext(),
      recipientCredentialID: credentialID
    )
  }

  static func recoveryContext(
    recipientID: UUID = recoveryRecipientID,
    boundContext: SecretSyncV1BoundContext? = nil
  ) throws -> SecretSyncRecoveryEnvelopeContext {
    SecretSyncRecoveryEnvelopeContext(
      boundContext: try boundContext ?? self.boundContext(),
      recoveryRecipientID: recipientID
    )
  }

  static func recipientDescriptor(
    bytes: Data = recipientPublicKeyBytes
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("recipient-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func recoveryDescriptor(
    bytes: Data = recoveryPublicKeyBytes
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("recovery-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func signingDescriptor() throws -> SigningPublicKeyDescriptor {
    try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("signing-fixture".utf8),
      publicKeyBytes: signingPublicKey
    )
  }

  static func digest(_ fill: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(repeating: fill, count: 32))
  }

  static func data(_ hex: String) -> Data {
    precondition(hex.count.isMultiple(of: 2))
    var result = Data()
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      result.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return result
  }
}
