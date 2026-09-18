// lib.rs — MootProductIdentity, Rust port.
//
// Every identity string the product uses, spelled once. Two roots:
//
// - `PRODUCT_ROOT` (`com.mootx01`): what the product names for itself. The
//   configuration folder, the logging subsystem, launchd and service labels,
//   its own Keychain items, preference keys, queue labels.
// - `VENDOR_ROOT` (`com.codedaptive.mootx01`): what Apple ties to the signing
//   identity. Bundle identifiers, the app group, the shared access group, the
//   Spotlight domain, background tasks, and the Keychain services existing
//   items are already keyed by.
//
// The Swift library at `Sources/MootProductIdentity/MootProductIdentity.swift`
// is the reference; `Fixtures/product_identity.json` pins every value, and
// `tests/fixture_parity.rs` refuses any drift between the constants it lists
// and the fixture, in both directions. Every `pub const` in this file is in
// that list, including `storage::UNIX_DATA_FOLDER`, which only this port
// uses. Change a value in the fixture and in both ports together.
//
// The Rust port targets Linux and Windows (macOS only for developer runs), so
// the Apple and Keychain namespaces are carried as strings for parity and
// for the surfaces that print or compare them; nothing here calls a platform
// API.

#![deny(rust_2018_idioms)]
#![deny(unused_must_use)]

use std::path::PathBuf;

/// What the product names for itself.
pub const PRODUCT_ROOT: &str = "com.mootx01";
/// What Apple ties to the signing identity.
pub const VENDOR_ROOT: &str = "com.codedaptive.mootx01";

/// On-disk names: the configuration folder, the catalog file and the estate
/// layout names the daemon provider's census and the estate catalog share.
pub mod storage {
    use super::*;

    /// The product folder the Swift product uses under Application Support
    /// and the Rust product uses under `%LOCALAPPDATA%` on Windows.
    pub const APPLICATION_SUPPORT_FOLDER: &str = "com.mootx01.ce";
    /// The folder under `${XDG_DATA_HOME:-~/.local/share}` on every Unix
    /// target (Linux in production; macOS developer runs follow the same
    /// convention): the program name, as every program under `.local/share`
    /// is named. Pinned by the fixture (`storage.unixDataFolder`) and carried
    /// by the Swift library for parity even though the Swift product never
    /// uses it: it decides which catalog a Linux install opens.
    pub const UNIX_DATA_FOLDER: &str = "mootx01";
    /// The lattice cache folder beside the product folder.
    pub const LATTICE_FOLDER: &str = "com.mootx01.lattice";

    /// The catalog file inside the configuration directory.
    pub const CATALOG_FILE: &str = "estatecatalog.json";
    /// The folder under the configuration directory that is the default
    /// database location on first run.
    pub const DATABASES_FOLDER: &str = "databases";
    /// The primary estate's name.
    pub const DEFAULT_ESTATE_NAME: &str = "default";
    /// The estate database file inside an estate directory.
    pub const ESTATE_DATABASE_FILE: &str = "estate.sqlite";

    /// The community daemon's sidecar directory name, beside `estatecatalog.json`
    /// in the configuration directory.
    pub const COMMUNITY_DAEMON_FOLDER: &str = "community-daemon";

    /// The process home: `HOME` on Unix, `USERPROFILE` on Windows. The Rust
    /// port never runs sandboxed, so the family home is always the user's.
    pub fn process_home() -> PathBuf {
        #[cfg(target_os = "windows")]
        let value = std::env::var("USERPROFILE");
        #[cfg(not(target_os = "windows"))]
        let value = std::env::var("HOME");
        value.map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
    }

