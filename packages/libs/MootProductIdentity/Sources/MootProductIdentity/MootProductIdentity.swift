// MootProductIdentity.swift
//
// The product's identity, spelled once. Everything that names the product on
// disk, in logs, to launchd, to the Keychain or to the operating system reads
// these; nothing else repeats the strings. Two roots and nothing else are
// spelled by hand; every other value is a root plus a suffix, composed here.
//
// Two roots, two meanings (Bob, 2026-09-08):
//
// - `productRoot` (`com.mootx01`): what the product names for itself and
//   controls outright: its configuration folder, its log subsystem, its
//   launchd labels, the Keychain items it mints for its own state, its
//   preference keys and its thread and queue labels. An Enterprise install
//   beside a Community one takes a sibling folder (`com.mootx01.ee`).
// - `vendorRoot` (`com.codedaptive.mootx01`): what Apple ties to the signing
//   identity and the developer account: bundle identifiers, the app group,
//   the shared Keychain access group, the Spotlight domain, background task
//   identifiers, and the Keychain services registered before the product root
//   existed and kept because existing items are keyed by them.
//
// Normalisation: every value is lowercase, dot-separated, and begins with a
// root; hyphens appear only inside a suffix Apple or an existing Keychain
// item already carries. `Fixtures/product_identity.json` lists every value
// and the conformance test pins the constants to it; a second test scans the
// repository's Swift sources and refuses any string literal that starts with
// a root outside this library, so a new spelling cannot creep in.
//
// Apple reads bundle identifiers, the app group and the Bonjour service type
// from `project.yml` and the entitlements as literals; `Apple` mirrors them
// so code refers to them by name, and the fixture pins the mirror.
//
// The Rust twin is `rust/src/lib.rs` (crate `moot-product-identity`), pinned
// to the same `Fixtures/product_identity.json` by `rust/tests/fixture_parity.rs`
// leaf by leaf. A value changes in the fixture and in both ports together;
// either port's parity test fails until all three agree.

import Foundation
import CoreFoundation
#if canImport(Security)
import Security
#endif

public enum MootProductIdentity {

    /// `com.mootx01`: the product's own name for itself.
    public static let productRoot = "com.mootx01"

    /// `com.codedaptive.mootx01`: the name Apple knows the product by.
    public static let vendorRoot = "com.codedaptive.mootx01"

    /// `<productRoot>.<suffix>`.
    static func product(_ suffix: String) -> String { "\(productRoot).\(suffix)" }

    /// `<vendorRoot>.<suffix>`.
    static func vendor(_ suffix: String) -> String { "\(vendorRoot).\(suffix)" }

    // MARK: Storage

    /// Where the product keeps its configuration on this machine.
    public enum Storage {
        /// Folder name under Application Support: `com.mootx01.ce`. The
        /// estate catalog and every install-wide file live under it; the
        /// Enterprise edition's sibling would be `com.mootx01.ee`.
        public static let applicationSupportFolder = product("ce")

        /// The catalog file inside the configuration directory, the folder
        /// that is the default database location on first run, the primary
        /// estate's name and the estate database file name. GeniusLocusKit's
        /// `EstateCatalogNames` reads these; the daemon provider's census,
        /// which cannot depend on the kit, spells the canonical estate path
        /// from them too, so the two cannot drift.
        public static let catalogFile = "estatecatalog.json"
        public static let databasesFolder = "databases"
        public static let defaultEstateName = "default"
        public static let estateDatabaseFile = "estate.sqlite"

        /// The community daemon's sidecar directory name, a subdirectory of
        /// the configuration directory beside `estatecatalog.json`. Sidecar
        /// JSON files (capture ledger, review state, Obsidian authorization,
        /// LAN state, estate metadata and operation state) live here.
        public static let communityDaemonFolder = "community-daemon"

        /// Folder under Application Support for the lattice novel-token pool
        /// (`com.mootx01.lattice`), a machine-wide resource shared across
        /// installs rather than a per-install configuration file.
        public static let latticeFolder = product("lattice")

