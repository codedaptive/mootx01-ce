// ZoneSubscriptionTests.swift
//
// Tests for CVK-ICLOUD P3-M3: zone subscription registration and
// remote-wake accelerator (handleRemoteNotification).
//
// Test organisation:
//   Suite 1 — ZoneSubscription (register/deregister via CloudZoneFake)
//   Suite 2 — RemoteWake notification payload parser
//   Suite 3 — handleRemoteNotification integration (accept/reject and event emission)
//
// All tests inject a CloudZoneFake so no live CloudKit container is needed.
// Engine setup mirrors TwoEstateFixture.setUp() but uses a single estate for
// the subscription / notification tests.
//
// Poll-deadline pattern (no Task.sleep):
//   Convergence waits use ContinuousClock + Task.yield() loops so the test
//   suite is not flaky under CPU contention.
//
// Cleanup: async actor-isolated engine.disable() cannot live in a defer block
// (defer blocks are synchronous in Swift 6). Cleanup is called explicitly at
// the end of each test. See AdaptivePollSchedulerTests for the same pattern.

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
@testable import ConvergenceKitCloudKit

// MARK: - Suite 1: Zone subscription register / deregister

@Suite("ZoneSubscription — register and deregister")
struct ZoneSubscriptionRegisterTests {

    // MARK: - Helpers

    /// Provision a single-estate engine backed by a CloudZoneFake.
    static func makeEnabledEngine(cloud: CloudZoneFake) async throws
        -> (CloudKitSyncEngine, any Storage)
    {
        let storage = try await TwoEstateFixture.makeStorage()
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: TwoEstateFixture.manifest, storage: storage)
        return (engine, storage)
    }

    // MARK: - Tests

    @Test("register is idempotent: two calls → one subscription in the fake")
    func registerIdempotent() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        try await engine.registerZoneSubscription()
        try await engine.registerZoneSubscription()  // second call — same ID

        let count = await cloud.subscriptionCount
        #expect(count == 1,
                "two saves of the same subscription ID must produce exactly one entry")

        // Explicit cleanup: disable() is async and cannot live in defer.
        try await engine.disable()
    }

    @Test("deregister removes the subscription from the fake")
    func deregisterRemovesSubscription() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        try await engine.registerZoneSubscription()
        let countBefore = await cloud.subscriptionCount
        #expect(countBefore == 1, "subscription should be present after register")

        try await engine.deregisterZoneSubscription()
        let countAfter = await cloud.subscriptionCount
        #expect(countAfter == 0, "subscription should be absent after deregister")

        try await engine.disable()
    }

    @Test("subscription uses the zone-derived ID")
    func subscriptionUsesZoneDerivedID() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        try await engine.registerZoneSubscription()

        let expectedID = CloudKitStateActor.zoneSubscriptionID(
            for: TwoEstateFixture.manifest.zoneIdentifier
        )
        let sub = await cloud.subscription(withID: expectedID)
        #expect(sub != nil,
                "subscription must be stored under the zone-derived ID '\(expectedID)'")

        try await engine.disable()
    }

    @Test("subscription sets shouldSendContentAvailable and clears badge")
    func subscriptionNotificationInfo() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        try await engine.registerZoneSubscription()

        let id = CloudKitStateActor.zoneSubscriptionID(
            for: TwoEstateFixture.manifest.zoneIdentifier
        )
        let sub = await cloud.subscription(withID: id)
        let info = sub?.notificationInfo
        #expect(info?.shouldSendContentAvailable == true,
                "silent-push: shouldSendContentAvailable must be true")
        #expect(info?.shouldBadge == false,
                "zone subscription must not produce badge updates")

        try await engine.disable()
    }

    @Test("deregisterZoneSubscription is safe when no subscription exists")
    func deregisterWhenAbsentIsSafe() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        // Call deregister without a prior register — must not throw.
        try await engine.deregisterZoneSubscription()
        #expect(await cloud.subscriptionCount == 0)

        try await engine.disable()
    }
}

// MARK: - Suite 2: Notification payload parser

@Suite("RemoteWake — notification payload parser")
struct RemoteWakeParserTests {

    // MARK: - Helpers

    /// Build a minimal CloudKit zone-subscription silent-push payload.
    ///
    /// The format mirrors the CloudKit APS payload for a CKRecordZoneSubscription
    /// with `shouldSendContentAvailable: true`:
    ///   userInfo["ck"]["met"]["zid"] = zone name
    static func payload(zoneName: String, cid: String = "iCloud.com.test") -> [AnyHashable: Any] {
        [
            "aps": ["content-available": 1] as [String: Any],
            "ck": [
                "nid": "test-notification-id",
                "nt": 2,             // CKNotificationType.recordZone
                "cid": cid,
                "met": [
                    "zid": zoneName,
                    "zeid": "_defaultOwner"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Tests

    @Test("valid zone payload extracts the zone name")
    func validPayloadExtractsZone() {
        let zoneName = "MyTestZone"
        let userInfo = Self.payload(zoneName: zoneName)
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(extracted == zoneName,
                "zone name must be extracted from ck.met.zid")
    }

    @Test("payload without ck key returns nil")
    func missingCKKeyReturnsNil() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1] as [String: Any]]
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(extracted == nil, "non-CloudKit payload must return nil")
    }

    @Test("payload without met key returns nil")
    func missingMetKeyReturnsNil() {
        let userInfo: [AnyHashable: Any] = [
            "ck": ["nid": "x", "nt": 2] as [String: Any]
        ]
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(extracted == nil, "payload without met sub-dict must return nil")
    }

    @Test("payload without zid key returns nil")
    func missingZidKeyReturnsNil() {
        let userInfo: [AnyHashable: Any] = [
            "ck": [
                "nid": "x",
                "nt": 2,
                "met": ["zeid": "_defaultOwner"] as [String: Any]
            ] as [String: Any]
        ]
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(extracted == nil, "payload without zid must return nil")
    }

    @Test("empty zid value returns nil")
    func emptyZidReturnsNil() {
        let userInfo: [AnyHashable: Any] = [
            "ck": [
                "nid": "x",
                "nt": 2,
                "met": ["zid": "", "zeid": "_defaultOwner"] as [String: Any]
            ] as [String: Any]
        ]
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(extracted == nil, "empty zone name must be rejected")
    }

    @Test("empty dict returns nil")
    func emptyDictReturnsNil() {
        let extracted = CloudKitSyncEngine.cloudKitZoneName(from: [:])
        #expect(extracted == nil, "empty userInfo must return nil")
    }
}

// MARK: - Suite 3: handleRemoteNotification integration

@Suite("RemoteWake — handleRemoteNotification integration")
struct RemoteWakeIntegrationTests {

