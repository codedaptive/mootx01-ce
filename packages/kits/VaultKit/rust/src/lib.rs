//! vault-kit — Rust port of VaultKit.
//!
//! VaultKit bridges a MOOT estate to a human-readable Markdown vault in
//! both directions. The substrate stays authoritative; the vault is a
//! projection (export) or an external source (import). Obsidian is the
//! first adapter, behind a modular `VaultAdapter` seam.
//!
//! This crate is the Rust parallel of the Swift `VaultKit` Swift Package.
//! Per ADR-VAULTKIT-001 (f), `NoteIR` and its companion types are the
//! language-neutral contract; the Rust types here are a mechanical port of
//! the Swift V1 home. The FNV-1a 128-bit `lineage_id` derivation in
//! `DrawerMapping` must produce bit-identical output to the Swift
//! implementation for the same `stable_source_key` input — this is the
//! cross-language conformance anchor.
//!
//! ## Crate layout
//!
//! - `note_ir` — `NoteIR`, `Block`, `WikiLink`, `SourceRef`, `OccurredAt`
//!   (the language-neutral IR boundary contract).
//! - `vault_adapter` — `VaultAdapter` trait (format ⇄ `NoteIR`).
//! - `obsidian_adapter` — `ObsidianAdapter: VaultAdapter` (Markdown/YAML/
//!   wikilink/tag ⇄ `NoteIR`; one `.md` file = one `NoteIR`).
//! - `drawer_mapping` — `DrawerMapping` + `ImportOutcome` (`NoteIR` ⇄
//!   substrate `Drawer`/`Tunnel` via the GLK verb surface).
//! - `vault_bridge` — `VaultBridge` + `ImportReport` (the public facade).
//! - `error` — `VaultKitError` (MOOTx01Error-style structured error enum).
//!
//! ## Conformance
//!
//! The FNV-1a 128-bit lineage-ID derivation in `drawer_mapping::lineage_id`
//! must produce byte-identical output to `DrawerMapping.lineageID(forStableSourceKey:)`
//! in the Swift port for every `stable_source_key`. The cross-language vector
//! test in `tests/fnv_vector.rs` asserts this over the canonical inputs used
//! by the Swift `DrawerMappingTests`.

#![deny(rust_2018_idioms)]

pub mod drawer_mapping;
pub mod error;
pub mod note_ir;
pub mod obsidian_adapter;
pub mod vault_adapter;
pub mod vault_bridge;

pub use drawer_mapping::{DrawerMapping, ImportOutcome};
pub use error::VaultKitError;
pub use note_ir::{Block, NoteIR, OccurredAt, SourceRef, WikiLink};
pub use obsidian_adapter::ObsidianAdapter;
pub use vault_adapter::VaultAdapter;
pub use vault_bridge::{ImportReport, VaultBridge};
