// settings_tests.rs
//
// Verifies three contracts for moot_product_identity::settings:
//   (a) absent key → load() returns None → caller uses its computed default
//   (b) key set to a scratch path → load() returns that path
//   (c) seed_defaults_if_absent writes once on a fresh dir, leaves a
//       pre-set value alone on a second call (idempotency)
//
// A mutation guard at the end of (b) confirms the gate discriminates:
// a reader that ignores the key would fail the keySet test while this
// file compiles and passes — same red/green evidence as the Swift suite.

use moot_product_identity::{paths, settings, storage};
use std::path::PathBuf;

// ── helpers ──────────────────────────────────────────────────────────────────

fn tmp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("com.mootx01.settings-tests-{label}-{}", uuid_hex()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

fn uuid_hex() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    format!("{ns:x}")
}

fn write_config(dir: &PathBuf, json: &str) {
    std::fs::write(dir.join("config.json"), json).expect("write config.json");
}

// ── (a) absent key → None ────────────────────────────────────────────────────

#[test]
fn absent_file_returns_none() {
    let dir = tmp_dir("absent-file");
    let s = settings::load(&dir);
    assert!(
        s.daemon_stats_store.is_none(),
        "absent config.json must yield None so callers use their computed default"
    );
}

#[test]
fn present_file_absent_key_returns_none() {
    let dir = tmp_dir("absent-key");
    write_config(&dir, r#"{"daemon":{}}"#);
    let s = settings::load(&dir);
    assert!(
        s.daemon_stats_store.is_none(),
        "present file without daemon.stats_store must yield None"
    );
}

#[test]
fn empty_string_treated_as_absent() {
    let dir = tmp_dir("empty-string");
    write_config(&dir, r#"{"daemon":{"stats_store":""}}"#);
    let s = settings::load(&dir);
    assert!(
        s.daemon_stats_store.is_none(),
        "an empty string in the file must be treated as absent"
    );
}

// ── (b) key set → that path returned ─────────────────────────────────────────

#[test]
fn key_set_returns_override_path() {
    let dir = tmp_dir("key-set");
    let override_path = dir.join("custom-stats.sqlite");
    let override_str = override_path.to_str().unwrap();
    write_config(
        &dir,
        &format!(r#"{{"daemon":{{"stats_store":"{override_str}"}}}}"#),
    );
    let s = settings::load(&dir);
    assert_eq!(
        s.daemon_stats_store.as_deref(),
        Some(override_str),
        "daemon.stats_store in config.json must be returned verbatim"
    );
}

#[test]
fn key_set_unknown_keys_ignored() {
    let dir = tmp_dir("unknown-keys");
    let override_path = dir.join("custom-stats.sqlite");
    let override_str = override_path.to_str().unwrap();
    // Extra keys must not affect parsing.
    write_config(
        &dir,
        &format!(
            r#"{{"daemon":{{"stats_store":"{override_str}","future_key":"ignored"}},"other_section":{{}}}}"#
        ),
    );
    let s = settings::load(&dir);
    assert_eq!(
        s.daemon_stats_store.as_deref(),
        Some(override_str),
        "unknown keys must be ignored; the known key must still be returned"
    );
}

// ── (c) seed_defaults_if_absent — idempotency ─────────────────────────────────

#[test]
fn seed_writes_default_when_absent() {
    let dir = tmp_dir("seed-absent");
    let default_path = dir.join("moot-mgr/stats.sqlite");
    let default_str = default_path.to_str().unwrap();
    let result = settings::seed_defaults_if_absent(&dir, default_str)
        .expect("seed must not error on a fresh directory");
    // Ok(false) means the file was written (key was absent).
    assert!(!result, "seed_defaults_if_absent must return Ok(false) when writing");
    let s = settings::load(&dir);
    assert_eq!(
        s.daemon_stats_store.as_deref(),
        Some(default_str),
        "after seeding, load() must return the seeded default path"
    );
}

#[test]
fn seed_preserves_preset_value() {
    let dir = tmp_dir("seed-preset");
    let custom_path = dir.join("operator-chosen.sqlite");
    let custom_str = custom_path.to_str().unwrap();
    // Operator pre-set the key before install ran.
    write_config(
        &dir,
        &format!(r#"{{"daemon":{{"stats_store":"{custom_str}"}}}}"#),
    );
    let default_path = dir.join("moot-mgr/stats.sqlite");
    let default_str = default_path.to_str().unwrap();
    let result = settings::seed_defaults_if_absent(&dir, default_str)
        .expect("seed must not error when key is already present");
    // Ok(true) means the key was already present — no-op.
    assert!(result, "seed_defaults_if_absent must return Ok(true) when key already present");
    let s = settings::load(&dir);
    assert_eq!(
        s.daemon_stats_store.as_deref(),
        Some(custom_str),
        "seed_defaults_if_absent must NOT overwrite a pre-set value"
    );
}

// ── (d) C-2 — seeded path resolves under the configuration directory ──────────

/// `storage::configuration_directory()` is the canonical per-platform
/// configuration directory for the Rust port. This test verifies:
///   - The directory is an absolute, non-empty path (so no caller can silently
///     build a relative path that resolves against an unknown cwd).
///   - A path seeded into a scratch directory is nested under that directory —
///     confirming that `paths::daemon_stats_store_default` + `settings::seed`
///     compose correctly and that no Rust caller builds a hand-crafted
///     platform path that diverges from the product identity (C-2).
///
/// On Linux the canonical path is `~/.local/share/mootx01/…`; on macOS CI
/// it mirrors the Apple container path. Neither is hard-coded here; the
/// injected scratch directory avoids touching the developer's real config.
#[test]
fn settings_resolves_under_configuration_directory() {
    // Production default is absolute and non-empty.
    let prod_dir = storage::configuration_directory();
    let prod_str = prod_dir.to_string_lossy();
    assert!(!prod_str.is_empty(), "configuration_directory must be non-empty");
    assert!(
        prod_dir.is_absolute(),
        "configuration_directory must be absolute; got: {prod_str}"
    );

    // A seeded default is nested under the injected scratch directory.
    let scratch = tmp_dir("c2-nested");
    let default_path = paths::daemon_stats_store_default(&scratch);
    settings::seed_defaults_if_absent(&scratch, &default_path)
        .expect("seed must succeed on a fresh scratch directory");
    let loaded = settings::load(&scratch);
    assert!(
        loaded
            .daemon_stats_store
            .as_deref()
            .map(|p| p.starts_with(scratch.to_string_lossy().as_ref()))
            .unwrap_or(false),
        "seeded default must be nested under the injected configuration directory (C-2)"
    );
}

#[test]
fn seed_idempotent_second_call_preserves_first_default() {
    let dir = tmp_dir("seed-idempotent");
    let default_path = dir.join("moot-mgr/stats.sqlite");
    let default_str = default_path.to_str().unwrap();
    // First call: seeds the default.
    settings::seed_defaults_if_absent(&dir, default_str).unwrap();
    // Second call: no-op — key already present.
    let result = settings::seed_defaults_if_absent(&dir, default_str).unwrap();
    assert!(result, "second call must return Ok(true)");
    let s = settings::load(&dir);
    assert_eq!(
        s.daemon_stats_store.as_deref(),
        Some(default_str),
        "second call must leave the seeded value intact"
    );
}
