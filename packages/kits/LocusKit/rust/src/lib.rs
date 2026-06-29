//! locus-kit — LocusKit Rust port. Spatial memory for one estate.
//!
//! This crate is the Rust parallel of the Swift `LocusKit` Swift Package.
//! It wraps the temporal knowledge-graph layer with the spatial primitives
//! MemPalace exposes: drawers (verbatim content), wings and rooms
//! (metadata-only taxonomy), tunnels (typed cross-references), and diary
//! entries. LocusKit composes on top of GeniusLocusKit; it does not inherit.
//!
//! ## Crate layout (current)
//!
//! Leaf types (landed LP-1A):
//!
//! - `estate_types` — RowID, OwnerCredentials, LatticeAnchor, EstateError
//! - `error` — LocusKitError
//! - `audit_types` — BitmapColumn, AuditActor, AuditRow, BitmapState
//! - `provenance` — SourceType, Channel, CaptureChannel, Confirmation, Confidence, Sensitivity, EnrichmentStatus (cookbook §2.5 v0.6)
//! - `summaries` — WingSummary, RoomSummary
//! - `adjectives` — State, Trust, AdjectiveSensitivity, AdjectiveExportability
//! - `recall_trace_item` — RecallTraceItem
//!
//! Schema and estate spine (landed LP-1B):
//!
//! - `schema` — LocusKitSchema declaration over persistence-kit primitives
//! - `manifest` — ManifestKey enum + ManifestValues snapshot struct
//! - `drawer_store` — DrawerStore trait, the contract every backend conforms to
//! - `estate` — Estate handle (open / create / close + manifest + estate_uuid)
//!
//! Drawer types, validators, and the pruning aggregate store (landed LP-1C):
//!
//! - `drawer` — Drawer struct + provenance accessors
//! - `drawer_operational` — CaptureChannel, ContentKind, DrawerFeatureFlags
//!   bitset constants + Drawer accessors
//! - `drawer_fingerprint` — EstateFingerprintFamilies and drawer fingerprint
//!   derivation via the substrate-lib SimHash machinery
//! - `drawer_state_validator` — thin adapter to substrate_lib::row_state per M1
//!   per spec § 6.2
//! - `forbidden_combination_validator` — I-3 enforcement (secret + exportable)
//! - `container_fingerprint_store` — ContainerFingerprint OR-reduction and
//!   the maintenance / rebuild API over the `container_fingerprints` table
//!
//! Tunnels, KG facts, diary entries, and the bundle algebra (landed LP-1D):
//!
//! - `tunnel` — Tunnel struct mirroring `Tunnel.swift`
//! - `tunnel_operational` — TunnelKind, TunnelDirection, TunnelLifecycle,
//!   TunnelOriginClass, TunnelStrength enums + Tunnel accessors
//! - `kg_fact` — KGFact struct + trust accessor mirroring `KGFact.swift`
//! - `kg_fact_operational` — KGExtractorClass, KGAssertionKind,
//!   KGSpecificity, KGConfidenceBand enums + KGFact accessors
//! - `diary_entry` — DiaryEntry struct mirroring `DiaryEntry.swift`
//! - `diary_operational` — DiaryEventClass, DiarySeverity, DiaryActorClass,
//!   DiaryBatchMembership enums + DiaryEntry accessors
//! - `node_bundle_store` — Per-node count-vector store over persistence-kit
//!   `Storage`, with `BundleKind` and 1024-byte LE-u32 wire encoding
//! - `bundle_materializer` — Materializes Bundle A from an active drawer
//!   slice via `EstateFingerprintFamilies` + a `SubstrateKernel`
//!
//! DrawerStore concrete impls, the bitmap query engine, and the
//! supporting frame / filter types (landed LP-1E + LP-1F SQLite):
//!
//! - `drawer_store` — extended `DrawerStore` trait with the verb-surface
//!   methods (drawer CRUD, supersession cascade, mutation paths,
//!   tunnel / kg-fact / diary CRUD, recall trace, audit reads, summary)
//! - `drawer_store_inmemory` — `DrawerStoreCore` (storage-agnostic verb-logic
//!   core, pub(crate)) + `InMemoryDrawerStore` (public newtype over the
//!   in-memory backend, test fixture, no persistence across process restarts)
//! - `drawer_store_sqlite` — `SqliteDrawerStore` (public newtype over
//!   `DrawerStoreCore` backed by persistence-kit `SqliteStorage`;
//!   WAL-mode, durable across restarts)
//! - `drawer_store_postgres` — `PostgresDrawerStore` (public newtype over
//!   `DrawerStoreCore` backed by persistence-kit `PostgresStorage`;
//!   pooled, durable across restarts, lazy connection)
//! - `bitmap_ops` — § 7.7 bitmap operator primitives (and-mask,
//!   threshold-compare, XOR, shift-extract, SIMD-ballot,
//!   Hamming distance)
//! - `filter` — `Filter` enum + `StateCluster`, `HydrationLevel`,
//!   `Ordering`, `RecallFrame`
//! - `bitmap_evaluator` — `BitmapEvaluator::evaluate(...)` four-tier
//!   pipeline (default insertion → bitmap → structured → content → sort)
//!   with historical XOR-fold reconstruction (§ 6.8) and container
//!   pruning (§ 7.9.4 step 1)
//!
//! ## Composition surface (landed LP-1F)
//!
//! - `frames` — `CaptureFrame`, `MutationKind`, `LearnFrame` verb input
//!   frames
//! - `recall_stream` — synchronous paged cursor (`RecallStream`,
//!   `RecallPage`) over the evaluator's output
//! - `estate_verbs` — Estate verb surface: `capture`, `recall`,
//!   `withdraw`, `mutate`, `expunge`, `reanchor`, and `learn`
//!   (all implemented; `learn` derives a `LearnedReference` from a
//!   `SourceCatalogEntry` and persists it — see estate_verbs.rs § 7.8.2)
//! - `estate_audit` — audit / history methods (`audit_trail`,
//!   `bitmap_state`)
//!
//! The LP-0 vector runner (`tests/lp0_vectors.rs`) exercises the full
//! port end-to-end against the canonical conformance vectors.
//!
//! Three concrete `DrawerStore` implementations ship: `InMemoryDrawerStore`
//! (ephemeral/test fixture), `SqliteDrawerStore` (WAL-mode SQLite, durable),
//! and `PostgresDrawerStore` (pooled PostgreSQL, durable). All three are thin
//! newtypes over `DrawerStoreCore` (the shared verb-logic core), each wrapping
//! the appropriate persistence-kit backend.

