import ConvergenceKit
import Foundation

/// One proposed local-head advance with an explicit predecessor binding.
public struct SecretSyncProtectedHeadAdvance: Sendable, Hashable {
  public let expectedHead: SecretBootstrapFreshnessCommitment
  public let predecessorHeadDigest: SecretRecordDigest
  public let candidate: SecretBootstrapFreshnessCommitment

  public init(
    expectedHead: SecretBootstrapFreshnessCommitment,
    predecessorHeadDigest: SecretRecordDigest,
    candidate: SecretBootstrapFreshnessCommitment
  ) {
    self.expectedHead = expectedHead
    self.predecessorHeadDigest = predecessorHeadDigest
    self.candidate = candidate
  }
}

/// Device-local rollback floor for validated SecretSync head commitments.
///
/// This store deliberately does not conform to
/// `ExternalBootstrapFreshnessAnchor`: local state cannot establish external
/// freshness or substitute for an enrolled peer/recovery checkpoint.
public actor SecretSyncProtectedHeadStore {
  private static let service =
    "com.codedaptive.mootx01.secret-sync.protected-head"
  private static let maximumRecordByteCount = 4_096
  private let keychain: any SecretSyncKeychainOperating

  /// Creates the production Data Protection Keychain-backed local floor.
  public init() {
    keychain = SecretSyncSystemKeychain()
  }

  init(keychain: any SecretSyncKeychainOperating) {
    self.keychain = keychain
  }

  /// Initializes a previously absent floor after external validation.
  ///
  /// Reads never call this method implicitly. Duplicate initialization fails
  /// closed so a caller cannot overwrite a protected floor accidentally.
  public func initialize(
    _ commitment: SecretBootstrapFreshnessCommitment
  ) async throws {
    let bytes = try encode(commitment)
    switch await keychain.add(request(for: commitment.scopeID, data: bytes)) {
    case .success:
      return
    case .duplicate:
      throw SecretSyncCustodyError.rollbackDetected
    case .notFound, .failure:
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  /// Reads the protected floor without initializing or repairing it.
  public func protectedHead(
    for scopeID: SecretScopeID
  ) async throws -> SecretBootstrapFreshnessCommitment {
    let bytes: Data
    switch await keychain.read(request(for: scopeID, data: nil)) {
    case .success(let result):
      guard let result else {
        throw SecretSyncCustodyError.corruptProtectedHead
      }
      bytes = result
    case .notFound:
      throw SecretSyncCustodyError.missingProtectedHead
    case .duplicate, .failure:
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    guard !bytes.isEmpty, bytes.count <= Self.maximumRecordByteCount else {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    let commitment: SecretBootstrapFreshnessCommitment
    do {
      commitment = try PropertyListDecoder().decode(
        SecretBootstrapFreshnessCommitment.self,
        from: bytes
      )
    } catch {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    guard commitment.scopeID == scopeID else {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    return commitment
  }

  /// Advances the floor only from its exact current value and predecessor.
  public func advance(
    _ request: SecretSyncProtectedHeadAdvance
  ) async throws {
    let current = try await protectedHead(for: request.expectedHead.scopeID)
    guard
      current == request.expectedHead,
      request.candidate.scopeID == current.scopeID,
      request.predecessorHeadDigest == current.headCommitDigest
    else {
      throw SecretSyncCustodyError.rollbackDetected
    }
    if request.candidate.latestPolicyEpoch == current.latestPolicyEpoch {
      guard request.candidate == current else {
        throw SecretSyncCustodyError.rollbackDetected
      }
      return
    }
    guard request.candidate.latestPolicyEpoch > current.latestPolicyEpoch else {
      throw SecretSyncCustodyError.rollbackDetected
    }
    let bytes = try encode(request.candidate)
    switch await keychain.update(
      self.request(for: current.scopeID, data: bytes)
    ) {
    case .success:
      return
    case .notFound, .duplicate, .failure:
      throw SecretSyncCustodyError.rollbackDetected
    }
  }

  private func encode(
    _ commitment: SecretBootstrapFreshnessCommitment
  ) throws -> Data {
    do {
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      let bytes = try encoder.encode(commitment)
      guard bytes.count <= Self.maximumRecordByteCount else {
        throw SecretSyncCustodyError.corruptProtectedHead
      }
      return bytes
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  private func request(
    for scopeID: SecretScopeID,
    data: Data?
  ) -> SecretSyncKeychainRequest {
    SecretSyncKeychainRequest(
      service: Self.service,
      account: scopeID.rawValue.uuidString.lowercased(),
      data: data,
      accessibility: .whenUnlockedThisDeviceOnly,
      synchronizable: false,
      usesDataProtectionKeychain: true
    )
  }
}
