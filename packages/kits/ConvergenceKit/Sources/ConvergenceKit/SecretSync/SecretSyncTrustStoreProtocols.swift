import Foundation

/// Immutable exact set of currently approved stable device credentials.
public struct ApprovedDeviceTrustSnapshot: Sendable, Hashable {
    public let policyEpoch: UInt64
    public let credentials: [TrustedDeviceCredential]
    public let trustRecords: [DeviceTrustRecord]

    public init(
        policyEpoch: UInt64,
        credentials: [TrustedDeviceCredential],
        trustRecords: [DeviceTrustRecord]
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncInterfaceError.invalidPolicyEpoch
        }
        let sorted = credentials.sorted {
            $0.credentialID.rawValue.uuidString.lowercased()
                < $1.credentialID.rawValue.uuidString.lowercased()
        }
        for index in sorted.indices.dropFirst()
        where sorted[index].credentialID == sorted[index - 1].credentialID {
            throw SecretSyncInterfaceError.duplicateCredentialID
        }
        guard sorted.allSatisfy({ $0.status == .active }) else {
            throw SecretSyncInterfaceError.unapprovedCredentialStatus
        }
        let sortedTrustRecords = trustRecords.sorted {
            $0.credentialID.rawValue.uuidString.lowercased()
                < $1.credentialID.rawValue.uuidString.lowercased()
        }
        guard sortedTrustRecords.count == sorted.count else {
            throw SecretSyncInterfaceError.trustRecordMismatch
        }
        for index in sortedTrustRecords.indices.dropFirst()
        where sortedTrustRecords[index].credentialID
            == sortedTrustRecords[index - 1].credentialID
        {
            throw SecretSyncInterfaceError.trustRecordMismatch
        }
        for (credential, trustRecord) in zip(sorted, sortedTrustRecords) {
            guard
                trustRecord.credentialID == credential.credentialID,
                trustRecord.deviceID == credential.deviceID,
                trustRecord.trustState == .trusted,
                trustRecord.effectivePolicyEpoch <= policyEpoch
            else {
                throw SecretSyncInterfaceError.trustRecordMismatch
            }
        }
        self.policyEpoch = policyEpoch
        self.credentials = sorted
        self.trustRecords = sortedTrustRecords
    }

    /// Return the exact credential in this snapshot, if present.
    public func credential(
        for credentialID: DeviceCredentialID
    ) -> TrustedDeviceCredential? {
        credentials.first { $0.credentialID == credentialID }
    }

    /// Return the exact trust record paired with a credential, if present.
    public func trustRecord(
        for credentialID: DeviceCredentialID
    ) -> DeviceTrustRecord? {
        trustRecords.first { $0.credentialID == credentialID }
    }
}

/// Immutable membership of the one global trusted group.
///
/// There is deliberately no group identifier: the store protocol exposes one
/// singleton snapshot and cannot select product-specific audience groups.
public struct GlobalTrustedGroupSnapshot: Sendable, Hashable {
    public let policyEpoch: UInt64
    public let memberCredentialIDs: [DeviceCredentialID]

    public init(
        policyEpoch: UInt64,
        memberCredentialIDs: [DeviceCredentialID]
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncInterfaceError.invalidPolicyEpoch
        }
        let sorted = memberCredentialIDs.sorted {
            $0.rawValue.uuidString.lowercased()
                < $1.rawValue.uuidString.lowercased()
        }
        for index in sorted.indices.dropFirst()
        where sorted[index] == sorted[index - 1] {
            throw SecretSyncInterfaceError.duplicateCredentialID
        }
        self.policyEpoch = policyEpoch
        self.memberCredentialIDs = sorted
    }
}

/// Atomic exact view of approved credentials and the one global trusted group.
public struct SecretSyncTrustSnapshot: Sendable, Hashable {
    public let approvedDevices: ApprovedDeviceTrustSnapshot
    public let globalTrustedGroup: GlobalTrustedGroupSnapshot

    public init(
        approvedDevices: ApprovedDeviceTrustSnapshot,
        globalTrustedGroup: GlobalTrustedGroupSnapshot
    ) throws {
        guard approvedDevices.policyEpoch == globalTrustedGroup.policyEpoch else {
            throw SecretSyncInterfaceError.trustSnapshotEpochMismatch
        }
        let approvedIDs = Set(
            approvedDevices.credentials.map(\.credentialID)
        )
        guard globalTrustedGroup.memberCredentialIDs.allSatisfy(
            approvedIDs.contains
        ) else {
            throw SecretSyncInterfaceError
                .trustedGroupContainsUnapprovedCredential
        }
        self.approvedDevices = approvedDevices
        self.globalTrustedGroup = globalTrustedGroup
    }
}

/// Read seam for one atomic trust snapshot.
public protocol SecretSyncTrustStore: Sendable {
    func trustSnapshot() async throws -> SecretSyncTrustSnapshot
}
