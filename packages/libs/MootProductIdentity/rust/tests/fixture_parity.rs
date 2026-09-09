// fixture_parity.rs — every constant equals its leaf in the shared fixture.
//
// `Fixtures/product_identity.json` is the one pin both ports read. The Swift
// library's tests cover the fixture leaf by leaf; this test does the same for
// the Rust constants listed in `constants()`, in both directions: a fixture
// leaf with no listed constant fails, and a listed constant with no leaf
// fails. The list is hand-maintained, so a constant added to lib.rs must be
// added here too; `every_pub_const_is_listed` reads lib.rs and refuses one
// that is not.

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

/// One listed constant: the fixture path, the Rust path as written (so the
/// name guard can key on the constant's NAME, not its value), and the value.
struct Listed {
    rust_path: &'static str,
    value: &'static str,
}

macro_rules! c {
    ($path:expr, $konst:path) => {
        ($path, Listed { rust_path: stringify!($konst), value: $konst })
    };
}

fn listed() -> BTreeMap<&'static str, Listed> {
    use apple::bundle_identifiers as b;
    BTreeMap::from([
        c!("productRoot", PRODUCT_ROOT),
        c!("vendorRoot", VENDOR_ROOT),
        c!("storage.applicationSupportFolder", storage::APPLICATION_SUPPORT_FOLDER),
        c!("storage.unixDataFolder", storage::UNIX_DATA_FOLDER),
        c!("storage.latticeFolder", storage::LATTICE_FOLDER),
        c!("storage.catalogFile", storage::CATALOG_FILE),
        c!("storage.databasesFolder", storage::DATABASES_FOLDER),
        c!("storage.defaultEstateName", storage::DEFAULT_ESTATE_NAME),
        c!("storage.estateDatabaseFile", storage::ESTATE_DATABASE_FILE),
        c!("storage.communityDaemonFolder", storage::COMMUNITY_DAEMON_FOLDER),
        c!("logging.subsystem", logging::SUBSYSTEM),
        c!("services.daemonLabel", services::DAEMON_LABEL),
        c!("services.managerLabel", services::MANAGER_LABEL),
        c!("services.contractHostOwner", services::CONTRACT_HOST_OWNER),
        c!("services.daemonProviderLaunchAgentLabel", services::DAEMON_PROVIDER_LAUNCH_AGENT_LABEL),
        c!("services.bonjourServiceType", services::BONJOUR_SERVICE_TYPE),
        c!("services.federationBonjourServiceType", services::FEDERATION_BONJOUR_SERVICE_TYPE),
        c!("services.urlScheme", services::URL_SCHEME),
        c!("keychain.estateKeyService", keychain::ESTATE_KEY_SERVICE),
        c!("keychain.sharedAccessGroup", keychain::SHARED_ACCESS_GROUP),
        c!("keychain.estateIdentityService", keychain::ESTATE_IDENTITY_SERVICE),
        c!("keychain.lanCredentialService", keychain::LAN_CREDENTIAL_SERVICE),
        c!("keychain.daemonAuthService", keychain::DAEMON_AUTH_SERVICE),
        c!("keychain.daemonProofService", keychain::DAEMON_PROOF_SERVICE),
        c!("keychain.crossInstallCustodyProofService", keychain::CROSS_INSTALL_CUSTODY_PROOF_SERVICE),
        c!("keychain.secretSyncSigningHandleService", keychain::SECRET_SYNC_SIGNING_HANDLE_SERVICE),
        c!("keychain.secretSyncAgreementHandleService", keychain::SECRET_SYNC_AGREEMENT_HANDLE_SERVICE),
        c!("keychain.secretSyncProtectedHeadService", keychain::SECRET_SYNC_PROTECTED_HEAD_SERVICE),
        c!("keychain.syncTierServicePrefix", keychain::SYNC_TIER_SERVICE_PREFIX),
        c!("keychain.syncTierAccessGroup", keychain::SYNC_TIER_ACCESS_GROUP),
        c!("keychain.estateSurgeryCloneRecipientService", keychain::ESTATE_SURGERY_CLONE_RECIPIENT_SERVICE),
        c!("apple.appGroup", apple::APP_GROUP),
        c!("apple.spotlightDomain", apple::SPOTLIGHT_DOMAIN),
        c!("apple.miningRefreshTaskIdentifier", apple::MINING_REFRESH_TASK_IDENTIFIER),
        c!("apple.shareErrorDomain", apple::SHARE_ERROR_DOMAIN),
        c!("apple.bundleIdentifiers.macOSApp", b::MACOS_APP),
        c!("apple.bundleIdentifiers.iOSApp", b::IOS_APP),
        c!("apple.bundleIdentifiers.communityMacOSApp", b::COMMUNITY_MACOS_APP),
        c!("apple.bundleIdentifiers.daemonProvider", b::DAEMON_PROVIDER),
        c!("apple.bundleIdentifiers.daemonHelper", b::DAEMON_HELPER),
        c!("apple.bundleIdentifiers.daemonProofHost", b::DAEMON_PROOF_HOST),
        c!("apple.bundleIdentifiers.custodyProofSandboxHelper", b::CUSTODY_PROOF_SANDBOX_HELPER),
        c!("apple.bundleIdentifiers.custodyProofDeveloperIDDaemon", b::CUSTODY_PROOF_DEVELOPER_ID_DAEMON),
        c!("preferences.residency", preferences::RESIDENCY),
        c!("preferences.gatewayHasCompletedOnboarding", preferences::GATEWAY_HAS_COMPLETED_ONBOARDING),
        c!("preferences.gatewayIsAdvancedMode", preferences::GATEWAY_IS_ADVANCED_MODE),
        c!("preferences.gatewayShowQuickCapture", preferences::GATEWAY_SHOW_QUICK_CAPTURE),
        c!("preferences.portableOnPowerOnly", preferences::PORTABLE_ON_POWER_ONLY),
        c!("preferences.portableServiceName", preferences::PORTABLE_SERVICE_NAME),
        c!("queues.ariaHTTPAccept", queues::ARIA_HTTP_ACCEPT),
        c!("queues.managerControlChannelAccept", queues::MANAGER_CONTROL_CHANNEL_ACCEPT),
        c!("queues.managerHTTPReadAPIAccept", queues::MANAGER_HTTP_READ_API_ACCEPT),
        c!("queues.lanDiscovery", queues::LAN_DISCOVERY),
        c!("queues.lanBrowser", queues::LAN_BROWSER),
    ])
}