    /// The configuration directory: where `estatecatalog.json` lives, fixed
    /// for the life of the install and never passed, stored or moved.
    ///
    /// - Unix (Linux in production, macOS developer runs alike):
    ///   `${XDG_DATA_HOME:-<home>/.local/share}/mootx01`
    /// - Windows: `%LOCALAPPDATA%\com.mootx01.ce` (`<home>\AppData\Local`
    ///   when `LOCALAPPDATA` is unset)
    ///
    /// The Rust product never shares a directory with the Swift product.
    ///
    /// Only the platform base directory variables are read; no product
    /// environment value selects the directory.
    pub fn configuration_directory() -> PathBuf {
        configuration_directory_from(process_home(), |name| {
            std::env::var(name).ok().filter(|value| !value.is_empty())
        })
    }

    /// The directory rule with its inputs passed in, for tests.
    /// `platform_variable` answers `XDG_DATA_HOME` or `LOCALAPPDATA`.
    pub fn configuration_directory_from(
        home: PathBuf,
        platform_variable: impl Fn(&str) -> Option<String>,
    ) -> PathBuf {
        #[cfg(target_os = "windows")]
        {
            let base = platform_variable("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Local"));
            base.join(APPLICATION_SUPPORT_FOLDER)
        }
        #[cfg(not(target_os = "windows"))]
        {
            let base = platform_variable("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local").join("share"));
            base.join(UNIX_DATA_FOLDER)
        }
    }
}

/// Logging identity.
pub mod logging {
    /// The one subsystem every kit logs under.
    pub const SUBSYSTEM: &str = "com.mootx01.kit";

    /// The category for a module, optionally narrowed to a topic:
    /// `Module` or `Module.Topic`. Twin of Swift `Logging.category(_:topic:)`.
    pub fn category(module: &str, topic: Option<&str>) -> String {
        match topic {
            Some(topic) => format!("{module}.{topic}"),
            None => module.to_string(),
        }
    }
}

/// Service and label names.
pub mod services {
    pub const DAEMON_LABEL: &str = "com.mootx01.daemon";
    pub const MANAGER_LABEL: &str = "com.mootx01.mgr";
    pub const CONTRACT_HOST_OWNER: &str = "com.mootx01.daemon.contract-host";
    pub const DAEMON_PROVIDER_LAUNCH_AGENT_LABEL: &str = "com.codedaptive.mootx01.daemon";
    pub const BONJOUR_SERVICE_TYPE: &str = "_mootx01._tcp";
    pub const FEDERATION_BONJOUR_SERVICE_TYPE: &str = "_mootx01-fed._tcp";
    pub const URL_SCHEME: &str = "mootx01";
}

/// Keychain service and access-group names. The Rust port has no Keychain;
/// these are carried so both ports print and compare the same strings.
pub mod keychain {
    pub const ESTATE_KEY_SERVICE: &str = "com.codedaptive.mootx01";
    pub const SHARED_ACCESS_GROUP: &str = "com.codedaptive.mootx01.shared";
    pub const ESTATE_IDENTITY_SERVICE: &str = "com.mootx01.estate.identity";
    pub const LAN_CREDENTIAL_SERVICE: &str = "com.codedaptive.mootx01.lan-credential";
    pub const DAEMON_AUTH_SERVICE: &str = "com.codedaptive.mootx01.daemon-auth";
    pub const DAEMON_PROOF_SERVICE: &str = "com.codedaptive.mootx01.daemon-proof";
    pub const CROSS_INSTALL_CUSTODY_PROOF_SERVICE: &str =
        "com.codedaptive.mootx01.cross-install-custody-proof";
    pub const SECRET_SYNC_SIGNING_HANDLE_SERVICE: &str =
        "com.codedaptive.mootx01.secret-sync.signing-handle";
    pub const SECRET_SYNC_AGREEMENT_HANDLE_SERVICE: &str =
        "com.codedaptive.mootx01.secret-sync.agreement-handle";
    pub const SECRET_SYNC_PROTECTED_HEAD_SERVICE: &str =
        "com.codedaptive.mootx01.secret-sync.protected-head";
    pub const SYNC_TIER_SERVICE_PREFIX: &str = "com.codedaptive.mootx01.sync-tier.";
    pub const SYNC_TIER_ACCESS_GROUP: &str = "com.codedaptive.mootx01";
    pub const ESTATE_SURGERY_CLONE_RECIPIENT_SERVICE: &str =
        "com.codedaptive.mootx01.estate-surgery.clone-recipient";

