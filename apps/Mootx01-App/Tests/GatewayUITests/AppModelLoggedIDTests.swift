import Testing
import Foundation
@testable import GatewayUI

// Tests for AppModel.lastLoggedID().
//
// The method scans intentRunLog newest-first (index 0 is newest) for a line
// that begins with "capture:" and contains a UUID matching the RFC 4122
// pattern. It returns the first UUID found, or nil when no capture log line
// is present. These tests verify both the happy path and the nil-return path
// without a live bridge — intentRunLog is populated directly because the
// method only reads that stored property.

@Suite("AppModel — lastLoggedID")
@MainActor
struct AppModelLoggedIDTests {

    /// Feed a log that matches the exact format written by runIntent("capture"):
    /// "capture: filed memory <UUID> — filed into the live estate."
    /// lastLoggedID() must extract and return the UUID.
    @Test("returns the UUID from a capture log line")
    func returnsUUIDFromCaptureLog() {
        let model = AppModel()
        let knownID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        // Matches the format written by runIntent("capture"):
        // "capture: \(resultFirstLine) — filed into the live estate."
        // where resultFirstLine is "filed memory <UUID>" from ToolDispatch.runFileMemory.
        model.intentRunLog = ["capture: filed memory \(knownID) — filed into the live estate."]
        #expect(model.lastLoggedID() == knownID)
    }

    /// When intentRunLog contains no "capture:" lines, lastLoggedID() must
    /// return nil — callers fall back to the sentinel "no-id-captured-yet".
    @Test("returns nil when no capture log line is present")
    func returnsNilWhenNoCaptureLine() {
        let model = AppModel()
        model.intentRunLog = ["recall: RecallDrawerIntent.perform() ran — results returned as IntentResult."]
        #expect(model.lastLoggedID() == nil)
    }

    /// When intentRunLog is empty, lastLoggedID() must return nil.
    @Test("returns nil when the run log is empty")
    func returnsNilWhenLogEmpty() {
        let model = AppModel()
        // intentRunLog defaults to [] — no writes needed.
        #expect(model.lastLoggedID() == nil)
    }

    /// When multiple capture lines are present, lastLoggedID() returns the
    /// UUID from the most recent one (index 0 — the log is insert-at-0 so
    /// the newest capture is always first).
    @Test("returns the UUID from the most recent capture when multiple are present")
    func returnsMostRecentCaptureUUID() {
        let model = AppModel()
        let newerID = "FFFFFFFF-0000-0000-0000-000000000001"
        let olderID = "00000000-1111-2222-3333-444444444444"
        // Index 0 is newest — insert order mirrors runIntent("capture") behavior.
        model.intentRunLog = [
            "capture: filed memory \(newerID) — filed into the live estate.",
            "capture: filed memory \(olderID) — filed into the live estate.",
        ]
        #expect(model.lastLoggedID() == newerID)
    }
}
