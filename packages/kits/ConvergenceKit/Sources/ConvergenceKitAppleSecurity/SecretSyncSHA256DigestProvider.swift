import ConvergenceKit
import CryptoKit
import Foundation

/// CryptoKit SHA-256 implementation for the closed SecretSync v1 suite.
public struct SecretSyncSHA256DigestProvider: SecretSyncDigesting, Sendable {
  /// Creates a digest provider only for the registry-resolved v1 suite.
  public init(suite: SecretSyncAlgorithmSuite) throws {
    try SecretSyncV1SuiteValidator.requireExact(suite)
  }

  /// Digests the supplied canonical bytes without re-encoding them.
  public func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(SHA256.hash(data: canonicalBytes)))
  }
}
