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
  private static let baseService =
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
    do {
      _ = try await protectedHead(for: commitment.scopeID)
      throw SecretSyncCustodyError.rollbackDetected
    } catch SecretSyncCustodyError.missingProtectedHead {
      // Expected: initialization is the only path allowed to create epoch one.
    }
    let bytes = try encode(commitment)
    switch await keychain.add(appendRequest(for: commitment, data: bytes)) {
    case .success:
      guard try await protectedHead(for: commitment.scopeID) == commitment else {
        throw SecretSyncCustodyError.rollbackDetected
      }
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
    let records: [Data]
    switch await keychain.readAll(historyRequest(for: scopeID)) {
    case .success(let result):
      guard !result.isEmpty else {
        throw SecretSyncCustodyError.corruptProtectedHead
      }
      records = result
    case .notFound:
      throw SecretSyncCustodyError.missingProtectedHead
    case .failure:
      throw SecretSyncCustodyError.corruptProtectedHead
    }

    // Decode the complete immutable history before selecting a floor. Ignoring
    // one malformed or duplicated record could hide a same-epoch fork.
    let commitments = try records.map { try decode($0, scopeID: scopeID) }
    guard Set(commitments).count == commitments.count else {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    guard let maximumEpoch = commitments.map(\.latestPolicyEpoch).max() else {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    let highest = commitments.filter {
      $0.latestPolicyEpoch == maximumEpoch
    }
    guard highest.count == 1, let floor = highest.first else {
      throw SecretSyncCustodyError.rollbackDetected
    }
    return floor
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
    switch await keychain.add(
      appendRequest(for: request.candidate, data: bytes)
    ) {
    case .success:
      break
    case .duplicate:
      break
    case .notFound, .failure:
      throw SecretSyncCustodyError.rollbackDetected
    }
    guard try await protectedHead(for: current.scopeID) == request.candidate else {
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

  private func decode(
    _ bytes: Data,
    scopeID: SecretScopeID
  ) throws -> SecretBootstrapFreshnessCommitment {
    guard !bytes.isEmpty, bytes.count <= Self.maximumRecordByteCount else {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
    do {
      let commitment = try PropertyListDecoder().decode(
        SecretBootstrapFreshnessCommitment.self,
        from: bytes
      )
      guard commitment.scopeID == scopeID else {
        throw SecretSyncCustodyError.corruptProtectedHead
      }
      return commitment
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.corruptProtectedHead
    }
  }

  private func appendRequest(
    for commitment: SecretBootstrapFreshnessCommitment,
    data: Data?
  ) -> SecretSyncKeychainRequest {
    SecretSyncKeychainRequest(
      service: service(for: commitment.scopeID),
      account: Self.account(for: commitment),
      data: data,
      accessibility: .whenUnlockedThisDeviceOnly,
      synchronizable: false,
      usesDataProtectionKeychain: true
    )
  }

  private func historyRequest(
    for scopeID: SecretScopeID
  ) -> SecretSyncKeychainRequest {
    SecretSyncKeychainRequest(
      service: service(for: scopeID),
      account: nil,
      data: nil,
      accessibility: .whenUnlockedThisDeviceOnly,
      synchronizable: false,
      usesDataProtectionKeychain: true
    )
  }

  private func service(for scopeID: SecretScopeID) -> String {
    Self.baseService + "." + scopeID.rawValue.uuidString.lowercased()
  }

  private static func account(
    for commitment: SecretBootstrapFreshnessCommitment
  ) -> String {
    let epoch = String(
      format: "epoch-%020llu-",
      commitment.latestPolicyEpoch
    )
    let digest = commitment.headCommitDigest.bytes.map {
      String(format: "%02x", $0)
    }.joined()
    return epoch + digest
  }
}
