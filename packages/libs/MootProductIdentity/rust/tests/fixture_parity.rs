// fixture_parity.rs — every constant equals its leaf in the shared fixture.
//
// `Fixtures/product_identity.json` is the one pin both ports read. The Swift
// library's tests cover the fixture leaf by leaf; this test does the same for
// the Rust constants, and also refuses a fixture leaf this file does not know,
// so a value added on one side cannot go unmirrored.

use moot_product_identity::*;
use serde_json::Value;
use std::collections::BTreeMap;

fn fixture() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Fixtures/product_identity.json");
    let text = std::fs::read_to_string(path).expect("shared fixture beside the Swift library");
    serde_json::from_str(&text).expect("fixture is JSON")
}

/// Flatten the fixture to `a.b.c` -> string leaves.
fn leaves(value: &Value, prefix: &str, out: &mut BTreeMap<String, String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                let path = if prefix.is_empty() { key.clone() } else { format!("{prefix}.{key}") };
                leaves(child, &path, out);
            }
        }
        Value::String(s) => {
            out.insert(prefix.to_string(), s.clone());
        }
        other => panic!("fixture leaf {prefix} is not a string: {other}"),
    }
}

fn constants() -> BTreeMap<&'static str, &'static str> {
    use apple::bundle_identifiers as b;
    BTreeMap::from([
        ("productRoot", PRODUCT_ROOT),
        ("vendorRoot", VENDOR_ROOT),
        ("storage.applicationSupportFolder", storage::APPLICATION_SUPPORT_FOLDER),
        ("storage.latticeFolder", storage::LATTICE_FOLDER),
        ("storage.catalogFile", storage::CATALOG_FILE),
        ("storage.databasesFolder", storage::DATABASES_FOLDER),
        ("storage.defaultEstateName", storage::DEFAULT_ESTATE_NAME),
        ("storage.estateDatabaseFile", storage::ESTATE_DATABASE_FILE),
        ("logging.subsystem", logging::SUBSYSTEM),
        ("services.daemonLabel", services::DAEMON_LABEL),
        ("services.managerLabel", services::MANAGER_LABEL),
        ("services.contractHostOwner", services::CONTRACT_HOST_OWNER),
        ("services.daemonProviderLaunchAgentLabel", services::DAEMON_PROVIDER_LAUNCH_AGENT_LABEL),
        ("services.bonjourServiceType", services::BONJOUR_SERVICE_TYPE),
        ("services.federationBonjourServiceType", services::FEDERATION_BONJOUR_SERVICE_TYPE),
        ("services.urlScheme", services::URL_SCHEME),
        ("keychain.estateKeyService", keychain::ESTATE_KEY_SERVICE),
        ("keychain.sharedAccessGroup", keychain::SHARED_ACCESS_GROUP),
        ("keychain.estateIdentityService", keychain::ESTATE_IDENTITY_SERVICE),
        ("keychain.lanCredentialService", keychain::LAN_CREDENTIAL_SERVICE),
        ("keychain.daemonAuthService", keychain::DAEMON_AUTH_SERVICE),
        ("keychain.daemonProofService", keychain::DAEMON_PROOF_SERVICE),
        ("keychain.crossInstallCustodyProofService", keychain::CROSS_INSTALL_CUSTODY_PROOF_SERVICE),
        ("keychain.secretSyncSigningHandleService", keychain::SECRET_SYNC_SIGNING_HANDLE_SERVICE),
        ("keychain.secretSyncAgreementHandleService", keychain::SECRET_SYNC_AGREEMENT_HANDLE_SERVICE),
        ("keychain.secretSyncProtectedHeadService", keychain::SECRET_SYNC_PROTECTED_HEAD_SERVICE),
        ("keychain.syncTierServicePrefix", keychain::SYNC_TIER_SERVICE_PREFIX),
        ("keychain.syncTierAccessGroup", keychain::SYNC_TIER_ACCESS_GROUP),
        ("keychain.estateSurgeryCloneRecipientService", keychain::ESTATE_SURGERY_CLONE_RECIPIENT_SERVICE),
        ("apple.appGroup", apple::APP_GROUP),
        ("apple.spotlightDomain", apple::SPOTLIGHT_DOMAIN),
        ("apple.miningRefreshTaskIdentifier", apple::MINING_REFRESH_TASK_IDENTIFIER),
        ("apple.shareErrorDomain", apple::SHARE_ERROR_DOMAIN),
        ("apple.bundleIdentifiers.macOSApp", b::MACOS_APP),
        ("apple.bundleIdentifiers.iOSApp", b::IOS_APP),
        ("apple.bundleIdentifiers.communityMacOSApp", b::COMMUNITY_MACOS_APP),
        ("apple.bundleIdentifiers.daemonProvider", b::DAEMON_PROVIDER),
        ("apple.bundleIdentifiers.daemonHelper", b::DAEMON_HELPER),
        ("apple.bundleIdentifiers.daemonProofHost", b::DAEMON_PROOF_HOST),
        ("apple.bundleIdentifiers.custodyProofSandboxHelper", b::CUSTODY_PROOF_SANDBOX_HELPER),
        ("apple.bundleIdentifiers.custodyProofDeveloperIDDaemon", b::CUSTODY_PROOF_DEVELOPER_ID_DAEMON),
        ("preferences.residency", preferences::RESIDENCY),
        ("preferences.gatewayHasCompletedOnboarding", preferences::GATEWAY_HAS_COMPLETED_ONBOARDING),
        ("preferences.gatewayIsAdvancedMode", preferences::GATEWAY_IS_ADVANCED_MODE),
        ("preferences.gatewayShowQuickCapture", preferences::GATEWAY_SHOW_QUICK_CAPTURE),
        ("preferences.portableOnPowerOnly", preferences::PORTABLE_ON_POWER_ONLY),
        ("preferences.portableServiceName", preferences::PORTABLE_SERVICE_NAME),
        ("queues.ariaHTTPAccept", queues::ARIA_HTTP_ACCEPT),
        ("queues.managerControlChannelAccept", queues::MANAGER_CONTROL_CHANNEL_ACCEPT),
        ("queues.managerHTTPReadAPIAccept", queues::MANAGER_HTTP_READ_API_ACCEPT),
        ("queues.lanDiscovery", queues::LAN_DISCOVERY),
        ("queues.lanBrowser", queues::LAN_BROWSER),
    ])
}

