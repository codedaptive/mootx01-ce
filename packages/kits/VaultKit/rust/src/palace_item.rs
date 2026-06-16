//! palace_item — the language-neutral, four-noun unit the canonical palace
//! pump moves. Rust parallel of the Swift `PalaceItem` / `PalaceNoun`.
//!
//! `NoteIR` is the drawer/Obsidian IR; `PalaceItem` is the generic carrier for
//! the WHOLE mootx01 data model (drawer, tunnel, KG fact, diary entry). The
//! pump consumes a flat item — a noun discriminator plus the native-field /
//! envelope-field split the mapper needs. A drawer `PalaceItem` carries the
//! same envelope a `NoteIR` drawer would, so the two paths agree on drawer
//! bytes.
//!
//! ## The read seam (DECISION_PALACE_PUMP_CANONICAL_2026-06-12)
//!
//! VaultKit does NOT read the four nouns itself (it sits above GeniusLocusKit).
//! The operator driver reads each noun through GLK public verbs and projects it
//! to a `PalaceItem`; the driver hands the `Vec<PalaceItem>` stream to the
//! pump. The per-noun read knowledge stays in the driver; the per-noun WIRE
//! knowledge (tool, native args, envelope, verify) stays here in the kit.
//!
//! The envelope-field map uses `serde_json::Value` keyed in a `BTreeMap`, so
//! serialization is sorted/deterministic and the four-noun envelope bytes match
//! the Swift port for identical input (the cross-language conformance anchor).

use std::collections::BTreeMap;

/// Which mootx01 noun a [`PalaceItem`] carries. Drives the mapper's tool
/// choice, the response parser's id key, the verify strategy, and per-noun
/// report counts. Mirrors Swift `PalaceNoun` (the same lowerCamelCase raw
/// values: `drawer`, `tunnel`, `kgFact`, `diaryEntry`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PalaceNoun {
    #[serde(rename = "drawer")]
    Drawer,
    #[serde(rename = "tunnel")]
    Tunnel,
    #[serde(rename = "kgFact")]
    KgFact,
    #[serde(rename = "diaryEntry")]
    DiaryEntry,
}

/// One unit of the data model, ready to write to MemPalace. Mirrors Swift
/// `PalaceItem`. `native_fields` map into native MemPalace tool arguments;
/// `envelope_fields` are every remaining field, preserved losslessly in the
/// content envelope. `BTreeMap` keeps both deterministic.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PalaceItem {
    /// The noun kind.
    pub noun: PalaceNoun,
    /// The source row id (checkpoint/idempotency key).
    pub source_id: String,
    /// The native body text (drawer/diary content, or a readable rendering for
    /// a fact/tunnel).
    pub body: String,
    /// Values destined for native MemPalace tool arguments.
    pub native_fields: BTreeMap<String, serde_json::Value>,
    /// Every other field, preserved in the content envelope (never dropped).
    pub envelope_fields: BTreeMap<String, serde_json::Value>,
}

impl PalaceItem {
    /// Construct a `PalaceItem`.
    pub fn new(
        noun: PalaceNoun,
        source_id: impl Into<String>,
        body: impl Into<String>,
        native_fields: BTreeMap<String, serde_json::Value>,
        envelope_fields: BTreeMap<String, serde_json::Value>,
    ) -> Self {
        Self {
            noun,
            source_id: source_id.into(),
            body: body.into(),
            native_fields,
            envelope_fields,
        }
    }
}
