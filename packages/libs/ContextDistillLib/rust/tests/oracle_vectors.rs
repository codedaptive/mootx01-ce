//! JSONL loader for the CDL-01 oracle vectors.
//!
//! Loads rows from Tests/ContextDistillLibTests/Vectors/ relative to
//! CARGO_MANIFEST_DIR. Each row is kept as serde_json::Value so the
//! conformance tests can compare fields directly without a Rust schema.
//!
//! This file is included as a module by conformance.rs. It also compiles
//! as its own (empty) test binary — no #[test] functions live here.

use std::path::PathBuf;
use serde_json::Value;

/// Load all rows from one bed file by name (e.g. "debug7", "sample30").
/// File path: ../Tests/ContextDistillLibTests/Vectors/{name}-intent-span-v22.jsonl
/// relative to CARGO_MANIFEST_DIR.
pub fn load_bed(name: &str) -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/ContextDistillLibTests/Vectors")
        .join(format!("{}-intent-span-v22.jsonl", name));
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", path.display(), e));
    content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).expect("valid JSON line"))
        .collect()
}

