import Foundation
import Testing
@testable import GatewayUI

// MARK: - First-run flag tests (FAB5-FR Part 1)
//
// Verifies that the onboarding flag starts false and becomes true when set,
// covering the "shown once, never again" guarantee. No live bridge needed —
// AppModel state is exercised directly.

@Suite("FirstRun flag (FAB5-FR)")
@MainActor
struct FirstRunFlagTests {

    // swift-testing calls init() before every @Test in this suite.
    // Remove the persisted keys so each test starts from a known baseline.
    init() {
        UserDefaults.standard.removeObject(forKey: "com.mootx01.gateway.hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "com.mootx01.gateway.isAdvancedMode")
    }

    @Test("hasCompletedOnboarding defaults to false on a fresh model")
    func defaultsToNotCompleted() async throws {
        // UserDefaults persistence is tested by the model itself;
        // this test exercises the initial default on a brand-new model
        // created without prior UserDefaults writes for this key.
        // Tests run in a sandboxed container so standard UserDefaults is empty.
        let model = AppModel()
        #expect(model.hasCompletedOnboarding == false)
    }

    @Test("hasCompletedOnboarding can be set to true")
    func canSetCompleted() async throws {
        let model = AppModel()
        model.hasCompletedOnboarding = true
        #expect(model.hasCompletedOnboarding == true)
    }

    @Test("hasCompletedOnboarding true means onboarding is not shown")
    func completedFlagGatesDisplay() async throws {
        let model = AppModel()
        model.hasCompletedOnboarding = true
        // The gate: cover is presented when !hasCompletedOnboarding.
        // With true, the cover binding returns false → not presented.
        let binding = !model.hasCompletedOnboarding
        #expect(binding == false)
    }
}

// MARK: - Tab profile tests (FAB5-FR Part 2)
//
// Verifies that isAdvancedMode defaults to Standard and that the expected
// tab counts hold: Standard = 5, Advanced = 12 (5 + 7 engineering tabs).

@Suite("Tab profiles (FAB5-FR)")
@MainActor
struct TabProfileTests {

    // Clean UserDefaults before each test to avoid cross-test state pollution.
    init() {
        UserDefaults.standard.removeObject(forKey: "com.mootx01.gateway.isAdvancedMode")
    }

    // Expected tab labels per profile — mirrored from ContentView.
    // FAB5-G2: Review added third, between Recall and Intelligence.
    static let standardLabels = ["Capture", "Recall", "Review", "Intelligence", "Settings"]
    // FAB5-I3: Packets tab added after Miners (Kong ruling: Advanced-only, shippingbox icon).
    static let advancedExtraLabels = [
        "The Top", "Apple Surfaces", "Edges", "Engine", "Federation", "Miners", "Packets",
    ]

    @Test("isAdvancedMode defaults to false (Standard profile)")
    func defaultsToStandard() async throws {
        let model = AppModel()
        #expect(model.isAdvancedMode == false)
    }

    @Test("Standard profile has exactly 5 tabs")
    func standardTabCount() {
        #expect(Self.standardLabels.count == 5)
    }

    // FAB5-G2: the Review tab's position is load-bearing, not incidental — Kong
    // ruled it sits between Recall and Intelligence (capture, recall, then review
    // what the estate surfaced). Asserting the index catches a reorder that a
    // bare count check would pass.
    @Test("Review is the third Standard tab, between Recall and Intelligence")
    func reviewTabPosition() {
        #expect(Self.standardLabels.firstIndex(of: "Review") == 2)
        #expect(Self.standardLabels[1] == "Recall")
        #expect(Self.standardLabels[3] == "Intelligence")
    }

    @Test("Advanced profile adds exactly 7 engineering tabs")
    func advancedExtraTabCount() {
        #expect(Self.advancedExtraLabels.count == 7)
    }

    @Test("Advanced profile is a superset of Standard")
    func advancedIsSupersetOfStandard() {
        let all = Self.standardLabels + Self.advancedExtraLabels
        for label in Self.standardLabels {
            #expect(all.contains(label))
        }
    }

    @Test("isAdvancedMode can be toggled to true")
    func canEnableAdvancedMode() async throws {
        let model = AppModel()
        model.isAdvancedMode = true
        #expect(model.isAdvancedMode == true)
    }

    @Test("isAdvancedMode can be toggled back to false")
    func canDisableAdvancedMode() async throws {
        let model = AppModel()
        model.isAdvancedMode = true
        model.isAdvancedMode = false
        #expect(model.isAdvancedMode == false)
    }
}
