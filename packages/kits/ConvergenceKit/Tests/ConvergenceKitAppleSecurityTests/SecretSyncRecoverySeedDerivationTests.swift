import ConvergenceKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync recovery seed derivation")
struct SecretSyncRecoverySeedDerivationTests {
  private let recipientID = UUID(
    uuidString: "01234567-89ab-cdef-0123-456789abcdef"
  )!

  @Test("fixed seed deterministically creates two role-separated descriptors")
  func fixedDerivation() throws {
    let seed = Data(0..<32)
    let first = try SecretSyncRecoverySeedDerivation().derive(
      masterSeed: seed,
      recoveryRecipientID: recipientID
    )
    let second = try SecretSyncRecoverySeedDerivation().derive(
      masterSeed: seed,
      recoveryRecipientID: recipientID
    )

    #expect(first.descriptor == second.descriptor)
    #expect(first.agreementCounter == 0)
    #expect(first.authorizationSigningCounter == 0)
    #expect(
      first.descriptor.keyAgreementPublicKey.keyIdentifier
        != first.descriptor.authorizationSigningPublicKey.keyIdentifier
    )
    #expect(
      first.descriptor.keyAgreementPublicKey.publicKeyBytes
        != first.descriptor.authorizationSigningPublicKey.publicKeyBytes
    )
    #expect(first.descriptor.recoveryRecipientID == recipientID)
    #expect(
      first.agreementPrivateKey.rawRepresentation
        == hex("4275fbd9ed980ea6ff7ef13285866745014ad77b2f24cf94d4d1875d3b63887a")
    )
    #expect(
      first.descriptor.keyAgreementPublicKey.publicKeyBytes
        == hex("049db60ca8ce7800ddbcd2e57fb50a79245df7f00d73aa09c3c35b6a8c4328f01bd0959233008ba8478ccb6b9c804951efc1c23dec139f2e79ed1b0121a0ffd87b")
    )
    #expect(
      first.descriptor.keyAgreementPublicKey.keyIdentifier
        == hex("7acf5504106d221ddc08f15f48e19e3bf942baa2c084473940061ad3039609a1")
    )
    #expect(
      first.authorizationSigningPrivateKey.rawRepresentation
        == hex("84490119c678ec2f6f9ca1956cfab87c7f582ce2c009664bc271ac549846359c")
    )
    #expect(
      first.descriptor.authorizationSigningPublicKey.publicKeyBytes
        == hex("04f26486ad93967ef9b1cb8ead836d40827ebfd2e959da27d4290dbaf42a843c7a7a4efea9ab0b277cbe2c4b3fc2ed58ed24dda78df7c1be9520de45fcdcfe07cd")
    )
    #expect(
      first.descriptor.authorizationSigningPublicKey.keyIdentifier
        == hex("0e498ab9997d1a0ccc2871344e04f61d11eef9b105f5c39fd878a15887d3349c")
    )
  }

  @Test("key identifiers use the frozen role-separated length frame")
  func keyIdentifierFrame() throws {
    let material = try SecretSyncRecoverySeedDerivation().derive(
      masterSeed: Data(0..<32),
      recoveryRecipientID: recipientID
    )
    #expect(material.descriptor.keyAgreementPublicKey.keyIdentifier.count == 32)
    #expect(material.descriptor.authorizationSigningPublicKey.keyIdentifier.count == 32)
    #expect(
      SecretSyncRecoverySeedDerivation.keyIdentifier(
        role: .agreement,
        publicKey: material.descriptor.keyAgreementPublicKey.publicKeyBytes
      ) == material.descriptor.keyAgreementPublicKey.keyIdentifier
    )
    #expect(
      SecretSyncRecoverySeedDerivation.keyIdentifier(
        role: .authorizationSigning,
        publicKey: material.descriptor.authorizationSigningPublicKey.publicKeyBytes
      ) == material.descriptor.authorizationSigningPublicKey.keyIdentifier
    )
  }

  @Test("rejection increments only the rejected role counter")
  func rejectionCounter() throws {
    let expander = ScriptedRecoveryExpander(
      agreement: [Data(repeating: 0, count: 32), scalar(1)],
      authorization: [scalar(2)]
    )
    let material = try SecretSyncRecoverySeedDerivation(
      expand: expander.expand
    ).derive(
      masterSeed: Data(repeating: 7, count: 32),
      recoveryRecipientID: recipientID
    )
    #expect(material.agreementCounter == 1)
    #expect(material.authorizationSigningCounter == 0)
  }

  @Test("master seed and X9.63 inputs fail closed at exact boundaries")
  func boundaries() throws {
    #expect(throws: SecretSyncRecoveryError.invalidMasterSeed) {
      _ = try SecretSyncRecoverySeedDerivation().derive(
        masterSeed: Data(repeating: 0, count: 31),
        recoveryRecipientID: recipientID
      )
    }
    #expect(
      SecretSyncRecoverySeedDerivation.keyIdentifier(
        role: .agreement,
        publicKey: Data(repeating: 0, count: 65)
      ) == nil
    )
  }

  private func scalar(_ value: UInt8) -> Data {
    Data(repeating: 0, count: 31) + Data([value])
  }

  private func hex(_ value: String) -> Data {
    Data(stride(from: 0, to: value.count, by: 2).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(start, offsetBy: 2)
      return UInt8(value[start..<end], radix: 16)!
    })
  }
}

private final class ScriptedRecoveryExpander: @unchecked Sendable {
  private let lock = NSLock()
  private var agreement: [Data]
  private var authorization: [Data]

  init(agreement: [Data], authorization: [Data]) {
    self.agreement = agreement
    self.authorization = authorization
  }

  func expand(
    _ seed: Data,
    _ role: SecretSyncRecoveryKeyRole,
    _ counter: UInt32
  ) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    switch role {
    case .agreement:
      return agreement.removeFirst()
    case .authorizationSigning:
      return authorization.removeFirst()
    }
  }
}
