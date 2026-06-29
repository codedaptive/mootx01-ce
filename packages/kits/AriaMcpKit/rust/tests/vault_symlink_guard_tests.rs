//! Symlink-containment guard tests for `write_manifest` (secfix/c-aria-minor CAND-014).
//!
//! Verifies that a pre-planted symlink at `.moot/export-manifest.json` causes
//! `write_manifest` to refuse rather than follow the link. Mirrors the test
//! added to the Swift port's `VaultToolsTests.writeManifest_refusesPreExistingSymlinkAtManifestPath`.

use aria_mcp::vault_tools::{write_manifest, ExportManifest};
use std::collections::BTreeMap;

/// A pre-planted symlink at the manifest path causes `write_manifest` to return
/// an error instead of following the link. The symlink target must not be created.
#[test]
fn write_manifest_refuses_pre_existing_symlink_at_manifest_path() {
    let vault_dir = std::env::temp_dir().join(format!(
        "symlink-guard-rust-{}",
        uuid_string()
    ));
    let moot_dir = vault_dir.join(".moot");
    std::fs::create_dir_all(&moot_dir).expect("create .moot dir");

    // Plant a symlink at the manifest path pointing to a location outside the vault.
    // The target does NOT need to exist — `symlink_metadata` detects broken symlinks too.
    let manifest_path = vault_dir.join(".moot/export-manifest.json");
    let symlink_target = std::env::temp_dir().join(format!(
        "symlink-target-rust-{}.json",
        uuid_string()
    ));
    #[cfg(unix)]
    std::os::unix::fs::symlink(&symlink_target, &manifest_path)
        .expect("create symlink at manifest path");

    // A minimal manifest — content doesn't matter, the guard fires before serialization.
    let manifest = ExportManifest {
        exported_at: "2026-01-01T00:00:00Z".to_string(),
        note_count: 0,
        files: BTreeMap::new(),
    };

    // write_manifest must return an error, not follow the symlink.
    let result = write_manifest(&manifest, &vault_dir);
    assert!(
        result.is_err(),
        "write_manifest must refuse a pre-existing symlink at the manifest path"
    );

    // The symlink target must NOT have been created — the write was refused.
    assert!(
        !symlink_target.exists(),
        "symlink target must not be created; the manifest write must be refused"
    );

    // Clean up.
    let _ = std::fs::remove_dir_all(&vault_dir);
    let _ = std::fs::remove_file(&symlink_target);
}

/// Helper: generate a unique string without pulling in the uuid crate.
fn uuid_string() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    // PID + nanos gives enough uniqueness for temp-dir names in tests.
    format!("{}-{}", std::process::id(), nanos)
}
