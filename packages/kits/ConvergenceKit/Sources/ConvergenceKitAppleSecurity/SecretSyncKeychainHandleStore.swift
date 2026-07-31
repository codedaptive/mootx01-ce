import ConvergenceKit
import Foundation
import Security

/// Fixed, payload-free failures emitted by Apple SecretSync custody.
public enum SecretSyncCustodyError: Error, Sendable, Equatable {
  case missingHandle
  case corruptHandle
  case duplicateHandle
  case authorizationFailed
  case hardwareUnavailable
  case cryptographicFailure
  case invalidProof
  case backgroundOperationDenied
  case missingProtectedHead
  case corruptProtectedHead
  case rollbackDetected
}

enum SecretSyncStoredKeyRole: String, Sendable, Codable {
  case signing
  case agreement

  var service: String {
    switch self {
    case .signing:
      "com.codedaptive.mootx01.secret-sync.signing-handle"
    case .agreement:
      "com.codedaptive.mootx01.secret-sync.agreement-handle"
    }
  }
}

struct SecretSyncStoredKeyRecord: Sendable, Codable, Equatable {
  let credentialID: DeviceCredentialID
  let handleID: UUID
  let role: SecretSyncStoredKeyRole
  let opaqueKeyRepresentation: Data
  let publicKeyBytes: Data
}

enum SecretSyncKeychainAccessibility: Sendable, Equatable {
  case whenUnlockedThisDeviceOnly
}

struct SecretSyncKeychainRequest: Sendable, Equatable {
  let service: String
  let account: String?
  let data: Data?
  let accessibility: SecretSyncKeychainAccessibility
  let synchronizable: Bool
  let usesDataProtectionKeychain: Bool

  // A nil group is intentional: omission selects the default application
  // access group without requiring a sharing entitlement.
  let accessGroup: String? = nil

  var storageKey: String { service + "\u{0}" + (account ?? "*") }
}

enum SecretSyncKeychainResult: Sendable, Equatable {
  case success(Data?)
  case notFound
  case duplicate
  case failure
}

enum SecretSyncKeychainItemsResult: Sendable, Equatable {
  case success([Data])
  case notFound
  case failure
}

protocol SecretSyncKeychainOperating: Sendable {
  func add(
    _ request: SecretSyncKeychainRequest
  ) async -> SecretSyncKeychainResult

  func read(
    _ request: SecretSyncKeychainRequest
  ) async -> SecretSyncKeychainResult

  func readAll(
    _ request: SecretSyncKeychainRequest
  ) async -> SecretSyncKeychainItemsResult

  func delete(
    _ request: SecretSyncKeychainRequest
  ) async -> SecretSyncKeychainResult
}

actor SecretSyncSystemKeychain: SecretSyncKeychainOperating {
  func add(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainResult {
    guard let data = request.data else { return .failure }
    var attributes = baseAttributes(request)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] =
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return result(for: SecItemAdd(attributes as CFDictionary, nil))
  }

  func read(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainResult {
    var query = baseAttributes(request)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var returned: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &returned)
    guard status == errSecSuccess else { return result(for: status) }
    guard let data = returned as? Data else { return .failure }
    return .success(data)
  }

  func readAll(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainItemsResult {
    var query = baseAttributes(request)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var returned: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &returned)
    switch status {
    case errSecSuccess:
      if let values = returned as? [Data], !values.isEmpty {
        return .success(values)
      }
      if let value = returned as? Data {
        return .success([value])
      }
      return .failure
    case errSecItemNotFound:
      return .notFound
    default:
      return .failure
    }
  }

  func delete(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainResult {
    result(for: SecItemDelete(baseAttributes(request) as CFDictionary))
  }

  private func baseAttributes(
    _ request: SecretSyncKeychainRequest
  ) -> [String: Any] {
    var attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: request.service,
      kSecAttrSynchronizable as String:
        request.synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
    ]
    if let account = request.account {
      attributes[kSecAttrAccount as String] = account
    }
    #if os(macOS)
      if request.usesDataProtectionKeychain {
        attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
      }
    #endif
    return attributes
  }

  private func result(for status: OSStatus) -> SecretSyncKeychainResult {
    switch status {
    case errSecSuccess:
      .success(nil)
    case errSecItemNotFound:
      .notFound
    case errSecDuplicateItem:
      .duplicate
    default:
      .failure
    }
  }
}

actor SecretSyncKeychainHandleStore {
  private static let maximumRecordByteCount = 16_384
  private let keychain: any SecretSyncKeychainOperating

  init(keychain: any SecretSyncKeychainOperating = SecretSyncSystemKeychain()) {
    self.keychain = keychain
  }

  func insert(_ record: SecretSyncStoredKeyRecord) async throws {
    guard
      !record.opaqueKeyRepresentation.isEmpty,
      record.opaqueKeyRepresentation.count <= Self.maximumRecordByteCount,
      record.publicKeyBytes.count == 65,
      record.publicKeyBytes.first == 0x04
    else {
      throw SecretSyncCustodyError.corruptHandle
    }
    let encoded: Data
    do {
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      encoded = try encoder.encode(record)
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    switch await keychain.add(request(for: record, data: encoded)) {
    case .success:
      return
    case .duplicate:
      throw SecretSyncCustodyError.duplicateHandle
    case .notFound, .failure:
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }

  func record(
    for credentialID: DeviceCredentialID,
    role: SecretSyncStoredKeyRole
  ) async throws -> SecretSyncStoredKeyRecord {
    let request = request(
      credentialID: credentialID,
      role: role,
      data: nil
    )
    let bytes: Data
    switch await keychain.read(request) {
    case .success(let result):
      guard let result else { throw SecretSyncCustodyError.corruptHandle }
      bytes = result
    case .notFound:
      throw SecretSyncCustodyError.missingHandle
    case .duplicate, .failure:
      throw SecretSyncCustodyError.corruptHandle
    }
    guard !bytes.isEmpty, bytes.count <= Self.maximumRecordByteCount else {
      throw SecretSyncCustodyError.corruptHandle
    }
    do {
      let decoded = try PropertyListDecoder().decode(
        SecretSyncStoredKeyRecord.self,
        from: bytes
      )
      guard
        decoded.credentialID == credentialID,
        decoded.role == role,
        !decoded.opaqueKeyRepresentation.isEmpty,
        decoded.publicKeyBytes.count == 65,
        decoded.publicKeyBytes.first == 0x04
      else {
        throw SecretSyncCustodyError.corruptHandle
      }
      return decoded
    } catch let error as SecretSyncCustodyError {
      throw error
    } catch {
      throw SecretSyncCustodyError.corruptHandle
    }
  }

  func remove(
    credentialID: DeviceCredentialID,
    role: SecretSyncStoredKeyRole
  ) async {
    _ = await keychain.delete(
      request(credentialID: credentialID, role: role, data: nil)
    )
  }

  private func request(
    for record: SecretSyncStoredKeyRecord,
    data: Data?
  ) -> SecretSyncKeychainRequest {
    request(
      credentialID: record.credentialID,
      role: record.role,
      data: data
    )
  }

  private func request(
    credentialID: DeviceCredentialID,
    role: SecretSyncStoredKeyRole,
    data: Data?
  ) -> SecretSyncKeychainRequest {
    SecretSyncKeychainRequest(
      service: role.service,
      account: credentialID.rawValue.uuidString.lowercased(),
      data: data,
      accessibility: .whenUnlockedThisDeviceOnly,
      synchronizable: false,
      usesDataProtectionKeychain: true
    )
  }
}