    // MARK: - Helpers

    static func makeEnabledEngine(cloud: CloudZoneFake) async throws
        -> (CloudKitSyncEngine, any Storage)
    {
        let storage = try await TwoEstateFixture.makeStorage()
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: TwoEstateFixture.manifest, storage: storage)
        return (engine, storage)
    }

    // MARK: - Tests

    @Test("notification for correct zone returns true")
    func correctZoneReturnsTrue() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        let userInfo = RemoteWakeParserTests.payload(
            zoneName: TwoEstateFixture.manifest.zoneIdentifier
        )
        let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
        #expect(consumed == true, "notification targeting the engine's zone must be consumed")

        try await engine.disable()
    }

    @Test("notification for wrong zone returns false")
    func wrongZoneReturnsFalse() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        let userInfo = RemoteWakeParserTests.payload(zoneName: "SomeOtherZone")
        let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
        #expect(consumed == false, "notification for a different zone must NOT be consumed")

        try await engine.disable()
    }

    @Test("unparseable payload returns false without action")
    func unparseablePayloadReturnsFalse() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        let consumed = await engine.handleRemoteNotification(userInfo: [:])
        #expect(consumed == false, "empty / unrecognised payload must return false")

        try await engine.disable()
    }

    @Test("correct zone emits remoteWakeReceived on subscribe() stream")
    func correctZoneEmitsRemoteWakeReceived() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        // Subscribe before triggering the notification.
        let stream = engine.subscribe()

        // Collect events in a background task. The task exits as soon as
        // remoteWakeReceived arrives or the deadline is exceeded.
        let eventTask = Task<SyncEvent?, Never> {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            for await event in stream {
                if case .remoteWakeReceived = event { return event }
                if ContinuousClock.now > deadline { break }
            }
            return nil
        }

        let userInfo = RemoteWakeParserTests.payload(
            zoneName: TwoEstateFixture.manifest.zoneIdentifier
        )
        let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
        #expect(consumed == true)

        let event = await eventTask.value
        #expect(event != nil,
                "remoteWakeReceived must arrive on the subscribe() stream within 3 s")

        try await engine.disable()
    }

    @Test("wrong zone does not emit remoteWakeReceived")
    func wrongZoneDoesNotEmitEvent() async throws {
        let cloud = CloudZoneFake()
        let (engine, _) = try await Self.makeEnabledEngine(cloud: cloud)

        let stream = engine.subscribe()

        // Fire a wrong-zone notification and wait a short window for any event.
        let userInfo = RemoteWakeParserTests.payload(zoneName: "UnrelatedZone")
        let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
        #expect(consumed == false)

        // Collect any events for 100 ms using poll-deadline pattern.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        var gotWakeEvent = false
        let collector = Task<Bool, Never> {
            for await event in stream {
                if case .remoteWakeReceived = event { return true }
                if ContinuousClock.now > deadline { break }
            }
            return false
        }
        while ContinuousClock.now < deadline { await Task.yield() }
        collector.cancel()
        gotWakeEvent = await collector.value
        #expect(!gotWakeEvent,
                "wrong-zone notification must NOT emit remoteWakeReceived")

        try await engine.disable()
    }

    @Test("nudge fires a pull — lastPullAt updates after handleRemoteNotification")
    func nudgeFiresPull() async throws {
        // enablePolling: false → nudge() fires a direct one-shot pull().
        // The pull updates stateActor.lastPullAt, which is observable.
        let cloud = CloudZoneFake()
        let storage = try await TwoEstateFixture.makeStorage()
        let engine = CloudKitSyncEngine(containerIdentifier: nil, enablePolling: false)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: TwoEstateFixture.manifest, storage: storage)

        // Capture lastPullAt before the notification.
        let beforePull = await engine.stateActor.lastPullAt

        let userInfo = RemoteWakeParserTests.payload(
            zoneName: TwoEstateFixture.manifest.zoneIdentifier
        )
        let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
        #expect(consumed == true)

        // Poll briefly for lastPullAt to update (nudge fires pull asynchronously).
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var afterPull: Date? = nil
        while ContinuousClock.now < deadline {
            await Task.yield()
            afterPull = await engine.stateActor.lastPullAt
            if afterPull != beforePull { break }
        }
        #expect(afterPull != beforePull,
                "handleRemoteNotification must trigger a pull cycle (lastPullAt must update)")

        try await engine.disable()
    }
}
