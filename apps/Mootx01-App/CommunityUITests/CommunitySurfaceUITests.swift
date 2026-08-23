import XCTest

@MainActor
final class CommunitySurfaceUITests: XCTestCase {
    func testCapturePrivacyControlsAreReachableAndIndependent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let destination = element("community.capture.destination", in: app)
        let sensitivity = element("community.capture.sensitivity", in: app)
        let exportEligibility = element("community.capture.export-eligibility", in: app)
        let lanEligibility = element("community.capture.lan-eligibility", in: app)

        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertTrue(sensitivity.exists)
        XCTAssertTrue(exportEligibility.exists)
        XCTAssertTrue(lanEligibility.exists)
        XCTAssertEqual(exportEligibility.label, "Eligible for export")
        XCTAssertEqual(lanEligibility.label, "Eligible for LAN sharing")
        XCTAssertNotEqual(exportEligibility.identifier, lanEligibility.identifier)
    }

    func testEveryCommunityOperationsSurfaceIsReachableByStableIdentifier() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let operations = element("community.destination.operations", in: app)
        XCTAssertTrue(operations.waitForExistence(timeout: 10))
        operations.click()

        XCTAssertTrue(
            element("community.operations.workspace", in: app).waitForExistence(timeout: 5)
        )

        let destinations = [
            ("workspace.review", "community.operations.review"),
            ("workspace.obsidian", "community.operations.obsidian"),
            ("workspace.transfer", "community.operations.transfer"),
            ("workspace.lan", "community.operations.lan"),
        ]
        for (identifier, surfaceIdentifier) in destinations {
            let row = element(identifier, in: app)
            XCTAssertTrue(row.exists, "Missing operations row \(identifier)")
            XCTAssertFalse(row.label.isEmpty, "Operations row \(identifier) has no accessible label")
            row.click()
            XCTAssertTrue(
                element(surfaceIdentifier, in: app).waitForExistence(timeout: 3),
                "Operations row \(identifier) did not expose \(surfaceIdentifier)"
            )
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
