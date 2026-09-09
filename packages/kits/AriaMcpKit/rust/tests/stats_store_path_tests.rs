// stats_store_path_tests.rs — Rust wiring tests for `stats_store_path`.
//
// Mirrors Swift `AriaResidentTelemetryTests.StatsStorePathTests`:
// wiring tests that prove the `config_dir` seam routes through
// `moot_product_identity::settings::load` (two tests: key-set and key-absent).
// Existing tests pass `None` for config_dir; the wiring tests inject a scratch
// directory so no real config.json is read.

use uuid::Uuid;
use aria_mcp::stats_store_path;

/// Wiring test (key set): stats_store_path with a scratch config dir that has
/// `daemon.stats_store` set returns that configured path. Deleting the
/// `moot_product_identity::settings::load` call in stats_store_path makes
/// this test red.
#[test]
fn wiring_key_set_returns_configured_path() {
    let scratch = std::env::temp_dir()
        .join(format!("aria-ssp-wiring-set-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    let custom = scratch.join("custom-stats.sqlite");
    let json = format!(r#"{{"daemon":{{"stats_store":"{}"}}}}"#, custom.display());
    std::fs::write(scratch.join("config.json"), json).unwrap();

    let result = stats_store_path(true, Some(&scratch));
    assert_eq!(
        result.as_deref(),
        Some(custom.to_string_lossy().as_ref()),
        "stats_store_path must return daemon.stats_store from config.json; got {:?}",
        result
    );
}

/// Wiring test (key absent): stats_store_path with a scratch config dir that
/// has no config.json falls back to the computed default under that dir.
#[test]
fn wiring_key_absent_returns_computed_default() {
    let scratch = std::env::temp_dir()
        .join(format!("aria-ssp-wiring-absent-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    // No config.json written — key is absent.
    let result = stats_store_path(true, Some(&scratch));
    let expected = scratch.join("moot-mgr").join("stats.sqlite");
    assert_eq!(
        result.as_deref(),
        Some(expected.to_string_lossy().as_ref()),
        "stats_store_path must fall back to <configDir>/moot-mgr/stats.sqlite; got {:?}",
        result
    );
}

/// Control: use_default=false always returns None regardless of config dir.
#[test]
fn use_default_false_returns_none() {
    let scratch = std::env::temp_dir()
        .join(format!("aria-ssp-none-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    let result = stats_store_path(false, Some(&scratch));
    assert!(result.is_none(), "stdio mode must return None; got {:?}", result);
}
