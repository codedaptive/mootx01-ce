//! vault-kit — Rust port of VaultKit.
//!
//! VaultKit bridges a MOOT estate to a human-readable Markdown vault in
//! both directions. The substrate stays authoritative; the vault is a
//! projection (export) or an external source (import). Obsidian is the
//! first adapter, behind a modular `VaultAdapter` seam.
//!
//! This crate is the Rust parallel of the Swift `VaultKit` Swift Package.
//! Per Vault import/export (f), `NoteIR` and its companion types are the
//! language-neutral contract; the Rust types here are a mechanical port of
//! the Swift V1 home. The FNV-1a 128-bit `lineage_id` derivation in
//! `DrawerMapping` must produce bit-identical output to the Swift
//! implementation for the same `stable_source_key` input — this is the
//! cross-language conformance anchor.
//!
//! ## Crate layout
//!
//! - `note_ir` — `NoteIR`, `Block`, `WikiLink`, `SourceRef`, `OccurredAt`,
//!   `FactIR` (the language-neutral IR boundary contract, full-fidelity
//!   per data-movement privacy tiers).
//! - `corpus_document` — `CorpusDocument` (the versioned canonical JSON
//!   interchange envelope; deterministic encode, strict versioned decode).
//! - `vault_adapter` — `VaultAdapter` trait (format ⇄ `NoteIR`).
//! - `obsidian_adapter` — `ObsidianAdapter: VaultAdapter` (Markdown/YAML/
//!   wikilink/tag ⇄ `NoteIR`; one `.md` file = one `NoteIR`).
//! - `exchange_adapter` — `ExchangeAdapter: VaultAdapter` (external
//!   memory-tool JSON export ⇄ `NoteIR`; read side per VK-ADAPT-01,
//!   write side per VK-EXPORT-01).
//! - `corpus_projection` — `Vec<NoteIR>` → `ExternalCorpus` so migration
//!   verification and the fidelity benchmark are fed from the adapter
//!   pipeline.
//! - `drawer_mapping` — `DrawerMapping` + `ImportOutcome` (`NoteIR` ⇄
//!   substrate `Drawer`/`Tunnel` via the GLK verb surface).
//! - `vault_bridge` — `VaultBridge` + `ImportReport` (the public facade).
//! - `palace_bridge` — `PalaceBridge` + `ImportReport` (direct palace →
//!   substrate import, bypassing NoteIR; applies four import guards:
//!   tombstone, content-idempotent dedup, sensitivity floor, tunnel sig dedup).
//! - `json_import_bridge` — `JsonImportBridge` + seed-file schema v1 types
//!   (the fourth import lane: rigid versioned JSON with total pre-write
//!   validation, strict-append collision assertion, file-order ingestion;
//!   see `docs/JSON_IMPORT_FORMAT.md`).
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

pub mod corpus_document;
pub mod corpus_projection;
pub mod drawer_mapping;
pub mod error;
pub mod exchange_adapter;
pub mod import_policy;
pub mod json_import_bridge;
pub mod mcp_stdio_client;
pub mod mem_palace_chroma_adapter;
pub mod note_ir;
pub mod obsidian_adapter;
pub mod palace_bridge;
pub mod palace_drift_detector;
pub mod palace_item;
pub mod palace_payload_envelope;
pub mod palace_pump;
pub mod palace_pump_mapping;
pub mod palace_response_parsing;
pub mod vault_adapter;
pub mod vault_bridge;
pub mod vault_export_scope;

pub use corpus_document::{CorpusDocument, CURRENT_FORMAT_VERSION};
pub use drawer_mapping::{DrawerMapping, ExportProjection, ImportOutcome};
pub use error::VaultKitError;
pub use exchange_adapter::{ExchangeAdapter, ExchangeExport};
pub use json_import_bridge::{
    JsonImportLimits, JsonSeedFact, JsonSeedFile, JsonSeedRecord, JsonSeedTunnel,
};
pub use mcp_stdio_client::{McpCallResult, McpClientError, McpStdioClient};
pub use mem_palace_chroma_adapter::MemPalaceChromaAdapter;
pub use note_ir::{Block, FactIR, NoteIR, OccurredAt, SourceRef, WikiLink};
pub use obsidian_adapter::ObsidianAdapter;
pub use palace_drift_detector::{
    diff as palace_drift_diff, expected_manifest as palace_expected_manifest, PalaceDriftFinding,
    PalaceExpectedTool, PalaceLiveTool,
};
pub use palace_item::{PalaceItem, PalaceNoun};
pub use palace_payload_envelope::{
    decode as palace_envelope_decode, decode_fields as palace_envelope_decode_fields,
    encode as palace_envelope_encode, encode_fields as palace_envelope_encode_fields,
    reconstruct_note as palace_reconstruct_note, DecodedFields, EnvelopeDecodeError,
    PalaceEnvelopePayload,
};
pub use palace_pump::{
    CheckpointQueue, PalaceItemJobPayload, PalacePump, PalacePumpError, PalacePumpItemResult,
    PalacePumpResult, PumpJobPayload,
};
pub use palace_pump_mapping::{
    call as palace_item_call, make_args as palace_make_args, PalaceCall, PalaceDrawerArgs,
};
pub use palace_response_parsing::{
    assigned_id_key, parse_add_drawer_id, parse_assigned_id, parse_get_drawer, PalaceFetchedDrawer,
    PalaceResponseError,
};
pub use vault_adapter::VaultAdapter;
pub use vault_bridge::{ExportReport, ImportReport, VaultBridge};
pub use vault_export_scope::VaultExportScope;
