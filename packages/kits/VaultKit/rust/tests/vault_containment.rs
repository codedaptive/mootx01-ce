//! Vault path-containment security tests (VK-SEC-01 / VK-SEC-02).
//!
//! Rust parity for the Swift suite's "Vault containment" MARK sections in
//! `ObsidianAdapterTests.swift` and `ExchangeAdapterTests.swift`.
//!
//! These tests exercise the two security helpers added to the Rust adapters:
//!
//! * `contained_vault_path` (in `obsidian_adapter.rs`) — rejects `..`,
//!   absolute paths, backslashes, and empty/`.` components before building
//!   a filesystem path from an untrusted label.
//! * `write_contained_file` (in `obsidian_adapter.rs`) — verifies the
//!   written path stays inside the vault root after `canonicalize`
//!   (symlink expansion), and refuses pre-existing symlinks at the
//!   destination.
//! * `validated_path_components` (in `exchange_adapter.rs`) — rejects the
//!   same unsafe lexical patterns in the `pathComponents` JSON field.
//!
//! These tests live in the integration-test tree (not `#[cfg(test)]` inside
//! lib.rs) because the lib-test suite has a pre-existing compile failure in
//! `palace_bridge.rs` (out of scope for this mission) that would prevent
//! the lib-test binary from being built.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;
use vault_kit::{Block, ExchangeAdapter, NoteIR, ObsidianAdapter, VaultAdapter, VaultKitError};

// ---------------------------------------------------------------------------
// TempVault: a unique temporary directory that cleans up on drop.
// ---------------------------------------------------------------------------

struct TempVault(PathBuf);

impl TempVault {
    /// Create a fresh empty directory under the OS temp directory.
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("vk-sec-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).expect("temp vault dir must be creatable");
        Self(path)
    }

    fn path(&self) -> &PathBuf {
        &self.0
    }
}

impl Drop for TempVault {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

// ---------------------------------------------------------------------------
// Helper: build a minimal exchange-export JSON payload whose single entry
// has the given pathComponents array.
// ---------------------------------------------------------------------------

fn json_with_path_components(components: &[&str]) -> Vec<u8> {
    let encoded: Vec<String> = components
        .iter()
        .map(|c| format!("\"{}\"", c.replace('\\', "\\\\").replace('"', "\\\"")))
        .collect();
    let inner = encoded.join(",");
    format!(
        r#"{{"name":"n","entries":[{{"id":"a","content":"c","pathComponents":[{inner}]}}]}}"#
    )
    .into_bytes()
}

// ---------------------------------------------------------------------------
// Helper: build a minimal single-note corpus with the given stable_source_key.
// ---------------------------------------------------------------------------

fn corpus_with_key(key: &str) -> Vec<NoteIR> {
    vec![NoteIR::new(
        key,
        vec![Block::markdown("test body")],
        HashMap::new(),
        vec![],
        vec![],
        "",
        None,
        None,
    )]
}

// ---------------------------------------------------------------------------
// ExchangeAdapter pathComponents validation (VK-SEC-02)
// ---------------------------------------------------------------------------

#[test]
fn decode_rejects_dot_dot_in_path_components() {
    // Classic directory traversal via `..`.
    let data = json_with_path_components(&[".."]);
    let result = ExchangeAdapter::new().decode(&data);
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for '..', got {result:?}"
    );
}

#[test]
fn decode_rejects_slash_in_path_components() {
    // 'a/b' as a single component is path injection — must be caught before
    // the value reaches the filesystem.
    let data = json_with_path_components(&["a/b"]);
    let result = ExchangeAdapter::new().decode(&data);
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for 'a/b', got {result:?}"
    );
}

#[test]
fn decode_rejects_backslash_in_path_components() {
    let data = json_with_path_components(&["a\\b"]);
    let result = ExchangeAdapter::new().decode(&data);
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for 'a\\b', got {result:?}"
    );
}

#[test]
fn decode_rejects_dot_component_in_path_components() {
    // A bare `.` component is a current-directory reference — reject it.
    let data = json_with_path_components(&["."]);
    let result = ExchangeAdapter::new().decode(&data);
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for '.', got {result:?}"
    );
}

#[test]
fn decode_rejects_empty_component_in_path_components() {
    let data = json_with_path_components(&[""]);
    let result = ExchangeAdapter::new().decode(&data);
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for empty component, got {result:?}"
    );
}

#[test]
fn decode_accepts_legitimate_path_components() {
    // Normal multi-level label — must decode cleanly.
    let data = json_with_path_components(&["projects", "alpha"]);
    let export = ExchangeAdapter::new()
        .decode(&data)
        .expect("legitimate pathComponents must decode");
    assert_eq!(export.notes[0].path_components, vec!["projects", "alpha"]);
}

// ---------------------------------------------------------------------------
// ObsidianAdapter note-write containment (VK-SEC-01)
// ---------------------------------------------------------------------------

#[test]
fn from_ir_rejects_dot_dot_traversal() {
    let vault = TempVault::new();
    // `stable_source_key` becomes the vault-relative path; `..` must be
    // caught by `contained_vault_path` before any filesystem write.
    let corpus = corpus_with_key("../escape");
    let result = ObsidianAdapter::new().from_ir(&corpus, vault.path());
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for '../escape', got {result:?}"
    );
}

#[test]
fn from_ir_rejects_multi_level_traversal() {
    let vault = TempVault::new();
    let corpus = corpus_with_key("notes/../../../escape");
    let result = ObsidianAdapter::new().from_ir(&corpus, vault.path());
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for multi-level traversal, got {result:?}"
    );
}

#[test]
fn from_ir_rejects_backslash_in_key() {
    let vault = TempVault::new();
    let corpus = corpus_with_key("folder\\backslash");
    let result = ObsidianAdapter::new().from_ir(&corpus, vault.path());
    assert!(
        matches!(result, Err(VaultKitError::AdapterError(_))),
        "expected AdapterError for backslash key, got {result:?}"
    );
}

#[test]
fn from_ir_accepts_legitimate_nested_key() {
    let vault = TempVault::new();
    // Wing/Room style — must write a file inside the vault and NOT error.
    let corpus = corpus_with_key("Wing/Room/my-note");
    ObsidianAdapter::new()
        .from_ir(&corpus, vault.path())
        .expect("Wing/Room/my-note is a legitimate nested key");
    let expected = vault.path().join("Wing").join("Room").join("my-note.md");
    assert!(
        expected.exists(),
        "expected file at {expected:?} after from_ir"
    );
}

#[test]
fn from_ir_accepts_root_level_key() {
    let vault = TempVault::new();
    let corpus = corpus_with_key("root-note");
    ObsidianAdapter::new()
        .from_ir(&corpus, vault.path())
        .expect("root-level key must be accepted");
    assert!(vault.path().join("root-note.md").exists());
}
