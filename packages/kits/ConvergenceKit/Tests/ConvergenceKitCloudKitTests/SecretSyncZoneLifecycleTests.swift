import CloudKit
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit zones")
struct SecretSyncZoneLifecycleTests {
    @Test("the lifecycle contains exactly the two fixed private zones")
    func exactZoneSet() {
        #expect(SecretSyncCloudKitZones.controlZoneName == "moot-secret-control-v1")
        #expect(SecretSyncCloudKitZones.payloadZoneName == "moot-secret-payload-v1")
        #expect(SecretSyncCloudKitZones.allZoneIDs == [
            SecretSyncCloudKitZones.controlZoneID,
            SecretSyncCloudKitZones.payloadZoneID,
        ])
        #expect(SecretSyncCloudKitZones.recordZones.map(\.zoneID) == SecretSyncCloudKitZones.allZoneIDs)
        #expect(SecretSyncCloudKitZones.allZoneIDs.allSatisfy {
            $0.ownerName == CKCurrentUserDefaultName
        })
    }

    @Test("record types route through one closed type-zone matrix")
    func closedTypeZoneMatrix() {
        for type in SecretSyncCloudKitRecordType.allCases {
            let expected = type == .sealedPayload
                ? SecretSyncCloudKitZones.payloadZoneID
                : SecretSyncCloudKitZones.controlZoneID
            #expect(SecretSyncCloudKitZones.zoneID(for: type) == expected)
        }
    }

    @Test("zone and record presence never grant authorization")
    func presenceNeverAuthorizes() {
        for role in SecretSyncCloudKitZoneRole.allCases {
            #expect(role.presenceGrantsAuthorization == false)
        }
    }

    @Test("subscriptions are pure, deterministic, silent, and exact")
    func exactSubscriptions() {
        let first = SecretSyncCloudKitZones.subscriptions()
        let second = SecretSyncCloudKitZones.subscriptions()

        #expect(first.map(\.subscriptionID) == second.map(\.subscriptionID))
        #expect(first.map(\.zoneID) == SecretSyncCloudKitZones.allZoneIDs)
        #expect(first.map(\.subscriptionID) == [
            "ck-zone-wake-moot-secret-control-v1",
            "ck-zone-wake-moot-secret-payload-v1",
        ])
        #expect(first.allSatisfy { $0.notificationInfo?.shouldSendContentAvailable == true })
        #expect(first.allSatisfy { $0.notificationInfo?.shouldBadge == false })
    }
}
