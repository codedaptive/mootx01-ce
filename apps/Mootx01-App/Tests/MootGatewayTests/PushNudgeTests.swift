import Testing
import Foundation
@testable import MootGateway
@testable import ConvergenceKitCloudKit

// MARK: - APNs push-nudge tests (CVK-ICLOUD P5-M2)
//
// Two coverage areas:
//
// 1. cloudKitZoneName parser (CloudKitSyncEngine static, internal)
//    The parser extracts the zone name from a CloudKit silent-push payload's
//    `userInfo["ck"]["met"]["zid"]` path. Tested directly here because:
//    - The method is `internal` to ConvergenceKitCloudKit (accessible via @testable).
//    - Unit-testing it directly is faster than constructing a live engine and
//      verifying the full nudge path, and is the parser's only test coverage.
//    - Dict-based parsing was chosen over CKNotification(fromRemoteNotificationDictionary:)
//      specifically to keep the parser unit-testable (see RemoteWake.swift module comment).
//
// 2. MootSyncDriver.handleRemoteNotification — graceful disabled path
//    When the driver is not yet configured (default state at launch),
//    handleRemoteNotification MUST return false. This verifies the graceful-
//    degradation contract: push acceleration is best-effort; an uninitialized
//    driver never crashes, never blocks, and never produces a false .newData.

@Suite("PushNudge — cloudKitZoneName parser + MootSyncDriver graceful-disabled path")
struct PushNudgeTests {

    // MARK: - cloudKitZoneName parser

    @Test("valid CloudKit zone-change payload extracts zone name")
    func parserValidPayload() {
        let userInfo: [AnyHashable: Any] = [
            "ck": [
                "met": [
                    "zid": "com.codedaptive.mootx01.estate"
                ]
            ]
        ]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == "com.codedaptive.mootx01.estate")
    }

    @Test("empty dict returns nil")
    func parserEmptyDict() {
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: [:])
        #expect(zoneName == nil)
    }

    @Test("payload without 'ck' key returns nil (non-CloudKit push)")
    func parserMissingCKKey() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1]]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == nil)
    }

    @Test("payload with 'ck' but missing 'met' sub-dict returns nil")
    func parserMissingMetKey() {
        let userInfo: [AnyHashable: Any] = ["ck": ["nid": "irrelevant"]]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == nil)
    }

    @Test("payload with 'met' but missing 'zid' returns nil")
    func parserMissingZidKey() {
        let userInfo: [AnyHashable: Any] = [
            "ck": ["met": ["other": "value"]]
        ]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == nil)
    }

    @Test("empty zone name string returns nil")
    func parserEmptyZoneName() {
        let userInfo: [AnyHashable: Any] = [
            "ck": ["met": ["zid": ""]]
        ]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == nil)
    }

    @Test("payload with wrong type for 'zid' returns nil")
    func parserWrongTypeZid() {
        let userInfo: [AnyHashable: Any] = [
            "ck": ["met": ["zid": 42]]  // Int instead of String
        ]
        let zoneName = CloudKitSyncEngine.cloudKitZoneName(from: userInfo)
        #expect(zoneName == nil)
    }

    // MARK: - MootSyncDriver graceful disabled path

    @Test("handleRemoteNotification returns false when driver not configured (engine nil)")
    func driverNotConfiguredReturnsFalse() async {
        // MootSyncDriver.shared defaults to .disabled at app start.
        // cloudKitEngine is nil until syncNow() creates it post-enable.
        // handleRemoteNotification MUST return false without crashing.
        let userInfo: [AnyHashable: Any] = [
            "ck": ["met": ["zid": "com.codedaptive.mootx01.estate"]]
        ]
        let result = await MootSyncDriver.shared.handleRemoteNotification(userInfo: userInfo)
        #expect(result == false,
                "handleRemoteNotification must return false when cloudKitEngine is nil (graceful degradation — B-11)")
    }

    @Test("handleRemoteNotification returns false for non-CK payload when driver not configured")
    func driverNotConfiguredNonCKPayloadReturnsFalse() async {
        let result = await MootSyncDriver.shared.handleRemoteNotification(userInfo: [:])
        #expect(result == false)
    }
}
