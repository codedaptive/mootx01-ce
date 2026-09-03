//! JSONL loader for versioned CDL oracle vectors.
//!
//! Loads rows from Tests/ContextDistillLibTests/Vectors/ relative to
//! CARGO_MANIFEST_DIR. Each row is kept as serde_json::Value so the
//! conformance tests can compare fields directly without a Rust schema.
//!
//! This file is included as a module by conformance.rs. It also compiles
//! as its own (empty) test binary — no #[test] functions live here.

use std::path::PathBuf;
use serde_json::Value;

/// Load all rows from one v22 bed file by name (e.g. "debug7", "sample30").
/// File path: ../Tests/ContextDistillLibTests/Vectors/{name}-intent-span-v22.jsonl
/// relative to CARGO_MANIFEST_DIR.
///
/// This function is used by conformance.rs and potentially other test binaries.
/// The dead_code allow is here because oracle_vectors.rs is included as a module
/// in multiple test binaries; each binary uses only the functions it needs.
#[allow(dead_code)]
pub fn load_bed(name: &str) -> Vec<Value> {
    load_bed_suffix(name, "intent-span-v22")
}

/// Load all rows from one bed file using an explicit converter suffix.
///
/// - `name`: bed name, e.g. "debug7", "sample30", "locomo".
/// - `suffix`: filename suffix that selects the converter, e.g.
///   "intent-span-v22" or "intent-span-v23-attributed".
///
/// File path: ../Tests/ContextDistillLibTests/Vectors/{name}-{suffix}.jsonl
/// relative to CARGO_MANIFEST_DIR.
pub fn load_bed_suffix(name: &str, suffix: &str) -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/ContextDistillLibTests/Vectors")
        .join(format!("{}-{}.jsonl", name, suffix));
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", path.display(), e));
    content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).expect("valid JSON line"))
        .collect()
}