    /// The service for one sync tier: the prefix plus the tier's raw value.
    /// Twin of Swift `Keychain.syncTierService(_:)`.
    pub fn sync_tier_service(tier: &str) -> String {
        format!("{SYNC_TIER_SERVICE_PREFIX}{tier}")
    }
}

/// Identifiers Apple ties to the signing identity.
pub mod apple {
    pub const APP_GROUP: &str = "group.com.codedaptive.mootx01";
    pub const SPOTLIGHT_DOMAIN: &str = "com.codedaptive.mootx01.memory";
    pub const MINING_REFRESH_TASK_IDENTIFIER: &str = "com.codedaptive.mootx01.mining.refresh";
    pub const SHARE_ERROR_DOMAIN: &str = "com.codedaptive.mootx01.share";

    pub mod bundle_identifiers {
        pub const MACOS_APP: &str = "com.codedaptive.mootx01.macos";
        pub const IOS_APP: &str = "com.codedaptive.mootx01.ios";
        pub const COMMUNITY_MACOS_APP: &str = "com.codedaptive.mootx01.community.macos";
        pub const DAEMON_PROVIDER: &str = "com.codedaptive.mootx01.macos.daemonprovider";
        pub const DAEMON_HELPER: &str = "com.codedaptive.mootx01.macos.daemonhelper";
        pub const DAEMON_PROOF_HOST: &str = "com.codedaptive.mootx01.macos.daemonproofhost";
        pub const CUSTODY_PROOF_SANDBOX_HELPER: &str =
            "com.codedaptive.mootx01.macos.custodyproof.sandboxhelper";
        pub const CUSTODY_PROOF_DEVELOPER_ID_DAEMON: &str =
            "com.codedaptive.mootx01.macos.custodyproof.developeriddaemon";
    }
}

/// Preference keys.
pub mod preferences {
    pub const RESIDENCY: &str = "com.mootx01.residency";
    pub const GATEWAY_HAS_COMPLETED_ONBOARDING: &str = "com.mootx01.gateway.hasCompletedOnboarding";
    pub const GATEWAY_IS_ADVANCED_MODE: &str = "com.mootx01.gateway.isAdvancedMode";
    pub const GATEWAY_SHOW_QUICK_CAPTURE: &str = "com.mootx01.gateway.showQuickCapture";
    pub const PORTABLE_ON_POWER_ONLY: &str = "com.mootx01.portable.onPowerOnly";
    pub const PORTABLE_SERVICE_NAME: &str = "com.mootx01.portable.serviceName";
}

/// Dispatch queue labels.
pub mod queues {
    pub const ARIA_HTTP_ACCEPT: &str = "com.mootx01.aria-mcp.http.accept";
    /// Stable name for the raw-read thread in the Swift HTTP transport; mirrored
    /// here so the fixture parity gate holds. The Rust port has no such thread.
    pub const ARIA_HTTP_RAW_READ: &str = "com.mootx01.aria-mcp.raw-read";
    pub const MANAGER_CONTROL_CHANNEL_ACCEPT: &str = "com.mootx01.mgr.control-channel.accept";
    pub const MANAGER_HTTP_READ_API_ACCEPT: &str = "com.mootx01.mgr.http-read-api.accept";
    pub const LAN_DISCOVERY: &str = "com.mootx01.lan-discovery";
    pub const LAN_BROWSER: &str = "com.mootx01.lan-browser";
}

/// Product settings read from `config.json` at the root of the configuration
/// directory. Twin of Swift `MootProductIdentity.Settings`.
///
/// JSON shape: `{"daemon": {"stats_store": "<absolute-path>"}}`. Additional
/// keys are ignored.  All consumers load through this module so a single edit
/// to `config.json` is reflected by every component.
pub mod settings {
    use std::path::Path;

