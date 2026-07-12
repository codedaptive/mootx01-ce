import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class Mootx01AppIntentsTests: XCTestCase {
    private let bundleIdentifier = "com.codedaptive.mootx01.ios"
    private var definitions: IntentDefinitions!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let testEstateID = "app-intents-\(UUID().uuidString)"
        let app = XCUIApplication()
        app.launchEnvironment["MOOTX01_TEST_ESTATE_ID"] = testEstateID
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        app.terminate()
        definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
    }

    override func tearDown() async throws {
        if definitions != nil {
            let reset = definitions.intents["ResetTestEstateIntent"].makeIntent()
            _ = try? await reset.run()
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOOTX01_TEST_ESTATE_CLEAR"] = "1"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        app.terminate()
        definitions = nil
        try await super.tearDown()
    }

    func testMetadataAndColdCaptureRecall() async throws {
        let marker = "mootx01-app-test cold \(UUID().uuidString)"
        let capture = definitions.intents["CaptureDrawerIntent"].makeIntent(
            content: marker,
            location: "app-intents-tests",
            sensitivity: "normal"
        )
        _ = try await capture.run()

        let recall = definitions.intents["RecallDrawerIntent"].makeIntent(
            query: marker,
            publicOnly: false
        )
        let result = try await recall.run()
        // RecallDrawerIntent returns a typed [DrawerEntity] value; the test
        // process sees each entity as AnyAppEntity with dynamic properties.
        let recalled: [AnyAppEntity] = try result.value
        let contents: [String] = try recalled.map { try $0.content }
        XCTAssertTrue(contents.contains { $0.contains(marker) })
    }

    func testDrawerEntityIdentifierResolution() async throws {
        let marker = "mootx01-app-test entity \(UUID().uuidString)"
        let capture = definitions.intents["CaptureDrawerIntent"].makeIntent(
            content: marker,
            location: "app-intents-tests",
            sensitivity: "normal"
        )
        _ = try await capture.run()

        let drawerDefinition = definitions.entities["DrawerEntity"]
        let matches = try await drawerDefinition.entities(matching: marker)
        let matchingDrawer = try XCTUnwrap(matches.first { match in
            let content: String? = try? match.content
            return content?.contains(marker) == true
        })
        let identifier = matchingDrawer.identifier.instanceIdentifier
        let resolved = try await drawerDefinition.entities(identifiers: [identifier])
        XCTAssertEqual(resolved.count, 1)
        let content: String = try resolved[0].content
        XCTAssertTrue(content.contains(marker))
    }

    func testDebugStatusIntentRunsOutOfProcess() async throws {
        let status = definitions.intents["TestEstateStatusIntent"].makeIntent()
        let result = try await status.run()
        let text: String = try result.value
        XCTAssertTrue(text.localizedCaseInsensitiveContains("estate"))
    }

    func testEntityCollectionBatchMutationAndLongRunningReindex() async throws {
        let marker = "mootx01-app-test batch \(UUID().uuidString)"
        for index in 0..<2 {
            let capture = definitions.intents["CaptureDrawerIntent"].makeIntent(
                content: "\(marker) \(index)",
                location: "app-intents-tests",
                sensitivity: "normal"
            )
            _ = try await capture.run()
        }

        let drawerDefinition = definitions.entities["DrawerEntity"]
        let matches = try await drawerDefinition.entities(matching: marker)
        let selected = matches.filter { match in
            let content: String? = try? match.content
            return content?.contains(marker) == true
        }
        XCTAssertEqual(selected.count, 2)

        let mutate = definitions.intents["BatchMutateIntent"].makeIntent(
            drawers: selected,
            mutation: "confirm"
        )
        _ = try await mutate.run()

        let reindex = definitions.intents["ReindexEstateIntent"].makeIntent()
        _ = try await reindex.run()
    }
}