        /// The Rust port's configuration folder on Unix targets, under
        /// `${XDG_DATA_HOME:-~/.local/share}`: the program name, as every
        /// program under `.local/share` is named. Never used by the Swift
        /// product (its folder is `applicationSupportFolder`); carried here so
        /// the fixture pins the most load-bearing Rust-only path string the
        /// way it pins every other identity value.
        public static let unixDataFolder = "mootx01"

        /// `<home>/Library/Application Support/<applicationSupportFolder>`.
        /// Pure path arithmetic; touches nothing.
        public static func applicationSupportDirectory(homeDirectory: URL) -> URL {
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(applicationSupportFolder, isDirectory: true)
                .standardizedFileURL
        }

        /// The home the configuration directory hangs off, decided by a fact
        /// about the running process (DECISION_INSTALL_TAKEOVER_2026-09-08):
        ///
        /// - unsandboxed (the CLI, its resident, moot-mgr, the direct
        ///   Developer ID provider shell): the user's home, so the CLI
        ///   family shares one catalog under `~/Library`;
        /// - sandboxed with the product's app group in its signed
        ///   entitlements (the Community or Pro app and its nested helper):
        ///   the group container, the one directory every member of a
        ///   signed family can reach, so the app and its daemon share one
        ///   catalog there;
        /// - sandboxed without the group (a build signed without it): the
        ///   process's own container, which is what `NSHomeDirectory()`
        ///   returns inside a sandbox.
        ///
        /// Never a build flag, never an environment value the operator sets:
        /// `APP_SANDBOX_CONTAINER_ID` is the marker the system itself places
        /// in a sandboxed process's environment. The group identifier is read
        /// from the process's own signed entitlement, expanded by the
        /// signature with the team prefix, never composed from a constant
        /// (a composed prefix would only hold on the machine it was written on).
        public static func processHome(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            entitledGroups: [String] = signedApplicationGroups(),
            groupContainer: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        ) -> URL {
            let ownHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            guard environment["APP_SANDBOX_CONTAINER_ID"] != nil else { return ownHome }
            guard let group = entitledGroups.first(where: { $0.hasSuffix(Apple.appGroup) }),
                  let container = groupContainer(group) else { return ownHome }
            return container.standardizedFileURL
        }

        /// `applicationSupportDirectory(homeDirectory: processHome())`: the
        /// one configuration directory this process's family shares.
        public static var configurationDirectory: URL {
            applicationSupportDirectory(homeDirectory: processHome())
        }

        /// The `com.apple.security.application-groups` of this process's
        /// signed entitlements, as the signature expanded them. Empty for an
        /// unsigned or unentitled process and on platforms without Security.
        public static func signedApplicationGroups() -> [String] {
            #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil),
                  let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
                  let groups = value as? [String] else { return [] }
            return groups
            #else
            // iOS has no SecTask API; the app-group entitlement is resolved by
            // the host app, so this reader reports absent.
            return []
            #endif
        }
    }

    // MARK: Logging

    /// OSLog coordinates. One subsystem for the whole product, so one Console
    /// filter shows every kit, daemon and app surface; the category names the
    /// module, with an optional topic for a surface an operator filters on
    /// separately (sync engines, key custody, migrations).
    public enum Logging {
        /// `com.mootx01.kit`: the subsystem every `Logger` in the product uses.
        public static let subsystem = product("kit")

        /// `Module` or `Module.Topic`. The module is the Swift target's name;
        /// the topic, when given, is a CamelCase word for the surface.
        public static func category(_ module: String, topic: String? = nil) -> String {
            guard let topic, !topic.isEmpty else { return module }
            return "\(module).\(topic)"
        }
    }

    // MARK: Services