    /// Name of the settings file inside the configuration directory.
    const FILE_NAME: &str = "config.json";

    /// Parsed product settings. `None` fields mean the key was absent in the
    /// file — the consumer falls back to its computed default.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct ProductSettings {
        /// Override path for the daemon stats store (`daemon.stats_store`).
        /// `None` means absent in the file; the consumer should use
        /// `<config-dir>/moot-mgr/stats.sqlite` as the default.
        pub daemon_stats_store: Option<String>,

        // ---- fact_extraction block (config.json top-level key) ----
        // Four Rust-port paths from `fact_extraction.*`. The two Swift-only
        // keys (`coreai_asset`, `coreai_tokenizer`) are parsed by the Swift
        // port and ignored here. An absent or empty value produces `None` —
        // the same fail-quiet contract as `daemon_stats_store`.

        /// Absolute path to the `moot-nuextract-worker` binary
        /// (`fact_extraction.worker_executable` in config.json).
        pub fact_extraction_worker_executable: Option<String>,
        /// Absolute path to the GGUF model file
        /// (`fact_extraction.gguf` in config.json).
        pub fact_extraction_gguf: Option<String>,
        /// Absolute path to the tokenizer file
        /// (`fact_extraction.tokenizer` in config.json).
        pub fact_extraction_tokenizer: Option<String>,
        /// Model version string used to derive the activation recipe ID so
        /// switching models automatically clears extraction debt estate-wide
        /// (`fact_extraction.model_version` in config.json).
        pub fact_extraction_model_version: Option<String>,
        /// Maximum expanded reference output bytes.
        pub context_distill_reference_expansion_max_bytes: usize,
        /// Maximum reference output/input UTF-8 byte ratio.
        pub context_distill_reference_expansion_max_ratio: usize,
        /// `recall_distillation.max_source_bytes`: UTF-8 admission budget,
        /// default/ceiling 32768. Config may lower it; oversized bodies stay intact.
        pub recall_distillation_max_source_bytes: usize,

