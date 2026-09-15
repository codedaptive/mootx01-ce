// MootProductIdentityTests.swift
//
// Three guards. The constants match the shared fixture, so a value cannot
// change in one place; every value is normalised (lowercase, begins with a
// root); and no Swift source outside this library spells a root-prefixed
// string literal, so a new identity string cannot appear anywhere else.

import Foundation
import Testing
@testable import MootProductIdentity

@Suite("MootProductIdentity")
struct MootProductIdentityTests {

    private func fixture() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "product_identity", withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private func string(_ fixture: [String: Any], _ path: [String]) throws -> String {
        var node: Any = fixture
        for key in path {
            node = try #require((node as? [String: Any])?[key], "fixture path \(path.joined(separator: "."))")
        }
        return try #require(node as? String)
    }

    /// Every constant the library exports, by fixture path, so the fixture
    /// and this list are the two places a value is named and they must agree.
    private static let constants: [(path: [String], value: String)] = [
        (["productRoot"], MootProductIdentity.productRoot),
        (["vendorRoot"], MootProductIdentity.vendorRoot),
        (["storage", "applicationSupportFolder"], MootProductIdentity.Storage.applicationSupportFolder),
        (["storage", "unixDataFolder"], MootProductIdentity.Storage.unixDataFolder),
        (["storage", "latticeFolder"], MootProductIdentity.Storage.latticeFolder),
        (["storage", "catalogFile"], MootProductIdentity.Storage.catalogFile),
        (["storage", "databasesFolder"], MootProductIdentity.Storage.databasesFolder),
        (["storage", "defaultEstateName"], MootProductIdentity.Storage.defaultEstateName),
        (["storage", "estateDatabaseFile"], MootProductIdentity.Storage.estateDatabaseFile),
        (["storage", "communityDaemonFolder"], MootProductIdentity.Storage.communityDaemonFolder),
        (["logging", "subsystem"], MootProductIdentity.Logging.subsystem),
        (["services", "daemonLabel"], MootProductIdentity.Services.daemonLabel),
        (["services", "managerLabel"], MootProductIdentity.Services.managerLabel),
        (["services", "contractHostOwner"], MootProductIdentity.Services.contractHostOwner),
        (["services", "daemonProviderLaunchAgentLabel"], MootProductIdentity.Services.daemonProviderLaunchAgentLabel),
        (["services", "bonjourServiceType"], MootProductIdentity.Services.bonjourServiceType),
        (["services", "federationBonjourServiceType"], MootProductIdentity.Services.federationBonjourServiceType),
        (["services", "urlScheme"], MootProductIdentity.Services.urlScheme),
        (["keychain", "estateKeyService"], MootProductIdentity.Keychain.estateKeyService),
        (["keychain", "sharedAccessGroup"], MootProductIdentity.Keychain.sharedAccessGroup),
        (["keychain", "estateIdentityService"], MootProductIdentity.Keychain.estateIdentityService),
        (["keychain", "lanCredentialService"], MootProductIdentity.Keychain.lanCredentialService),
        (["keychain", "daemonAuthService"], MootProductIdentity.Keychain.daemonAuthService),
        (["keychain", "daemonProofService"], MootProductIdentity.Keychain.daemonProofService),
        (["keychain", "crossInstallCustodyProofService"], MootProductIdentity.Keychain.crossInstallCustodyProofService),
        (["keychain", "secretSyncSigningHandleService"], MootProductIdentity.Keychain.secretSyncSigningHandleService),
        (["keychain", "secretSyncAgreementHandleService"], MootProductIdentity.Keychain.secretSyncAgreementHandleService),
        (["keychain", "secretSyncProtectedHeadService"], MootProductIdentity.Keychain.secretSyncProtectedHeadService),
        (["keychain", "syncTierServicePrefix"], MootProductIdentity.Keychain.syncTierService("")),
        (["keychain", "syncTierAccessGroup"], MootProductIdentity.Keychain.syncTierAccessGroup),
        (["keychain", "estateSurgeryCloneRecipientService"], MootProductIdentity.Keychain.estateSurgeryCloneRecipientService),
        (["apple", "appGroup"], MootProductIdentity.Apple.appGroup),
        (["apple", "spotlightDomain"], MootProductIdentity.Apple.spotlightDomain),
        (["apple", "miningRefreshTaskIdentifier"], MootProductIdentity.Apple.miningRefreshTaskIdentifier),
        (["apple", "shareErrorDomain"], MootProductIdentity.Apple.shareErrorDomain),
        (["apple", "bundleIdentifiers", "macOSApp"], MootProductIdentity.Apple.BundleIdentifiers.macOSApp),
        (["apple", "bundleIdentifiers", "iOSApp"], MootProductIdentity.Apple.BundleIdentifiers.iOSApp),
        (["apple", "bundleIdentifiers", "communityMacOSApp"], MootProductIdentity.Apple.BundleIdentifiers.communityMacOSApp),
        (["apple", "bundleIdentifiers", "daemonProvider"], MootProductIdentity.Apple.BundleIdentifiers.daemonProvider),
        (["apple", "bundleIdentifiers", "daemonHelper"], MootProductIdentity.Apple.BundleIdentifiers.daemonHelper),
        (["apple", "bundleIdentifiers", "daemonProofHost"], MootProductIdentity.Apple.BundleIdentifiers.daemonProofHost),
        (["apple", "bundleIdentifiers", "custodyProofSandboxHelper"], MootProductIdentity.Apple.BundleIdentifiers.custodyProofSandboxHelper),
        (["apple", "bundleIdentifiers", "custodyProofDeveloperIDDaemon"], MootProductIdentity.Apple.BundleIdentifiers.custodyProofDeveloperIDDaemon),
        (["preferences", "residency"], MootProductIdentity.Preferences.residency),
        (["preferences", "gatewayHasCompletedOnboarding"], MootProductIdentity.Preferences.gatewayHasCompletedOnboarding),
        (["preferences", "gatewayIsAdvancedMode"], MootProductIdentity.Preferences.gatewayIsAdvancedMode),
        (["preferences", "gatewayShowQuickCapture"], MootProductIdentity.Preferences.gatewayShowQuickCapture),
        (["preferences", "portableOnPowerOnly"], MootProductIdentity.Preferences.portableOnPowerOnly),
        (["preferences", "portableServiceName"], MootProductIdentity.Preferences.portableServiceName),
        (["queues", "ariaHTTPAccept"], MootProductIdentity.Queues.ariaHTTPAccept),
        (["queues", "ariaHTTPRawRead"], MootProductIdentity.Queues.ariaHTTPRawRead),
        (["queues", "managerControlChannelAccept"], MootProductIdentity.Queues.managerControlChannelAccept),
        (["queues", "managerHTTPReadAPIAccept"], MootProductIdentity.Queues.managerHTTPReadAPIAccept),
        (["queues", "lanDiscovery"], MootProductIdentity.Queues.lanDiscovery),
        (["queues", "lanBrowser"], MootProductIdentity.Queues.lanBrowser),
    ]