#[test]
fn every_constant_matches_its_fixture_leaf_and_every_leaf_is_mirrored() {
    let mut expected = BTreeMap::new();
    leaves(&fixture(), "", &mut expected);
    let actual = constants();
    for (path, value) in &expected {
        let mirrored = actual.get(path.as_str()).unwrap_or_else(|| panic!("fixture leaf {path} has no Rust constant"));
        assert_eq!(mirrored, value, "{path}");
    }
    for path in actual.keys() {
        assert!(expected.contains_key(*path), "Rust constant {path} is not in the fixture");
    }
    assert_eq!(expected.len(), actual.len());
}

#[test]
fn every_identifier_hangs_off_one_of_the_two_roots() {
    // Identifiers (labels, services, groups, keys) all start with a root;
    // on-disk names, the URL scheme and the Bonjour types are plain words.
    for (path, value) in constants() {
        if path.starts_with("storage.") || path == "services.urlScheme" || path.ends_with("ServiceType") {
            continue;
        }
        let bare = value.strip_prefix("group.").unwrap_or(value);
        assert!(
            bare.starts_with(PRODUCT_ROOT) || bare.starts_with(VENDOR_ROOT),
            "{path} = {value} hangs off neither root"
        );
    }
}

#[test]
fn logging_category_is_module_or_module_dot_topic() {
    assert_eq!(logging::category("GeniusLocusKit", None), "GeniusLocusKit");
    assert_eq!(logging::category("ConvergenceKit", Some("Sync")), "ConvergenceKit.Sync");
    assert_eq!(keychain::sync_tier_service("2"), "com.codedaptive.mootx01.sync-tier.2");
}

#[test]
fn configuration_directory_follows_the_platform_rule() {
    let home = std::path::PathBuf::from(if cfg!(windows) { r"C:\Users\moot" } else { "/home/moot" });
    let unset = |_: &str| None;
    let set = |name: &str| {
        Some(match name {
            "XDG_DATA_HOME" => "/data/xdg".to_string(),
            "LOCALAPPDATA" => r"D:\Local".to_string(),
            _ => unreachable!(),
        })
    };
    let default_dir = storage::configuration_directory_from(home.clone(), unset);
    let variable_dir = storage::configuration_directory_from(home.clone(), set);
    if cfg!(target_os = "windows") {
        assert_eq!(default_dir, home.join("AppData").join("Local").join("com.mootx01.ce"));
        assert_eq!(variable_dir, std::path::PathBuf::from(r"D:\Local\com.mootx01.ce"));
    } else {
        assert_eq!(default_dir, home.join(".local").join("share").join("mootx01"));
        assert_eq!(variable_dir, std::path::PathBuf::from("/data/xdg/mootx01"));
    }
    assert_eq!(storage::configuration_directory().file_name().unwrap().to_str().unwrap(),
               if cfg!(windows) { "com.mootx01.ce" } else { "mootx01" });
}