        // ---- duties block (GeniusLocusKit § DUTY_LIFECYCLE) ----
        /// `duties.fact_extraction_batch`: sources per fact-extraction batch (default 16).
        pub duty_fact_extraction_batch: usize,
        /// `duties.subject_backfill_batch`: rows per subject sweep (default 32: one batch of ~10 s Apple calls fits the cadence).
        pub duty_subject_backfill_batch: usize,
        /// `duties.fact_source_lease_seconds`: per-source in-flight fence while a
        /// model call runs (default 120; must exceed the extractor's request timeout).
        pub duty_fact_source_lease_seconds: u64,
        /// `duties.fact_extraction_cadence_seconds`: the resident's Signal 14 period (default 300).
        pub duty_fact_extraction_cadence_seconds: u64,
        /// `duties.anomaly_sweep_chests`: containers scored per anomaly-sweep batch (default 8).
        pub duty_anomaly_sweep_chests: usize,
        /// `duties.chest_rebin_batch`: rooms re-binned per chest-rebin batch (default 1).
        pub duty_chest_rebin_batch: usize,
    }

    /// A missing or unreadable config file yields the same values as `{}`:
    /// absent optional keys and the 32768-byte recall admission ceiling. A
    /// derived `Default` would set the ceiling to zero and disable distillation.
    impl Default for ProductSettings {
        fn default() -> Self {
            Self {
                daemon_stats_store: None,
                fact_extraction_worker_executable: None,
                fact_extraction_gguf: None,
                fact_extraction_tokenizer: None,
                fact_extraction_model_version: None,
                context_distill_reference_expansion_max_bytes: 8_388_608,
                context_distill_reference_expansion_max_ratio: 64,
                recall_distillation_max_source_bytes: 32768,
                duty_fact_extraction_batch: 16,
                duty_subject_backfill_batch: 32,
                duty_fact_source_lease_seconds: 120,
                duty_fact_extraction_cadence_seconds: 300,
                duty_anomaly_sweep_chests: 8,
                duty_chest_rebin_batch: 1,
            }
        }
    }

    /// Load settings from `<config_dir>/config.json`.
    ///
    /// A missing file, unreadable file, or absent keys all produce `None` for
    /// the corresponding field — never a fatal error. Unknown JSON keys are
    /// silently ignored. Twin of Swift `Settings.load(configurationDirectory:)`.
    pub fn load(config_dir: &Path) -> ProductSettings {
        load_from_file(config_dir, FILE_NAME)
    }

    /// Internal loader with the file name as a parameter (for unit tests in this crate).
    pub(crate) fn load_from_file(config_dir: &Path, file_name: &str) -> ProductSettings {
        let path = config_dir.join(file_name);
        let data = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(_) => return ProductSettings::default(),
        };
        parse_settings(&data)
    }

    /// Parse the settings JSON string. Separated so unit tests in this crate can drive it directly.
    pub(crate) fn parse_settings(json: &str) -> ProductSettings {
        let root: serde_json::Value = match serde_json::from_str(json) {
            Ok(v) => v,
            Err(_) => return ProductSettings::default(),
        };
        let daemon_stats_store = root
            .get("daemon")
            .and_then(|d| d.get("stats_store"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        // `fact_extraction.*` — four Rust-port paths. `coreai_asset` and
        // `coreai_tokenizer` are Swift-only and silently ignored here.
        let fe = root.get("fact_extraction");
        let fact_extraction_worker_executable = fe
            .and_then(|fe| fe.get("worker_executable"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let fact_extraction_gguf = fe
            .and_then(|fe| fe.get("gguf"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let fact_extraction_tokenizer = fe
            .and_then(|fe| fe.get("tokenizer"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let fact_extraction_model_version = fe
            .and_then(|fe| fe.get("model_version"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        // `duties.*` — batch limits and the fact source lease. A non-positive
        // or malformed value keeps the default.
        let duties = root.get("duties");
        let duty_positive = |key: &str, fallback: u64| -> u64 {
            duties.and_then(|v| v.get(key)).and_then(|v| v.as_i64())
                .filter(|v| *v > 0).map(|v| v as u64).unwrap_or(fallback)
        };
        let distill = root.get("context_distill");
        let distill_positive = |key: &str, fallback: usize| -> usize {
            distill.and_then(|v| v.get(key)).and_then(|v| v.as_i64())
                .filter(|v| *v > 0).map(|v| v as usize).unwrap_or(fallback)
        };
        ProductSettings {
            context_distill_reference_expansion_max_bytes: distill_positive("reference_expansion_max_bytes", 8_388_608),
            context_distill_reference_expansion_max_ratio: distill_positive("reference_expansion_max_ratio", 64),
            recall_distillation_max_source_bytes: root.get("recall_distillation")
                .and_then(|v| v.get("max_source_bytes")).and_then(|v| v.as_i64())
                .map(|v| v.clamp(1, 32768) as usize).unwrap_or(32768),
            daemon_stats_store,
            fact_extraction_worker_executable,
            fact_extraction_gguf,
            fact_extraction_tokenizer,
            fact_extraction_model_version,
            duty_fact_extraction_batch: duty_positive("fact_extraction_batch", 16) as usize,
            duty_subject_backfill_batch: duty_positive("subject_backfill_batch", 32) as usize,
            duty_fact_source_lease_seconds: duty_positive("fact_source_lease_seconds", 120),
            duty_fact_extraction_cadence_seconds: duty_positive("fact_extraction_cadence_seconds", 300),
            duty_anomaly_sweep_chests: duty_positive("anomaly_sweep_chests", 8) as usize,
            duty_chest_rebin_batch: duty_positive("chest_rebin_batch", 1) as usize,
        }
    }

    #[test]
    fn missing_config_file_keeps_recall_ceiling() {
        let dir = std::env::temp_dir().join(format!("mpi-missing-{}", std::process::id()));
        assert_eq!(load_from_file(&dir, FILE_NAME).recall_distillation_max_source_bytes, 32768);
    }

    #[test]
    fn recall_budget_cannot_disable_safety_ceiling() {
        assert_eq!(parse_settings("{}").recall_distillation_max_source_bytes, 32768);
        for (value, expected) in [("1024", 1024), ("0", 1), ("-1", 1), ("999999", 32768), ("true", 32768), ("1.5", 32768), ("\"64\"", 32768)] {
            let json = format!("{{\"recall_distillation\":{{\"max_source_bytes\":{value}}}}}");
            assert_eq!(parse_settings(&json).recall_distillation_max_source_bytes, expected);
        }
    }

    /// Write the default `config.json` when the `daemon.stats_store` key is
    /// absent. Idempotent: a second call with the same or a user-chosen value
    /// leaves the file untouched. Twin of Swift
    /// `Settings.seedDefaultsIfAbsent(defaultStatsStorePath:configurationDirectory:)`.
    ///
    /// Called by `mootx01 install`; never called by `mootx01 upgrade`.
    ///
    /// Returns `Ok(true)` when the key was already present (no-op),
    /// `Ok(false)` when the file was written, and `Err` when the write failed.
    pub fn seed_defaults_if_absent(
        config_dir: &Path,
        default_stats_store_path: &str,
    ) -> std::io::Result<bool> {
        let path = config_dir.join(FILE_NAME);
        // Read the existing file if any.
        let mut root: serde_json::Map<String, serde_json::Value> = if path.exists() {
            let text = std::fs::read_to_string(&path)?;
            match serde_json::from_str(&text) {
                Ok(serde_json::Value::Object(map)) => map,
                _ => serde_json::Map::new(),
            }
        } else {
            serde_json::Map::new()
        };
        // If the key is already present (non-empty), leave the file untouched.
        let existing = root
            .get("daemon")
            .and_then(|d| d.get("stats_store"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty());
        if existing.is_some() {
            return Ok(true);
        }
        // Set the key and write the file.
        let daemon = root
            .entry("daemon")
            .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()));
        if let serde_json::Value::Object(ref mut d) = daemon {
            d.insert(
                "stats_store".to_owned(),
                serde_json::Value::String(default_stats_store_path.to_owned()),
            );
        }
        // Ensure the parent directory exists.
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(&serde_json::Value::Object(root))
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(&path, text.as_bytes())?;
        Ok(false)
    }
    #[cfg(test)]
    mod tests {
        use super::*;


        // Unit tests for pub(crate) helpers — these are the only callers that can
        // reach them, since the integration tests in tests/ are a separate crate.

        #[test]
        fn parse_settings_extracts_daemon_stats_store() {
            let json = r#"{"daemon":{"stats_store":"/tmp/test.sqlite"}}"#;
            let s = parse_settings(json);
            assert_eq!(s.daemon_stats_store.as_deref(), Some("/tmp/test.sqlite"));
        }

        #[test]
        fn parse_settings_absent_key_returns_none() {
            let json = r#"{"daemon":{}}"#;
            let s = parse_settings(json);
            assert!(s.daemon_stats_store.is_none());
        }

        #[test]
        fn parse_settings_empty_string_is_absent() {
            let json = r#"{"daemon":{"stats_store":""}}"#;
            let s = parse_settings(json);
            assert!(s.daemon_stats_store.is_none());
        }

        #[test]
        fn load_from_file_missing_file_returns_default() {
            let dir = std::env::temp_dir().join("mpi-unit-test-missing");
            std::fs::create_dir_all(&dir).ok();
            let s = load_from_file(&dir, "no_such_file.json");
            assert!(s.daemon_stats_store.is_none());
        }

        // ---- fact_extraction block tests ----

        /// All four Rust-port paths present and non-empty — all four fields populated.
        #[test]
        fn parse_settings_fact_extraction_all_present() {
            let json = r#"{
                "fact_extraction": {
                    "coreai_asset": "/swift-only.aimodel",
                    "coreai_tokenizer": "/swift-only-tok",
                    "worker_executable": "/usr/local/bin/moot-nuextract-worker",
                    "gguf": "/models/nuextract.gguf",
                    "tokenizer": "/models/tokenizer.json",
                    "model_version": "q8-2026-09-14"
                }
            }"#;
            let s = parse_settings(json);
            assert_eq!(
                s.fact_extraction_worker_executable.as_deref(),
                Some("/usr/local/bin/moot-nuextract-worker"),
                "worker_executable must be parsed"
            );
            assert_eq!(
                s.fact_extraction_gguf.as_deref(),
                Some("/models/nuextract.gguf"),
                "gguf must be parsed"
            );
            assert_eq!(
                s.fact_extraction_tokenizer.as_deref(),
                Some("/models/tokenizer.json"),
                "tokenizer must be parsed"
            );
            assert_eq!(
                s.fact_extraction_model_version.as_deref(),
                Some("q8-2026-09-14"),
                "model_version must be parsed"
            );
            // Swift-only keys do not appear in ProductSettings.
            assert!(s.daemon_stats_store.is_none());
        }

        /// Absent `fact_extraction` block — all four fields are `None`.
        #[test]
        fn parse_settings_fact_extraction_absent_block_is_none() {
            let json = r#"{"daemon":{"stats_store":"/s"}}"#;
            let s = parse_settings(json);
            assert!(s.fact_extraction_worker_executable.is_none(), "absent block → None");
            assert!(s.fact_extraction_gguf.is_none(), "absent block → None");
            assert!(s.fact_extraction_tokenizer.is_none(), "absent block → None");
            assert!(s.fact_extraction_model_version.is_none(), "absent block → None");
        }

        /// Empty string for any path value is treated as absent (`None`),
        /// matching the fail-quiet contract of `daemon_stats_store`.
        #[test]
        fn parse_settings_fact_extraction_empty_string_is_none() {
            let json = r#"{
                "fact_extraction": {
                    "worker_executable": "",
                    "gguf": "/models/nuextract.gguf",
                    "tokenizer": "/models/tokenizer.json",
                    "model_version": "q8-2026-09-14"
                }
            }"#;
            let s = parse_settings(json);
            assert!(
                s.fact_extraction_worker_executable.is_none(),
                "empty worker_executable must be None"
            );
            // The other three are still present.
            assert!(s.fact_extraction_gguf.is_some());
            assert!(s.fact_extraction_tokenizer.is_some());
            assert!(s.fact_extraction_model_version.is_some());
        }
    }

}

/// Path helpers — pure computation over product-identity constants.
///
/// These functions produce canonical filesystem paths without calling platform
/// APIs. Every caller that previously inlined the join arithmetic should use
/// these instead so the paths are spelled once and drift is prevented.
///
/// Twin of the Swift `MootPaths` helpers in `MootInstallerCore`.
pub mod paths {
    use std::path::Path;

    /// The canonical stats-store path for the moot-mgr / daemon pair:
    /// `<config_dir>/moot-mgr/stats.sqlite`.
    ///
    /// Callers (install seeder, resident daemon, moot-mgr config) use this
    /// function instead of spelling the join independently, so both the
    /// subdirectory name and the filename are spelled exactly once.
    ///
    /// Twin of Swift `MootPaths.daemonStatsStoreDefault(dataDir:)`.
    pub fn daemon_stats_store_default(config_dir: &Path) -> String {
        config_dir
            .join("moot-mgr")
            .join("stats.sqlite")
            .to_string_lossy()
            .into_owned()
    }
}