    /// Names the product registers with the operating system for its own
    /// processes and network presence.
    public enum Services {
        /// launchd label of the resident mootx01 daemon (`com.mootx01.daemon`).
        public static let daemonLabel = product("daemon")
        /// launchd label of the moot-mgr resident host (`com.mootx01.mgr`).
        public static let managerLabel = product("mgr")
        /// Owner identifier the daemon contract host files under.
        public static let contractHostOwner = product("daemon.contract-host")
        /// launchd label of the bundle-form daemon provider registration,
        /// under the vendor root because it is the signed bundle's agent.
        public static let daemonProviderLaunchAgentLabel = vendor("daemon")
        /// Bonjour service type the resident advertises (`project.yml`
        /// `NSBonjourServices`).
        public static let bonjourServiceType = "_mootx01._tcp"
        /// Bonjour service type of the federation relay.
        public static let federationBonjourServiceType = "_mootx01-fed._tcp"
        /// URL scheme the app registers (`project.yml` `CFBundleURLSchemes`).
        public static let urlScheme = "mootx01"
    }

    // MARK: Keychain

    /// Keychain coordinates. Services under the vendor root predate the
    /// product root and stay: existing items are keyed by them, and a rename
    /// would orphan every user's key.
    public enum Keychain {
        /// `kSecAttrService` of the per-estate SQLCipher key items. The
        /// account is derived from the estate file path by
        /// `KeychainKeyStore.estateAccount`.
        public static let estateKeyService = vendorRoot
        /// The shared access group the app and a separately spawned server
        /// both read; requires the matching entitlement on a signed build.
        public static let sharedAccessGroup = vendor("shared")
        /// `kSecAttrService` of the per-estate Ed25519 identity key items.
        public static let estateIdentityService = product("estate.identity")
        /// The portable LAN server's credential.
        public static let lanCredentialService = vendor("lan-credential")
        /// The first-party daemon authentication secret.
        public static let daemonAuthService = vendor("daemon-auth")
        /// The daemon helper's custody proof item.
        public static let daemonProofService = vendor("daemon-proof")
        /// The cross-install custody proof item.
        public static let crossInstallCustodyProofService = vendor("cross-install-custody-proof")
        /// Secret-sync key handles and the protected head.
        public static let secretSyncSigningHandleService = vendor("secret-sync.signing-handle")
        public static let secretSyncAgreementHandleService = vendor("secret-sync.agreement-handle")
        public static let secretSyncProtectedHeadService = vendor("secret-sync.protected-head")
        /// The sync tier authorisation items: one service per tier, in the
        /// vendor-root access group the app alone reads.
        public static func syncTierService(_ tier: String) -> String { vendor("sync-tier.\(tier)") }
        public static let syncTierAccessGroup = vendorRoot
        /// The estate-surgery clone recipient key.
        public static let estateSurgeryCloneRecipientService = vendor("estate-surgery.clone-recipient")
    }

    // MARK: Apple

    /// Identifiers Apple registers for the signed products. Mirrors of
    /// `project.yml` and the entitlements, pinned by the fixture.
    public enum Apple {
        /// The app group every process family shares (`group.<vendorRoot>`).
        public static let appGroup = "group.\(vendorRoot)"
        /// Spotlight domain for indexed memories.
        public static let spotlightDomain = vendor("memory")
        /// BGTaskScheduler identifier of the mining refresh.
        public static let miningRefreshTaskIdentifier = vendor("mining.refresh")
        /// NSError domain of the share extension.
        public static let shareErrorDomain = vendor("share")

        public enum BundleIdentifiers {
            public static let macOSApp = vendor("macos")
            public static let iOSApp = vendor("ios")
            public static let communityMacOSApp = vendor("community.macos")
            public static let daemonProvider = vendor("macos.daemonprovider")
            public static let daemonHelper = vendor("macos.daemonhelper")
            public static let daemonProofHost = vendor("macos.daemonproofhost")
            public static let custodyProofSandboxHelper = vendor("macos.custodyproof.sandboxhelper")
            public static let custodyProofDeveloperIDDaemon = vendor("macos.custodyproof.developeriddaemon")
        }
    }

    // MARK: Preferences

    /// UserDefaults keys, all under the product root.
    public enum Preferences {
        public static let residency = product("residency")
        public static let gatewayHasCompletedOnboarding = product("gateway.hasCompletedOnboarding")
        public static let gatewayIsAdvancedMode = product("gateway.isAdvancedMode")
        public static let gatewayShowQuickCapture = product("gateway.showQuickCapture")
        public static let portableOnPowerOnly = product("portable.onPowerOnly")
        public static let portableServiceName = product("portable.serviceName")
    }

