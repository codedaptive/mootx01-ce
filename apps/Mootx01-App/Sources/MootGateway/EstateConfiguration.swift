import Foundation

/// The one estate attachment selected for the lifetime of an app process.
public enum GatewayEstateConfiguration: Sendable, Equatable {
    case sqlite(URL)
    #if DEBUG
    case inMemoryTesting
    #endif
}

/// Resolves the estate used by the GUI, App Intents, URL routes, and miners.
public enum EstateConfigurationResolver {
    public static let testEstateIDEnvironmentKey = "MOOTX01_TEST_ESTATE_ID"
    public static let testEstateModeEnvironmentKey = "MOOTX01_TEST_ESTATE_MODE"
    public static let clearTestEstateEnvironmentKey = "MOOTX01_TEST_ESTATE_CLEAR"
    #if DEBUG
    private static let persistedTestEstateIDKey = "mootx01.debug.test-estate-id"
    #endif

    public enum Error: Swift.Error, Equatable {
        case invalidTestEstateID(String)
        case unsupportedTestEstateMode(String)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) throws -> GatewayEstateConfiguration {
        #if DEBUG
        if let mode = environment[testEstateModeEnvironmentKey], !mode.isEmpty {
            guard mode == "in-memory" else {
                throw Error.unsupportedTestEstateMode(mode)
            }
            return .inMemoryTesting
        }

        let testIdentifier = environment[testEstateIDEnvironmentKey]
            ?? userDefaults.string(forKey: persistedTestEstateIDKey)
        if let identifier = testIdentifier, !identifier.isEmpty {
            guard identifier.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }) else {
                throw Error.invalidTestEstateID(identifier)
            }
            let url = fileManager.temporaryDirectory
                .appendingPathComponent("Mootx01-Tests", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("mootx01.sqlite", isDirectory: false)
            return .sqlite(url)
        }
        #endif

        return .sqlite(defaultDatabaseURL(fileManager: fileManager))
    }

    #if DEBUG
    /// Persist an XCUITest launch override so a later system-launched intent
    /// process selects the same disposable estate after the setup app exits.
    public static func installDebugLaunchOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) {
        if environment[clearTestEstateEnvironmentKey] == "1" {
            userDefaults.removeObject(forKey: persistedTestEstateIDKey)
            return
        }
        guard let identifier = environment[testEstateIDEnvironmentKey], !identifier.isEmpty else {
            return
        }
        userDefaults.set(identifier, forKey: persistedTestEstateIDKey)
    }
    #endif

    /// `<Application Support>/mootx01/mootx01.sqlite` in the current app container.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("mootx01", isDirectory: true)
            .appendingPathComponent("mootx01.sqlite", isDirectory: false)
    }
}
