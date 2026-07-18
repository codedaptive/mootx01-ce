import Foundation
import Testing
@testable import MootGateway

@Suite("Estate configuration")
struct EstateConfigurationTests {
    @Test("production resolution selects a durable application-support database")
    func productionResolutionIsDurable() throws {
        let configuration = try EstateConfigurationResolver.resolve(environment: [:])
        guard case .sqlite(let url) = configuration else {
            Issue.record("production resolution selected a non-durable estate")
            return
        }
        #expect(url.lastPathComponent == "mootx01.sqlite")
        #expect(url.pathComponents.contains("mootx01"))
    }

    @Test("DEBUG test estate id selects a stable disposable database")
    func testEstateIDSelectsDisposableDatabase() throws {
        let configuration = try EstateConfigurationResolver.resolve(environment: [
            EstateConfigurationResolver.testEstateIDEnvironmentKey: "cold-start-123"
        ])
        guard case .sqlite(let url) = configuration else {
            Issue.record("test estate id did not select SQLite")
            return
        }
        #expect(url.lastPathComponent == "mootx01.sqlite")
        #expect(url.pathComponents.contains("Mootx01-Tests"))
        #expect(url.pathComponents.contains("cold-start-123"))
    }

    @Test("invalid test estate id is refused")
    func invalidTestEstateIDIsRefused() {
        #expect(throws: EstateConfigurationResolver.Error.invalidTestEstateID("../real-estate")) {
            _ = try EstateConfigurationResolver.resolve(environment: [
                EstateConfigurationResolver.testEstateIDEnvironmentKey: "../real-estate"
            ])
        }
    }

    @Test("in-memory estate requires an explicit DEBUG test mode")
    func inMemoryRequiresExplicitTestMode() throws {
        let configuration = try EstateConfigurationResolver.resolve(environment: [
            EstateConfigurationResolver.testEstateModeEnvironmentKey: "in-memory"
        ])
        #expect(configuration == .inMemoryTesting)
    }

    @Test("DEBUG test override can be cleared after system-intent testing")
    func persistedOverrideCanBeCleared() throws {
        let suiteName = "estate-config-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        EstateConfigurationResolver.installDebugLaunchOverride(
            environment: [EstateConfigurationResolver.testEstateIDEnvironmentKey: "temporary"],
            userDefaults: defaults
        )
        let persisted = try EstateConfigurationResolver.resolve(
            environment: [:], userDefaults: defaults
        )
        guard case .sqlite(let persistedURL) = persisted else {
            Issue.record("override did not persist")
            return
        }
        #expect(persistedURL.pathComponents.contains("temporary"))

        EstateConfigurationResolver.installDebugLaunchOverride(
            environment: [EstateConfigurationResolver.clearTestEstateEnvironmentKey: "1"],
            userDefaults: defaults
        )
        let cleared = try EstateConfigurationResolver.resolve(
            environment: [:], userDefaults: defaults
        )
        guard case .sqlite(let clearedURL) = cleared else {
            Issue.record("cleared resolution was not durable")
            return
        }
        #expect(!clearedURL.pathComponents.contains("Mootx01-Tests"))
    }
}