    // MARK: Queues

    /// Thread and dispatch queue labels, all under the product root. Visible
    /// only in a debugger or a crash report.
    public enum Queues {
        public static let ariaHTTPAccept = product("aria-mcp.http.accept")
        /// Stable name for the raw-read thread in the HTTP transport. Used by the
        /// test gate to assert the read is NOT running on the shared pool.
        public static let ariaHTTPRawRead = product("aria-mcp.raw-read")
        public static let managerControlChannelAccept = product("mgr.control-channel.accept")
        public static let managerHTTPReadAPIAccept = product("mgr.http-read-api.accept")
        public static let lanDiscovery = product("lan-discovery")
        public static let lanBrowser = product("lan-browser")
    }

    // MARK: Settings

    /// Product settings read from `config.json` at the root of the configuration
    /// directory. This file is written by `mootx01 install` with default values
    /// when the file is absent, and left untouched by `mootx01 upgrade`. All
    /// consumers read through this type so a single edit to `config.json` is
    /// reflected by every component.
    ///
    /// JSON shape (all keys are optional; unknown keys are silently ignored):
    /// ```json
    /// {
    ///   "daemon": { "stats_store": "<absolute-path>" },
    ///   "fact_extraction": {
    ///     "coreai_asset":     "<absolute path to a .aimodel directory>",
    ///     "coreai_tokenizer": "<absolute path to a tokenizer file>",
    ///     "model_version":    "<string>"
    ///   }
    /// }
    /// ```
    /// `coreai_asset` and `coreai_tokenizer` point to CoreAI NuExtract model
    /// files on the host. `model_version` is a free-form version string baked
    /// into the extractor's recipe ID so changing the model clears extraction
    /// debt estate-wide. All three resolve to `nil` when absent or empty.
    /// The three Rust-only keys (`gguf`, `tokenizer`, `worker_executable`)
    /// that share the same `fact_extraction` object are silently ignored here.
    public struct Settings: Sendable {

        /// The name of the settings file inside the configuration directory.
        static let fileName = "config.json"

        /// JSON key path for the daemon stats-store setting, as a display string.
        /// The actual parsing reads `json["daemon"]["stats_store"]`.
        static let daemonStatsStoreKeyPath = "daemon.stats_store"

        // MARK: Resolved values

        /// Override path for the daemon stats store (`daemon.stats_store`).
        /// `nil` means the key was absent — the consumer should fall back to
        /// the platform-default path (`<config-dir>/moot-mgr/stats.sqlite`).
        /// An empty string in the file is treated the same as absent.
        public let daemonStatsStore: String?

        // MARK: Fact-extraction resolved values (Swift / Apple port only)

        /// Absolute path to the CoreAI NuExtract `.aimodel` directory
        /// (`fact_extraction.coreai_asset`). `nil` when the key is absent or empty.
        public let factExtractionCoreAIAsset: String?

        /// Absolute path to the CoreAI NuExtract tokenizer file
        /// (`fact_extraction.coreai_tokenizer`). `nil` when the key is absent or empty.
        public let factExtractionCoreAITokenizer: String?

        /// Model-version string baked into the recipe ID
        /// (`fact_extraction.model_version`). `nil` when the key is absent or empty.
        /// Changing this value clears bit-28 extraction debt estate-wide on the
        /// next activation (a recipe-ID change triggers the LocusKit registry
        /// transaction that resets the debt).
        public let factExtractionModelVersion: String?

        /// `recall_distillation.max_source_bytes`: UTF-8 admission limit (default
        /// 32768). Larger bodies are returned intact. Config can lower, not raise,
        /// the safety ceiling; nonpositive integers clamp to 1, invalid values default.
        public let recallDistillationMaxSourceBytes: Int

        // MARK: Duty limits (`duties` object; GeniusLocusKit § DUTY_LIFECYCLE)

