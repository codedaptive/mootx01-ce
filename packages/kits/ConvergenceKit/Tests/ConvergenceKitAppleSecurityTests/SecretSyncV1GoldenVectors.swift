import ConvergenceKit
import CryptoKit
import Foundation

@testable import ConvergenceKitAppleSecurity

/// Literal SecretSync v1 vectors used by the AppleSecurity tests.
///
/// HPKE and AES fixtures were generated once with Apple swift-crypto 4.5.0,
/// source revision `1b6b2e274e85105bfa155183145a1dcfd63331f1`.
/// Expected output is never generated at test runtime.
enum SecretSyncV1GoldenVectors {
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

  static let snapshotDigest = try! SecretRecordDigest(
    bytes: Data(0x00...0x1f)
  )
  static let policyDigest = try! SecretRecordDigest(
    bytes: Data(0x20...0x3f)
  )

  static let recipientBinding = data(
    "53534350000100227365637265742d73796e632f726563697069656e742d6b65792d656e76656c6f7065000b00010000002430303131323233332d343435352d363637372d383839392d616162626363646465656666000200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000300000008000000000000002a000400000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00050000002431313131313131312d323232322d333333332d343434342d353535353535353535353535000600000002000100070000002461616161616161612d626262622d636363632d646464642d656565656565656565656565000900000010726f7574696e65526563697069656e74000a000000020001000b0000002e6d6f6f747830312e7365637265742d73796e632e68706b652d703235362d61657367636d2d7368613235362e7631000c000000020001"
  )
  static let recoveryBinding = data(
    "535343500001001d7365637265742d73796e632f7265636f766572792d656e76656c6f7065000b00010000002430303131323233332d343435352d363637372d383839392d616162626363646465656666000200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000300000008000000000000002a000400000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00050000002431313131313131312d323232322d333333332d343434342d353535353535353535353535000600000002000100070000002439393939393939392d383838382d373737372d363636362d353535353535353535353535000800000016627265616b476c6173735265636f766572794f6e6c79000a000000020001000b0000002e6d6f6f747830312e7365637265742d73796e632e68706b652d703235362d61657367636d2d7368613235362e7631000c000000020001"
  )
  static let payloadBinding = data(
    "535343500001001a7365637265742d73796e632f7365616c65642d7061796c6f6164000a00010000002430303131323233332d343435352d363637372d383839392d616162626363646465656666000200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000300000008000000000000002a000400000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00050000002431313131313131312d323232322d333333332d343434342d353535353535353535353535000600000002000100080000000d7365616c65645061796c6f61640009000000020001000a0000002e6d6f6f747830312e7365637265742d73796e632e68706b652d703235362d61657367636d2d7368613235362e7631000b000000020001"
  )

  static let generationKeyBytes = data(
    "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
  )
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

  static let aesKeyBytes = data(
    "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"
  )
  static let aesPlaintext = data(
    "7365637265742d73796e63206669786564207061796c6f6164"
  )
  static let aesCombined = data(
    "a0a1a2a3a4a5a6a7a8a9aaab736a134239d4be4307016596e268f2e3c90a76d056e4ed4ca40a4badd3a38a749075b90b0b575241fd"
  )

  static func suite() throws -> SecretSyncAlgorithmSuite {
    try SecretSyncAlgorithmRegistry.resolve(
      exactIdentifiers(),
      availability: .available
    )
  }

  static func exactIdentifiers() -> SecretSyncAlgorithmSuiteIdentifiers {
    SecretSyncAlgorithmSuiteIdentifiers(
      suiteID: SecretSyncAlgorithmRegistry.suiteID,
      suiteNameUTF8: Array(SecretSyncAlgorithmRegistry.suiteName.utf8),
      version: SecretSyncAlgorithmRegistry.version,
      digestUTF8: Array(SecretSyncAlgorithmRegistry.digestAlgorithm.utf8),
      signatureUTF8: Array(SecretSyncAlgorithmRegistry.signatureAlgorithm.utf8),
      publicKeyEncodingUTF8: Array(SecretSyncAlgorithmRegistry.publicKeyEncoding.utf8),
      keyEnvelopeUTF8: Array(SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm.utf8),
      payloadUTF8: Array(SecretSyncAlgorithmRegistry.payloadAlgorithm.utf8)
    )
  }

  static func boundContext(
    scopeID: SecretScopeID = scopeID,
    snapshotDigest: SecretRecordDigest = snapshotDigest,
    policyEpoch: UInt64 = 42,
    policyDigest: SecretRecordDigest = policyDigest,
    generationID: SecretGenerationID = generationID,
    formatVersion: UInt16 = 1
  ) throws -> SecretSyncV1BoundContext {
    try SecretSyncV1BoundContext(
      scopeID: scopeID,
      scopeSnapshotDigest: snapshotDigest,
      policyEpoch: policyEpoch,
      policyDigest: policyDigest,
      generationID: generationID,
      formatVersion: formatVersion
    )
  }

  static func recipientContext() throws -> SecretSyncRecipientEnvelopeContext {
    SecretSyncRecipientEnvelopeContext(
      boundContext: try boundContext(),
      recipientCredentialID: recipientCredentialID
    )
  }

  static func recoveryContext() throws -> SecretSyncRecoveryEnvelopeContext {
    SecretSyncRecoveryEnvelopeContext(
      boundContext: try boundContext(),
      recoveryRecipientID: recoveryRecipientID
    )
  }

  static func recipientDescriptor(
    bytes: Data = recipientPublicKeyBytes,
    algorithm: String = SecretSyncAlgorithmRegistry.publicKeyEncoding
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: algorithm,
      keyIdentifier: Data("recipient-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func recoveryDescriptor(
    bytes: Data = recoveryPublicKeyBytes,
    algorithm: String = SecretSyncAlgorithmRegistry.publicKeyEncoding
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: algorithm,
      keyIdentifier: Data("recovery-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func signingDescriptor(
    bytes: Data = signingPublicKey,
    algorithm: String = SecretSyncAlgorithmRegistry.publicKeyEncoding
  ) throws -> SigningPublicKeyDescriptor {
    try SigningPublicKeyDescriptor(
      algorithmIdentifier: algorithm,
      keyIdentifier: Data("signing-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func data(_ hex: String) -> Data {
    precondition(hex.count.isMultiple(of: 2))
    var output = Data()
    output.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      output.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return output
  }
}
