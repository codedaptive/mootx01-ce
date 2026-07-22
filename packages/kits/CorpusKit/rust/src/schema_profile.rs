//! Explicit operating-profile schema declarations + operating-mode and
//! index-unit-policy validation (GLK shared-content 1.1, P1).
//! Rust twin of Swift `CorpusSchemaProfile.swift`.
//!
//! STANDALONE — CorpusKit owns canonical documents (`corpus_documents` +
//! change journal), the derived tables, `corpus_index_state`, and — only
//! when passage indexing is enabled — `corpus_passages` (token-budgeted
//! UTF-8 RANGES; no verbatim text).
//!
//! ATTACHED — LocusKit Drawers are canonical; the declaration carries
//! ONLY rebuildable derived state keyed by canonical content ID:
//! iix_termfreqs + iix_doclens, corpus_provider_basis +
//! corpus_provider_counts, and corpus_index_state. It EXCLUDES chunks,
//! corpus_metadata, corpus_documents, corpus_passages, and
//! removed_sources.
//!
//! NOTE (Rust-port structural fact recorded in P0's characterization):
//! today's Rust `InvertedIndexStore` keeps iix_* in a PRIVATE rusqlite
//! connection rather than the estate storage. The declarations below are
//! the ESTATE-side layout both profiles publish — the P3 cutover moves
//! the Rust store's persistence onto them, matching Swift, so both ports
//! open each other's fixtures.

use crate::basis_store::BasisStore;
use crate::corpus_provider_counts_store::CorpusProviderCountsStore;
use crate::document_store::CorpusDocumentStore;
use crate::error::CorpusKitError;
use crate::index_state_store::CorpusIndexStateStore;
use persistence_kit::{ColumnDeclaration, IndexDeclaration, SchemaDeclaration, TableDeclaration};
use std::collections::BTreeSet;

/// The index-unit policy: what one derived index entry covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorpusIndexUnitPolicy {
    /// One index unit per canonical content row — the DEFAULT everywhere
    /// and the ONLY policy attached mode accepts.
    WholeContent,
    #[cfg(feature = "standalone-passages")]
    /// Standalone-only: optional token-window passages (versioned CorpusKit
    /// tokenizer + overlap, never a character-count threshold). This variant
    /// is absent from the GLK/MOOTx01 dependency build.
    TokenWindows {
        window_tokens: usize,
        overlap_tokens: usize,
    },
}

/// The operating mode a Corpus is constructed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorpusOperatingMode {
    Standalone,
    Attached,
}

/// Validated (mode, index-unit) configuration — the constructor-time gate
/// that rejects invalid combinations BEFORE anything is written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CorpusContentConfiguration {
    mode: CorpusOperatingMode,
    index_unit: CorpusIndexUnitPolicy,
}

impl CorpusContentConfiguration {
    pub fn new(
        mode: CorpusOperatingMode,
        index_unit: CorpusIndexUnitPolicy,
    ) -> Result<Self, CorpusKitError> {
        #[cfg(feature = "standalone-passages")]
        match (mode, index_unit) {
            (
                CorpusOperatingMode::Attached,
                CorpusIndexUnitPolicy::TokenWindows { .. },
            ) => {
                return Err(CorpusKitError::AttachedModeViolation(
                    "attached mode indexes whole Drawers only — passage configuration \
                     is standalone-only and must be rejected before writing"
                        .into(),
                ));
            }
            (_, CorpusIndexUnitPolicy::TokenWindows { window_tokens, .. })
                if window_tokens == 0 =>
            {
                return Err(CorpusKitError::InvalidConfiguration(
                    "passage windows require a positive token window, got 0".into(),
                ));
            }
            (
                _,
                CorpusIndexUnitPolicy::TokenWindows {
                    window_tokens,
                    overlap_tokens,
                },
            ) if overlap_tokens >= window_tokens => {
                return Err(CorpusKitError::InvalidConfiguration(format!(
                    "passage overlap must be smaller than the window \
                     (window={window_tokens}, overlap={overlap_tokens})"
                )));
            }
            _ => {}
        }
        Ok(CorpusContentConfiguration { mode, index_unit })
    }

    pub fn mode(&self) -> CorpusOperatingMode {
        self.mode
    }

    pub fn index_unit(&self) -> CorpusIndexUnitPolicy {
        self.index_unit
    }

    /// Whether canonical-content mutation (put/remove) is permitted through
    /// CorpusKit. False in attached mode.
    pub fn allows_content_mutation(&self) -> bool {
        self.mode == CorpusOperatingMode::Standalone
    }
}

/// The estate-side inverted-index tables (mirrors Swift
/// `InvertedIndexStore.schemaDeclaration`).
pub fn inverted_index_declaration() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "InvertedIndexStore",
        1,
        vec![
            TableDeclaration::new(
                "iix_termfreqs",
                vec![
                    ColumnDeclaration::text("term"),
                    ColumnDeclaration::text("item_id"),
                    ColumnDeclaration::int("freq"),
                ],
                vec!["term".to_string(), "item_id".to_string()],
            ),
            TableDeclaration::new(
                "iix_doclens",
                vec![
                    ColumnDeclaration::text("item_id"),
                    ColumnDeclaration::int("length"),
                ],
                vec!["item_id".to_string()],
            ),
        ],
    )
    .with_indices(vec![IndexDeclaration::new(
        "idx_iix_tf_item",
        "iix_termfreqs",
        vec!["item_id".to_string()],
    )])
}