pub mod adjectives;
pub mod association;
pub mod association_operational;
pub mod default_wings;
#[cfg(test)]
mod association_tests;
#[cfg(test)]
mod capture_tunnel_tests;
#[cfg(test)]
mod container_fingerprint_coverage_tests;
#[cfg(test)]
mod two_clock_ingest_tests;
#[cfg(test)]
mod capture_into_wing_tests;

pub mod audit_types;
pub mod bitmap_evaluator;
pub mod bitmap_ops;
pub mod bundle_materializer;
pub mod container_fingerprint_store;
pub mod diary_entry;
pub mod diary_operational;
pub mod drawer;
pub mod drawer_fingerprint;
pub mod drawer_operational;
pub mod drawer_state_validator;
pub mod drawer_store;
pub mod drawer_store_inmemory;
pub mod drawer_store_postgres;
pub mod drawer_store_sqlite;
pub mod error;
pub mod estate;
pub mod estate_audit;
pub mod estate_types;
pub mod estate_verbs;
pub mod filter;
pub mod merkle_rollup;
pub mod fingerprint256_adapters;
pub mod forbidden_combination_validator;
pub mod frames;
pub mod kg_fact;
pub mod kg_fact_operational;
pub mod learned_reference;
#[cfg(test)]
mod learned_reference_tests;
pub mod manifest;
pub mod node_bundle_store;
pub mod proposal;
pub mod proposal_operational;
#[cfg(test)]
mod proposal_tests;
pub mod provenance;
#[cfg(test)]
mod reanchor_tests;
pub mod recall_stream;
pub mod recall_trace_item;
pub mod schema;
pub mod source_catalog_entry;
pub mod summaries;
pub mod telemetry;
pub mod node;
pub mod node_store;
pub mod tunnel;
pub mod tunnel_operational;
pub mod vocabulary;
