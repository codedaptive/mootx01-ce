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
// `tests/fixture_parity.rs` refuses any drift between this file and the
// fixture. Change a value in the fixture and in both ports together.
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
    /// is named.
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
    pub const MANAGER_CONTROL_CHANNEL_ACCEPT: &str = "com.mootx01.mgr.control-channel.accept";
    pub const MANAGER_HTTP_READ_API_ACCEPT: &str = "com.mootx01.mgr.http-read-api.accept";
    pub const LAN_DISCOVERY: &str = "com.mootx01.lan-discovery";
    pub const LAN_BROWSER: &str = "com.mootx01.lan-browser";
}