/// Fixture path -> value, the view the leaf-by-leaf comparison uses.
fn constants() -> BTreeMap<&'static str, &'static str> {
    listed().into_iter().map(|(path, entry)| (path, entry.value)).collect()
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

/// The guard above is only as complete as `listed()`. This reads lib.rs and
/// refuses any `pub const NAME` whose NAME is not the last segment of a listed
/// constant's Rust path, so a constant added to the crate cannot escape the
/// fixture pin (`storage::UNIX_DATA_FOLDER` once did). Keyed on the name, not
/// the value: `services::URL_SCHEME` and `storage::UNIX_DATA_FOLDER` both
/// carry "mootx01", so a value-keyed guard would let an unlisted constant
/// with a duplicate value through. The Swift twin
/// (`everySourceConstantIsAFixtureLeaf`) reads the Swift source the same way.
#[test]
fn every_pub_const_is_listed() {
    let source = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/lib.rs")).expect("lib.rs");
    let listed_names: std::collections::BTreeSet<&str> = listed()
        .values()
        .map(|entry| entry.rust_path.rsplit("::").next().unwrap())
        .collect();
    let mut seen = 0;
    for line in source.lines() {
        let Some(rest) = line.trim_start().strip_prefix("pub const ") else { continue };
        let name: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
        assert!(listed_names.contains(name.as_str()),
                "lib.rs `pub const {name}` is not listed in fixture_parity.rs, so the fixture does not pin it");
        seen += 1;
    }
    assert_eq!(seen, listed_names.len(), "every listed name is a `pub const` in lib.rs and vice versa");
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