        /// `duties.fact_extraction_batch`: sources per fact-extraction batch (default 16).
        public let dutyFactExtractionBatch: Int
        /// `duties.subject_backfill_batch`: rows per subject sweep (default 256).
        public let dutySubjectBackfillBatch: Int
        /// `duties.fact_source_lease_seconds`: the per-source in-flight fence while a
        /// model call runs (default 120; it must exceed the extractor's request timeout).
        public let dutyFactSourceLeaseSeconds: Int
        /// `duties.fact_extraction_cadence_seconds`: the resident's Signal 14 period (default 300).
        public let dutyFactExtractionCadenceSeconds: Int

        /// Maximum expanded reference output bytes (`context_distill.reference_expansion_max_bytes`).
        public let contextDistillReferenceExpansionMaxBytes: Int
        /// Maximum output/input UTF-8 expansion ratio (`context_distill.reference_expansion_max_ratio`).
        public let contextDistillReferenceExpansionMaxRatio: Int

        // MARK: Loading

        /// Load settings from `config.json` in the given configuration directory.
        ///
        /// Missing file, unreadable file, or absent keys all produce `nil` for
        /// the corresponding property — never a fatal error. Unknown keys in the
        /// file are silently ignored.
        ///
        /// - Parameter configurationDirectory: The directory that contains
        ///   `config.json`. Defaults to `Storage.configurationDirectory`, the
        ///   one shared by all components in this product family.
        /// - Returns: A `Settings` value with whatever keys were found.
        public static func load(
            configurationDirectory: URL = Storage.configurationDirectory
        ) -> Settings {
            let url = configurationDirectory.appendingPathComponent(fileName)
            guard
                let data = try? Data(contentsOf: url),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return Settings(
                    daemonStatsStore: nil,
                    factExtractionCoreAIAsset: nil,
                    factExtractionCoreAITokenizer: nil,
                    factExtractionModelVersion: nil)
            }
            let daemon = root["daemon"] as? [String: Any]
            let statsStore = daemon?["stats_store"] as? String
            // Treat an empty string the same as absent — a manually-cleared
            // value should not produce an empty path string downstream.
            let storeOrNil = statsStore.flatMap { $0.isEmpty ? nil : $0 }
            // Parse fact_extraction sub-object. Rust-only keys (gguf, tokenizer,
            // worker_executable) live here too; this parser reads only the three
            // Swift-side keys and ignores the rest.
            let factExtraction = root["fact_extraction"] as? [String: Any]
            let coreaiAsset = (factExtraction?["coreai_asset"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let coreaiTokenizer = (factExtraction?["coreai_tokenizer"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let modelVersion = (factExtraction?["model_version"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let distill = root["context_distill"] as? [String: Any]
            // `duties` — batch limits and the fact source lease (§ DUTY_LIFECYCLE).
            // A non-positive or malformed value keeps the default.
            let duties = root["duties"] as? [String: Any]
            return Settings(
                daemonStatsStore: storeOrNil,
                factExtractionCoreAIAsset: coreaiAsset,
                factExtractionCoreAITokenizer: coreaiTokenizer,
                factExtractionModelVersion: modelVersion,
                contextDistillReferenceExpansionMaxBytes: positiveIntegerOrDefault(distill?["reference_expansion_max_bytes"], fallback: 8_388_608),
                contextDistillReferenceExpansionMaxRatio: positiveIntegerOrDefault(distill?["reference_expansion_max_ratio"], fallback: 64),
                recallDistillationMaxSourceBytes: min(32768, positiveInteger(
                    (root["recall_distillation"] as? [String: Any])?["max_source_bytes"], fallback: 32768)),
                dutyFactExtractionBatch: positiveIntegerOrDefault(duties?["fact_extraction_batch"], fallback: 16),
                dutySubjectBackfillBatch: positiveIntegerOrDefault(duties?["subject_backfill_batch"], fallback: 256),
                dutyFactSourceLeaseSeconds: positiveIntegerOrDefault(duties?["fact_source_lease_seconds"], fallback: 120),
                dutyFactExtractionCadenceSeconds: positiveIntegerOrDefault(duties?["fact_extraction_cadence_seconds"], fallback: 300))
        }

        // MARK: Writing

        /// Write the default `config.json` into the configuration directory,
        /// but only when the key is not already set. Idempotent: a second call
        /// with the same or a user-chosen value leaves the file untouched.
        ///
        /// This is called by `mootx01 install` to seed the file with the
        /// computed default so operators can discover and edit it. It is never
        /// called by `mootx01 upgrade`.
        ///
        /// - Parameters:
        ///   - defaultStatsStorePath: The path to write when the key is absent.
        ///   - configurationDirectory: Target directory (defaults to `Storage.configurationDirectory`).
        /// - Returns: `true` when the file was written or already contained the
        ///   key; `false` when the write failed.
        @discardableResult
        public static func seedDefaultsIfAbsent(
            defaultStatsStorePath: String,
            configurationDirectory: URL = Storage.configurationDirectory
        ) -> Bool {
            let url = configurationDirectory.appendingPathComponent(fileName)
            // Load existing settings — if the key is already present (any non-nil
            // value), this call is a no-op.
            let existing = load(configurationDirectory: configurationDirectory)
            if existing.daemonStatsStore != nil {
                return true
            }
            // Build the minimal JSON object and write it.
            // Round-trip through JSONSerialization so existing keys are preserved
            // when the file already exists but lacks only this key.
            var root: [String: Any]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            } else {
                root = [:]
            }
            var daemon = root["daemon"] as? [String: Any] ?? [:]
            daemon["stats_store"] = defaultStatsStorePath
            root["daemon"] = daemon
            guard
                let written = try? JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys]
                )
            else { return false }
            // Ensure the parent directory exists before writing.
            let fm = FileManager.default
            try? fm.createDirectory(
                at: configurationDirectory, withIntermediateDirectories: true
            )
            return fm.createFile(atPath: url.path, contents: written)
        }

        // Reject JSON booleans, fractional values, and out-of-range integers in
        // both ports. Nonpositive integer settings clamp to one.
        private static func positiveInteger(_ value: Any?, fallback: Int) -> Int {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = Int(number.stringValue) else { return fallback }
            return max(1, integer)
        }

        private static func positiveIntegerOrDefault(_ value: Any?, fallback: Int) -> Int {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = Int(number.stringValue), integer > 0 else { return fallback }
            return integer
        }

        // MARK: Private init

        private init(
            daemonStatsStore: String?,
            factExtractionCoreAIAsset: String?,
            factExtractionCoreAITokenizer: String?,
            factExtractionModelVersion: String?,
            contextDistillReferenceExpansionMaxBytes: Int = 8_388_608,
            contextDistillReferenceExpansionMaxRatio: Int = 64,
            recallDistillationMaxSourceBytes: Int = 32768,
            dutyFactExtractionBatch: Int = 16,
            dutySubjectBackfillBatch: Int = 256,
            dutyFactSourceLeaseSeconds: Int = 120,
            dutyFactExtractionCadenceSeconds: Int = 300
        ) {
            self.daemonStatsStore = daemonStatsStore
            self.factExtractionCoreAIAsset = factExtractionCoreAIAsset
            self.factExtractionCoreAITokenizer = factExtractionCoreAITokenizer
            self.factExtractionModelVersion = factExtractionModelVersion
            self.contextDistillReferenceExpansionMaxBytes = contextDistillReferenceExpansionMaxBytes
            self.contextDistillReferenceExpansionMaxRatio = contextDistillReferenceExpansionMaxRatio
            self.recallDistillationMaxSourceBytes = recallDistillationMaxSourceBytes
            self.dutyFactExtractionBatch = dutyFactExtractionBatch
            self.dutySubjectBackfillBatch = dutySubjectBackfillBatch
            self.dutyFactSourceLeaseSeconds = dutyFactSourceLeaseSeconds
            self.dutyFactExtractionCadenceSeconds = dutyFactExtractionCadenceSeconds
        }
    }
}
