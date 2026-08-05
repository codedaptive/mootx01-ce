import CloudKit
import Foundation

/// Closed SecretSync CloudKit zone roles. Merely observing a zone or record is
/// never an authorization signal; authorization comes from validated policy.
public enum SecretSyncCloudKitZoneRole: CaseIterable, Sendable {
    case control
    case payload

    public var presenceGrantsAuthorization: Bool { false }
}

/// Exact private-zone lifecycle for SecretSync schema version 1.
public enum SecretSyncCloudKitZones {
    public static let controlZoneName = "moot-secret-control-v1"
    public static let payloadZoneName = "moot-secret-payload-v1"

    public static let controlZoneID = CKRecordZone.ID(
        zoneName: controlZoneName,
        ownerName: CKCurrentUserDefaultName
    )
    public static let payloadZoneID = CKRecordZone.ID(
        zoneName: payloadZoneName,
        ownerName: CKCurrentUserDefaultName
    )

    public static let allZoneIDs = [controlZoneID, payloadZoneID]

    /// Fresh zone objects for idempotent create-or-confirm lifecycle calls.
    public static var recordZones: [CKRecordZone] {
        allZoneIDs.map(CKRecordZone.init(zoneID:))
    }

    /// Closed record-to-zone routing matrix. Only sealed payload ciphertext is
    /// stored in the payload zone; all policy and envelope records are control.
    public static func zoneID(for type: SecretSyncCloudKitRecordType) -> CKRecordZone.ID {
        type == .sealedPayload ? payloadZoneID : controlZoneID
    }

    /// Pure, deterministic silent-push subscriptions. Polling remains the
    /// correctness path; these subscriptions only accelerate discovery.
    public static func subscriptions() -> [CKRecordZoneSubscription] {
        allZoneIDs.map(SecretSyncCloudKitSubscriptionFactory.subscription(for:))
    }
}
