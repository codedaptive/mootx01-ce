import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync recovery mnemonic")
struct SecretSyncRecoveryMnemonicTests {
  @Test("pinned BIP-39 corpus has exact identity and integrity")
  func pinnedCorpusIntegrity() throws {
    #expect(SecretSyncRecoveryWordListV1.words.count == 2_048)
    #expect(Set(SecretSyncRecoveryWordListV1.words).count == 2_048)
    #expect(SecretSyncRecoveryWordListV1.words.first == "abandon")
    #expect(SecretSyncRecoveryWordListV1.words.last == "zoo")
    #expect(SecretSyncRecoveryWordListV1.words[512] == "divorce")
    #expect(SecretSyncRecoveryWordListV1.words[1_023] == "lend")
    #expect(SecretSyncRecoveryWordListV1.words[1_535] == "say")
    #expect(SecretSyncRecoveryWordListV1.canonicalBytes.count == 13_115)
    #expect(SecretSyncRecoveryWordListV1.rawUpstreamBytes.count == 13_116)
    #expect(
      Data(SHA256.hash(data: SecretSyncRecoveryWordListV1.canonicalBytes))
        == hex("187db04a869dd9bc7be80d21a86497d692c0db6abd3aa8cb6be5d618ff757fae")
    )
    #expect(
      Data(SHA256.hash(data: SecretSyncRecoveryWordListV1.rawUpstreamBytes))
        == hex("2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    )
  }

  @Test("official repeated-byte ENT256 vectors retain order and checksum")
  func repeatedByteVectors() throws {
    let legal = "legal winner thank year wave sausage worth useful "
      + "legal winner thank year wave sausage worth useful "
      + "legal winner thank year wave sausage worth title"
    let letter = "letter advice cage absurd amount doctor acoustic avoid "
      + "letter advice cage absurd amount doctor acoustic avoid "
      + "letter advice cage absurd amount doctor acoustic bless"
    #expect(
      try SecretSyncRecoveryMnemonic(masterSeed: Data(repeating: 0x7f, count: 32))
        .canonicalPhrase == legal
    )
    #expect(
      try SecretSyncRecoveryMnemonic(masterSeed: Data(repeating: 0x80, count: 32))
        .canonicalPhrase == letter
    )
  }

  @Test("ENT256 zero vector round-trips exactly")
  func zeroVector() throws {
    let seed = Data(repeating: 0, count: 32)
    let mnemonic = try SecretSyncRecoveryMnemonic(masterSeed: seed)
    let expected = Array(repeating: "abandon", count: 23) + ["art"]
    #expect(mnemonic.words == expected)
    #expect(mnemonic.canonicalPhrase == expected.joined(separator: " "))
    #expect(try SecretSyncRecoveryMnemonic(phrase: mnemonic.canonicalPhrase).masterSeed == seed)
  }

  @Test("ENT256 maximum vector round-trips exactly")
  func maximumVector() throws {
    let seed = Data(repeating: 0xff, count: 32)
    let mnemonic = try SecretSyncRecoveryMnemonic(masterSeed: seed)
    let expected = Array(repeating: "zoo", count: 23) + ["vote"]
    #expect(mnemonic.words == expected)
    #expect(try SecretSyncRecoveryMnemonic(phrase: mnemonic.canonicalPhrase).masterSeed == seed)
  }

  @Test("normalization accepts complete words but rejects incomplete and bad checksum input")
  func strictParsing() throws {
    let seed = Data(repeating: 0, count: 32)
    let canonical = try SecretSyncRecoveryMnemonic(masterSeed: seed).canonicalPhrase
    let widened = "  " + canonical.uppercased().replacingOccurrences(of: " ", with: "\n\t") + "  "
    #expect(try SecretSyncRecoveryMnemonic(phrase: widened).masterSeed == seed)
    #expect(throws: SecretSyncRecoveryError.invalidMnemonic) {
      _ = try SecretSyncRecoveryMnemonic(phrase: canonical.split(separator: " ").dropLast().joined(separator: " "))
    }
    let bad = canonical.replacingOccurrences(of: " art", with: " abandon")
    #expect(throws: SecretSyncRecoveryError.invalidMnemonic) {
      _ = try SecretSyncRecoveryMnemonic(phrase: bad)
    }
  }

  private func hex(_ value: String) -> Data {
    Data(stride(from: 0, to: value.count, by: 2).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(start, offsetBy: 2)
      return UInt8(value[start..<end], radix: 16)!
    })
  }
}
