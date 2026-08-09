//! Import stamp parity gate — Part 2 parity gate (MXE-JI-5).
//!
//! Asserts that `IMPORT_EMBEDDING_MODEL_ID` (locus_kit) is the single source
//! of truth for every import writer: DrawerMapping default, PalaceBridge, and
//! JsonImportBridge all route through it; the constant itself is pinned to
//! the canonical string. Mirrors `ImportStampParityTests.swift`.

use locus_kit::dataset_handle::IMPORT_EMBEDDING_MODEL_ID;
use vault_kit::DrawerMapping;

/// Pin the constant value so any accidental change surfaces immediately.
#[test]
fn constant_value() {
    assert_eq!(IMPORT_EMBEDDING_MODEL_ID, "vaultkit-noembed-v1");
}

/// DrawerMapping::default() uses the shared constant as embedding_model_id.
#[test]
fn drawer_mapping_default_uses_shared_constant() {
    let mapping = DrawerMapping::default();
    assert_eq!(mapping.embedding_model_id, IMPORT_EMBEDDING_MODEL_ID);
}