/// The standalone passage-range table (declared only when passage
/// indexing is enabled). A passage row is a RANGE over canonical text —
/// it holds no verbatim text.
#[cfg(feature = "standalone-passages")]
pub fn passages_table() -> TableDeclaration {
    TableDeclaration::new(
        "corpus_passages",
        vec![
            ColumnDeclaration::text("passage_id"),
            ColumnDeclaration::text("content_id"),
            ColumnDeclaration::int("revision"),
            ColumnDeclaration::text("digest"),
            ColumnDeclaration::int("utf8_start"),
            ColumnDeclaration::int("utf8_length"),
            ColumnDeclaration::text("policy_fingerprint"),
        ],
        vec!["passage_id".to_string()],
    )
}

/// Table names a profile must NEVER contain in attached mode.
pub fn attached_excluded_tables() -> BTreeSet<&'static str> {
    [
        "chunks",
        "corpus_metadata",
        "corpus_documents",
        "corpus_passages",
        "corpus_index_configuration",
        "removed_sources",
        "corpus_content_changes",
    ]
    .into_iter()
    .collect()
}

fn profile_version(components: &[&SchemaDeclaration]) -> i32 {
    components.iter().map(|c| c.version).sum()
}

/// The standalone profile declaration.
pub fn standalone_declaration(passage_indexing: bool) -> SchemaDeclaration {
    #[cfg(not(feature = "standalone-passages"))]
    assert!(
        !passage_indexing,
        "standalone passage indexing is not compiled in this build"
    );
    let documents = CorpusDocumentStore::schema_declaration();
    let index_state = CorpusIndexStateStore::schema_declaration();
    let coverage =
        crate::provider_coverage_store::CorpusProviderCoverageStore::schema_declaration();
    let configuration =
        crate::provider_configuration_store::CorpusProviderConfigurationStore::schema_declaration();
    let iix = inverted_index_declaration();
    let basis = BasisStore::schema_declaration();
    let counts = CorpusProviderCountsStore::schema_declaration();
    #[cfg(feature = "standalone-passages")]
    let index_configuration =
        crate::index_configuration_store::CorpusIndexConfigurationStore::schema_declaration();

    #[allow(unused_mut)] // mutable only in the standalone-passages build
    let mut components = vec![
        &documents,
        &index_state,
        &coverage,
        &configuration,
        &iix,
        &basis,
        &counts,
    ];
    #[cfg(feature = "standalone-passages")]
    components.push(&index_configuration);
    let version = profile_version(&components);
    let mut tables = Vec::new();
    tables.extend(documents.tables.clone());
    tables.extend(index_state.tables.clone());
    tables.extend(coverage.tables.clone());
    tables.extend(configuration.tables.clone());
    tables.extend(iix.tables.clone());
    tables.extend(basis.tables.clone());
    tables.extend(counts.tables.clone());
    #[cfg(feature = "standalone-passages")]
    tables.extend(index_configuration.tables.clone());
    let mut indices = Vec::new();
    indices.extend(documents.indices.clone());
    indices.extend(index_state.indices.clone());
    indices.extend(iix.indices.clone());
    #[cfg(feature = "standalone-passages")]
    if passage_indexing {
        tables.push(passages_table());
        indices.push(IndexDeclaration::new(
            "idx_corpus_passages_content",
            "corpus_passages",
            vec!["content_id".to_string()],
        ));
    }
    SchemaDeclaration {
        kit_id: "CorpusKitStandalone".to_string(),
        version,
        tables,
        indices,
        migrations: vec![],
    }
}

/// The attached profile declaration: ONLY rebuildable derived state keyed
/// by the canonical content ID. No canonical content table of any kind.
pub fn attached_declaration() -> SchemaDeclaration {
    let index_state = CorpusIndexStateStore::schema_declaration();
    let coverage =
        crate::provider_coverage_store::CorpusProviderCoverageStore::schema_declaration();
    let configuration =
        crate::provider_configuration_store::CorpusProviderConfigurationStore::schema_declaration();
    let iix = inverted_index_declaration();
    let basis = BasisStore::schema_declaration();
    let counts = CorpusProviderCountsStore::schema_declaration();

    let version = profile_version(&[
        &index_state,
        &coverage,
        &configuration,
        &iix,
        &basis,
        &counts,
    ]);
    let mut tables = Vec::new();
    tables.extend(index_state.tables.clone());
    tables.extend(coverage.tables.clone());
    tables.extend(configuration.tables.clone());
    tables.extend(iix.tables.clone());
    tables.extend(basis.tables.clone());
    tables.extend(counts.tables.clone());
    let mut indices = Vec::new();
    indices.extend(index_state.indices.clone());
    indices.extend(iix.indices.clone());
    SchemaDeclaration {
        kit_id: "CorpusKitAttached".to_string(),
        version,
        tables,
        indices,
        migrations: vec![],
    }
}
