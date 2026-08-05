import CryptoKit
import Foundation

/// Fixed, payload-free recovery failures.
public enum SecretSyncRecoveryError: Error, Sendable, Equatable {
  case invalidMnemonic
  case invalidMasterSeed
  case derivationExhausted
  case roleCollision
  case invalidPublicKey
  case invalidConfirmation
  case missingCeremony
  case alreadyConsumed
  case cancelled
  case freshnessMismatch
  case outputFailure
}

/// ENT256/CS8 BIP-39 representation of one 256-bit master recovery seed.
///
/// This type intentionally is not Codable. It implements the mnemonic
/// checksum only; it never applies PBKDF2, a passphrase, or wallet semantics.
struct SecretSyncRecoveryMnemonic: Sendable {
  static let wordCount = 24
  static let masterSeedByteCount = 32

  let masterSeed: Data
  let words: [String]

  var canonicalPhrase: String {
    words.joined(separator: " ")
  }

  init(masterSeed: Data) throws {
    guard masterSeed.count == Self.masterSeedByteCount else {
      throw SecretSyncRecoveryError.invalidMasterSeed
    }
    let checksum = Data(SHA256.hash(data: masterSeed))[0]
    let bits = Self.bits(Array(masterSeed) + [checksum])
    var words = [String]()
    words.reserveCapacity(Self.wordCount)
    for wordOffset in 0..<Self.wordCount {
      let bitOffset = wordOffset * 11
      var index = 0
      for bit in bits[bitOffset..<(bitOffset + 11)] {
        index = (index << 1) | Int(bit)
      }
      words.append(SecretSyncRecoveryWordListV1.words[index])
    }
    self.masterSeed = masterSeed
    self.words = words
  }

  init(phrase: String) throws {
    let normalized = phrase.decomposedStringWithCompatibilityMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
    let words = normalized.components(
      separatedBy: CharacterSet.whitespacesAndNewlines
    ).filter { !$0.isEmpty }
    guard words.count == Self.wordCount else {
      throw SecretSyncRecoveryError.invalidMnemonic
    }
    let indexByWord = Dictionary(
      uniqueKeysWithValues: SecretSyncRecoveryWordListV1.words.enumerated()
        .map { ($0.element, $0.offset) }
    )
    var bits = [UInt8]()
    bits.reserveCapacity(264)
    for word in words {
      guard let index = indexByWord[word] else {
        throw SecretSyncRecoveryError.invalidMnemonic
      }
      for shift in stride(from: 10, through: 0, by: -1) {
        bits.append(UInt8((index >> shift) & 1))
      }
    }
    var seedBytes = [UInt8](repeating: 0, count: Self.masterSeedByteCount)
    for index in seedBytes.indices {
      var byte: UInt8 = 0
      for bit in bits[(index * 8)..<(index * 8 + 8)] {
        byte = (byte << 1) | bit
      }
      seedBytes[index] = byte
    }
    var checksum: UInt8 = 0
    for bit in bits[256..<264] {
      checksum = (checksum << 1) | bit
    }
    let seed = Data(seedBytes)
    guard Data(SHA256.hash(data: seed))[0] == checksum else {
      throw SecretSyncRecoveryError.invalidMnemonic
    }
    self.masterSeed = seed
    self.words = words
  }

  private static func bits(_ bytes: [UInt8]) -> [UInt8] {
    bytes.flatMap { byte in
      stride(from: 7, through: 0, by: -1).map {
        UInt8((byte >> $0) & 1)
      }
    }
  }
}