    @Test func constantsMatchTheSharedFixture() throws {
        let f = try fixture()
        for constant in Self.constants {
            #expect(try string(f, constant.path) == constant.value, "\(constant.path.joined(separator: "."))")
        }
    }

    /// Every fixture leaf is also a constant: a value added to the fixture
    /// without a constant, or the reverse, fails here.
    @Test func everyFixtureLeafIsAConstant() throws {
        func leaves(_ node: Any, _ prefix: [String]) -> [[String]] {
            guard let object = node as? [String: Any] else { return [prefix] }
            return object.keys.sorted().flatMap { leaves(object[$0]!, prefix + [$0]) }
        }
        let fixtureLeaves = Set(leaves(try fixture(), []).map { $0.joined(separator: ".") })
        let constantPaths = Set(Self.constants.map { $0.path.joined(separator: ".") })
        #expect(fixtureLeaves == constantPaths, "fixture leaves and constants differ: \(fixtureLeaves.symmetricDifference(constantPaths).sorted())")
    }

    /// The list above is hand-maintained, so a constant added to the source
    /// without a fixture leaf would escape `everyFixtureLeafIsAConstant`. This
    /// reads the library source and refuses any `public static let` whose name
    /// is not the last component of a fixture path. Keyed on the NAME, not the
    /// value: two constants may share a value (`urlScheme` and `unixDataFolder`
    /// both read "mootx01"). Twin of the Rust `every_pub_const_is_listed`.
    @Test func everySourceConstantIsAFixtureLeaf() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MootProductIdentity/MootProductIdentity.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let leafNames = Set(Self.constants.map { $0.path.last! })
        var seen: Set<String> = []
        for line in source.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.hasPrefix("public static let ") else { continue }
            let name = String(trimmed.dropFirst("public static let ".count).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            #expect(leafNames.contains(name), "source `public static let \(name)` is not a fixture leaf, so the fixture does not pin it")
            seen.insert(name)
        }
        // Every leaf that is a stored constant is in the source; the one
        // function-backed leaf (`syncTierServicePrefix`) is not a `let`.
        #expect(leafNames.subtracting(seen) == ["syncTierServicePrefix"],
                "fixture leaves with no `public static let`: \(leafNames.subtracting(seen).sorted())")
    }

    @Test func everyValueIsNormalisedUnderARoot() {
        let roots = [MootProductIdentity.productRoot, MootProductIdentity.vendorRoot]
        for constant in Self.constants where constant.path != ["productRoot"] && constant.path != ["vendorRoot"] {
            let value = constant.value
            // On-disk names are file names, not reverse domains.
            if constant.path[0] == "storage", constant.path[1] != "applicationSupportFolder", constant.path[1] != "latticeFolder" {
                #expect(!value.contains("/") && value == value.lowercased())
                continue
            }
            // Bonjour types and the URL scheme are Apple grammars, not reverse domains.
            if constant.path[0] == "services", ["bonjourServiceType", "federationBonjourServiceType", "urlScheme"].contains(constant.path[1]) {
                #expect(value.hasPrefix("_mootx01") || value == "mootx01")
                continue
            }
            let stripped = value.hasPrefix("group.") ? String(value.dropFirst("group.".count)) : value
            #expect(roots.contains { stripped == $0 || stripped.hasPrefix($0 + ".") }, "\(value) is not under a root")
            #expect(value == value.lowercased() || constant.path[0] == "preferences" || constant.path[0] == "queues",
                    "\(value) must be lowercase")
        }
    }

    @Test func applicationSupportDirectoryIsSpelledFromTheFolder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let dir = MootProductIdentity.Storage.applicationSupportDirectory(homeDirectory: home)
        #expect(dir.path == "/Users/someone/Library/Application Support/com.mootx01.ce")
    }

    @Test func processHomeFollowsTheSandboxFact() {
        let own = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let group = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/TEAM.group.com.codedaptive.mootx01", isDirectory: true)
        let entitled = ["TEAM.\(MootProductIdentity.Apple.appGroup)", "TEAM.group.other"]
        // Unsandboxed: the user's home, whatever the entitlements say.
        #expect(MootProductIdentity.Storage.processHome(environment: [:], entitledGroups: entitled, groupContainer: { _ in group }) == own)
        // Sandboxed with the product's group: the group container the signature named.
        var seen: [String] = []
        let sandboxed = ["APP_SANDBOX_CONTAINER_ID": "com.codedaptive.mootx01.macos"]
        #expect(MootProductIdentity.Storage.processHome(environment: sandboxed, entitledGroups: entitled, groupContainer: { seen.append($0); return group }) == group)
        #expect(seen == ["TEAM.\(MootProductIdentity.Apple.appGroup)"], "the expanded entitlement string is what is resolved, never a composed prefix")
        // Sandboxed without the group, or with a group the system cannot resolve: the process's own container.
        #expect(MootProductIdentity.Storage.processHome(environment: sandboxed, entitledGroups: ["TEAM.group.other"], groupContainer: { _ in group }) == own)
        #expect(MootProductIdentity.Storage.processHome(environment: sandboxed, entitledGroups: entitled, groupContainer: { _ in nil }) == own)
        // The configuration directory hangs off that home.
        #expect(MootProductIdentity.Storage.applicationSupportDirectory(homeDirectory: group).path
                == group.path + "/Library/Application Support/com.mootx01.ce")
    }

    @Test func loggingCategoryIsModuleOrModuleDotTopic() {
        #expect(MootProductIdentity.Logging.category("CorpusKit") == "CorpusKit")
        #expect(MootProductIdentity.Logging.category("ConvergenceKitCloudKit", topic: "Engine") == "ConvergenceKitCloudKit.Engine")
        #expect(MootProductIdentity.Logging.category("LocusKit", topic: "") == "LocusKit")
    }

    /// No Swift source outside this library spells a root-prefixed string
    /// literal. Tests, UI tests, the fixture, `project.yml`, the entitlements
    /// and the two signed proof rigs (CustodyProof, U3SignedHost: standalone
    /// Xcode projects that exist to prove Keychain custody across signing
    /// identities and spell what they probe on purpose) are the only other
    /// places a value may appear.
    @Test func noOtherSourceSpellsARootLiteral() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { Issue.record("repository root not found above \(#filePath)"); return }
            root = parent
        }
        let scanRoots = ["apps", "packages", "tools"].map { root.appendingPathComponent($0, isDirectory: true) }
        let patterns = ["\"\(MootProductIdentity.productRoot)", "\"\(MootProductIdentity.vendorRoot)", "\"group.\(MootProductIdentity.vendorRoot)"]
        var offenders: [String] = []
        for scanRoot in scanRoots {
            guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator {
                let path = url.path
                guard url.pathExtension == "swift",
                      !path.contains("/.build/"), !path.contains("/Tests/"), !path.contains("/UITests/"),
                      !path.contains("/CustodyProof/"), !path.contains("/U3SignedHost/"),
                      !path.contains("/MootProductIdentity/") else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    if patterns.contains(where: { trimmed.contains($0) }) {
                        offenders.append("\(path.dropFirst(root.path.count + 1)):\(index + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "identity literals outside MootProductIdentity:\n\(offenders.joined(separator: "\n"))")
    }
}
