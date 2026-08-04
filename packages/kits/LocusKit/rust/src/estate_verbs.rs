//! Estate verb surface. Ports `EstateVerbs.swift`.
//!
//! Implements the seven ARIA verbs (`capture`, `recall`, `withdraw`,
//! `expunge`, `mutate`, `reanchor`, `learn`) plus additional estate
//! operations (`capture_batch`, `capture_tunnel`, `seed_wing`,
//! `propose`, `associate`, KG-fact and diary accessors, etc.).
//! `learn` derives a `LearnedReference` from a `SourceCatalogEntry`
//! (spec § 7.8.2). Mirrors the Swift split: `Estate.swift` carries the
//! lifecycle surface; this file carries the verbs.
//!
//! Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 7.8.1.
//!
//! ## Deterministic clock rule
//!
//! `capture`, `recall`, and `withdraw` each take a `now: i64` parameter
//! (epoch seconds). The Swift verbs call `Date()` once at the outermost
//! public boundary and pass it downward; the Rust port threads `now` in
//! explicitly so every method is deterministic and testable without
//! mocking a system clock. Mirrors CLAUDE.md's deterministic-engine rule.
//!
//! ## Rust vs Swift shape differences
//!
//! - Swift `Estate` is an `actor`; Rust `Estate` is a `Clone + Send + Sync`
//!   struct. The concrete `DrawerStore` impl (`DrawerStoreCore`'s internal
//!   `Mutex`) provides the same serialisation guarantee.
//! - `async throws -> T` → `Result<T, LocusKitError>` or plain return.
//! - Swift `recall` is non-throwing and returns a `RecallStream`; the Rust
//!   port mirrors that: a `RecallStream` is returned directly (not wrapped in
//!   `Result`). An internal-read failure does NOT collapse silently — it names
//!   a stage on `RecallStream::degraded_stages` (callers read
//!   `degraded_stages()` to distinguish a FAILED read from a GENUINE-EMPTY
//!   result). See `recall` and spec § 7.8.1 / LOCUSKIT SPEC § 5 B-3.
//! - Swift maintains a `containerFP` OR aggregate for fingerprint pruning
//!   (spec § 11.5). The Rust port wires the same pruning path: when the
//!   filter chain carries a prunable filter, `recall` calls
//!   `DrawerStore::room_level_fingerprints` to enumerate container entries,
//!   prunes with `BitmapEvaluator::container_survives` at both wing and room
//!   level, then fetches rows only from surviving containers via
//!   `DrawerStore::drawers_in_wing_room`. Non-prunable chains take the
//!   bounded corpus scan path (`all_drawers_bounded` /
//!   `all_drawers_bounded_projected`) unchanged. Both paths apply the same
//!   `prefix(scan_bound)` cap so results are identically bounded.

use crate::adjectives::{State, Trust};
use crate::bitmap_evaluator::BitmapEvaluator;
use crate::default_wings::{
    HINT_ADDED_BY, HINT_ROOM, HINT_UDC_CODE,
    DEFAULT_WING_NAME,
};
use crate::drawer::Drawer;
use crate::drawer_operational::DrawerFeatureFlags;
use crate::drawer_store::{SUBJECT_LENGTH_CONTRACT, SUBJECT_PIPELINE_AI_V1};
use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::estate_types::LatticeAnchor;
use crate::frames::TunnelCaptureFrame;
use crate::frames::{AssociateFrame, CaptureFrame, LearnFrame, MutationKind, ProposeFrame};
use crate::provenance::Confirmation;
use crate::recall_stream::RecallStream;
use crate::tunnel::Tunnel;

use crate::filter::{HydrationLevel, RecallFrame};
use crate::recall_trace_item::RecallTraceItem;
use intellectus_lib::{report, EventKind, StatSample};
use uuid::Uuid;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;
use substrate_lib::row_state::RowVerb;

use crate::estate_types::RowID;
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Result of `Estate::get_drawers_matching_frame`: the frame-admissible drawers
/// plus the set of ids whose rows physically loaded.
///
/// `loaded_ids` is reported independently of the frame filter so a caller can
/// gate a drop on load success — see `get_drawers_matching_frame`. Parity peer
/// of Swift `FrameFilteredDrawers` (EstateTypes.swift).
#[derive(Debug, Clone)]
pub struct FrameFilteredDrawers {
    /// Drawers from the requested ids that passed the frame's filter chain
    /// (tombstone exclusion always enforced). Ordered per the frame's ordering.
    pub admissible: Vec<Drawer>,
    /// Every id whose row was returned by storage, regardless of frame filter.
    pub loaded_ids: HashSet<String>,
}

/// Maximum candidate count for the recall locus-lane scan.
///
/// The GLK `RecallDirector` drains at most `min(max(limit * 4, 64), 256)`
/// rows from the recall stream. Capping the estate scan at this value produces
/// the identical drained set as an uncapped scan while doing O(cap) I/O instead
/// of O(estate). Mirrors Swift `Estate.recallCandidateCap`.
pub const RECALL_CANDIDATE_CAP: usize = 256;

/// Stable stage identifiers for recall internal-read failures. Centralised so
/// the strings cannot drift from the Swift port or from
/// `RecallStream::degraded_stages`' documented vocabulary.
pub(crate) mod recall_stage {
    pub const LIVE_ROWS_READ_FAILED: &str = "locus.liveRows.readFailed";
    pub const ROOM_FINGERPRINTS_READ_FAILED: &str = "locus.roomFingerprints.readFailed";
    pub const ROOM_DRAWER_READ_FAILED: &str = "locus.roomDrawerRead.readFailed";
    pub const BITMAP_EVAL_FAILED: &str = "locus.bitmapEval.failed";
    /// The opt-in recall-trace WRITE (`store.insert_recall_traces`) failed.
    /// recall stays non-throwing and STILL returns its rows — the lost trace
    /// is surfaced here so the reward sweep's missing input is observable
    /// rather than silent. Distinct namespace (`recall.`, not `locus.`)
    /// because this is a write-side reward-path fault, not an internal-read
    /// failure that emptied the result. Byte-identical to the Swift
    /// `RecallStage.traceWriteFailed` constant.
    pub const TRACE_WRITE_FAILED: &str = "recall.trace_write_failed";
}

impl Estate {
    // -----------------------------------------------------------------------
    // node-name resolution
    // -----------------------------------------------------------------------

    /// Build a `parent_node_id → (wing_name, room_name)` map for the given
    /// drawers by querying the estate's node tree. Used to supply the
    /// `BitmapEvaluator::evaluate` node_names parameter after drawers lost
    /// their denormalized wing/room fields.
    ///
    /// Returns an empty map when `node_store` is `None` (e.g. legacy estates
    /// opened without a node tree). The bitmap evaluator tolerates missing
    /// entries by treating unresolved drawers as matching no wing/room filter.
    fn resolve_node_names_for_drawers(
        &self,
        drawers: &[Drawer],
    ) -> BTreeMap<String, (String, String)> {
        let node_store = match &self.node_store {
            Some(ns) => ns,
            None => return BTreeMap::new(),
        };
        // Collect unique parent_node_ids.
        let parent_ids: BTreeSet<String> = drawers
            .iter()
            .filter(|d| !d.parent_node_id.is_empty())
            .map(|d| d.parent_node_id.clone())
            .collect();
        if parent_ids.is_empty() {
            return BTreeMap::new();
        }
        // Resolve each room node → (wing_name, room_name).
        let mut result = BTreeMap::new();
        for pid in &parent_ids {
            let room_uuid = match Uuid::parse_str(pid) {
                Ok(u) => u,
                Err(_) => continue,
            };
            let room_node = match node_store.get_node(room_uuid) {
                Ok(Some(n)) => n,
                _ => continue,
            };
            let wing_name = if let Some(wing_uuid) = room_node.parent_id {
                match node_store.get_node(wing_uuid) {
                    Ok(Some(w)) => w.display_name,
                    _ => String::new(),
                }
            } else {
                String::new()
            };
            result.insert(pid.clone(), (wing_name, room_node.display_name));
        }
        result
    }

    // -----------------------------------------------------------------------
    // capture
    // -----------------------------------------------------------------------

    /// File a new drawer into the estate.
    ///
    /// Translates `CaptureFrame` slots into a storage `Drawer` and writes
    /// it via `DrawerStore::add_drawer`. If `frame.lineage_id` is `Some`
    /// and an active predecessor with that lineage exists, the supersession
    /// cascade fires inside `add_drawer` (spec § 6.2 / § 6.3): the new
    /// drawer is captured through the gate (a genesis `AuditEvent`), the
    /// predecessor's 6-bit state field flips to `Superseded` via
    /// `mutate_state(State::Superseded, RowVerb::Supersede)` (which
    /// appends one sealed `AuditEvent`), and a `supersedes` tunnel is
    /// created.
    /// If `frame.lineage_id` is `None`, a fresh UUID is stamped so each
    /// drawer is its own lineage (spec § 5.10).
    ///
    /// # Bitmap assembly
    ///
    /// Operational bitmap (cookbook §2.4 v0.6 layout):
    ///   - bits 0–5:   `capture_channel` (contiguous raw 0..5)
    ///   - bits 6–11:  `content_kind`    (contiguous raw 0..7)
    ///   - bits 12–23: `feature_flags`   (DrawerFeatureFlags bitset, pre-shifted)
    ///
    /// Adjective bitmap:
    ///   - bits 0–5:  state — default 0 (`Active`)
    ///   - bits 6–11: adjective_sensitivity (scale-gapped raw 0/16/32/48,
    ///     packed via `bit_field::write_field` into bits 6–11)
    ///
    /// Per `DrawerOperational.swift` / spec § 5.6 and § 5.5.
    ///
    /// # Errors
    ///
    /// Returns `LocusKitError::InvalidContent` when any of `frame.content`,
    /// `frame.room`, `frame.lattice_anchor.udc_code`, `frame.added_by`, or
    /// `frame.embedding_model_id` is empty. The UDC requirement is
    /// invariant I-5.
    pub fn capture(&self, frame: CaptureFrame, now: i64) -> Result<Drawer, LocusKitError> {
        // Validate all required fields per spec I-5 and the capture contract.
        if frame.content.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "content must not be empty".to_string(),
            ));
        }
        if frame.room.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "room must not be empty".to_string(),
            ));
        }
        if frame.lattice_anchor.udc_code.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "latticeAnchor.udcCode must not be empty (spec I-5)".to_string(),
            ));
        }
        if frame.added_by.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "addedBy must not be empty".to_string(),
            ));
        }
        if frame.embedding_model_id.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "embeddingModelID must not be empty".to_string(),
            ));
        }
        // Subject length contract (SPEC B-18) checked at the frame boundary
        // so the error surfaces before any row exists. Empty-string subjects
        // are rejected the same way — a caller with no subject passes None
        // (subject debt, B-21), never "". Mirrors Swift capture().
        if let Some(ref subject) = frame.subject {
            let n = subject.chars().count();
            if n == 0 || n > SUBJECT_LENGTH_CONTRACT {
                return Err(LocusKitError::InvalidContent(format!(
                    "subject must be 1–{SUBJECT_LENGTH_CONTRACT} characters (got {n}); \
                     omit it entirely to file as subject debt"
                )));
            }
        }

        // Operational bitmap assembly (cookbook §2.4 v0.6 layout):
        //   bits 0–5   capture_channel (contiguous raw 0..5)
        //   bits 6–11  content_kind    (contiguous raw 0..7)
        //   bits 12–23 feature_flags   (DrawerFeatureFlags bitset)
        // Per DrawerOperational.swift / spec § 5.6.
        //
        // DrawerFeatureFlags constants are pre-shifted (e.g. HAS_LINKS = 1<<15),
        // so the merge is a direct OR masked to FIELD_MASK (0xFFF000) — the
        // inverse of the `feature_flags()` accessor's `& FIELD_MASK` decoder.
        let op_bitmap = bit_field::write_field(
            frame.kind.raw_value(),
            bit_field::write_field(frame.channel.raw_value(), 0, 0, 6),
            6,
            6,
        ) | (frame.feature_flags & DrawerFeatureFlags::FIELD_MASK);

        // Adjective bitmap assembly (cookbook §2.3 v0.6 layout):
        //   bits 0–5   state                 (default 0 = Active)
        //   bits 6–11  adjective_sensitivity (scale-gapped raw 0/16/32/48)
        //   bits 12–17 exportability         (scale-gapped raw 0 = Private, 32 = Public)
        //   bits 18–23 trust                 (default 0 = Verbatim)
        // Sensitivity and exportability both use scale-gapped raw values;
        // each is written into its 6-bit window via write_field, which
        // masks the value to the window width before placing it.
        // Per adjectives.rs / cookbook §2.3.
        let adj_bitmap = bit_field::write_field(
            frame.exportability.raw_value(),
            bit_field::write_field(frame.sensitivity.raw_value(), 0, 6, 6),
            12,
            6,
        );

        // Provenance bitmap assembly (cookbook §2.5 layout):
        //   bits 0–5   source_type           (SourceType raw)
        //   bits 6–11  channel               (provenance Channel raw)
        //   bits 18–23 confirmation          (Confirmation raw)
        //   bits 24–29 confidence            (Confidence raw, scale-gapped)
        //   bits 30–35 sensitivity           (provenance Sensitivity raw)
        // confirmation and confidence default to raw 0 (Unconfirmed / Null),
        // so a caller that omits them produces the same bytes as before these
        // slots existed; a daemon capturing with known review status or a known
        // confidence band records it at birth. The remaining provenance slots
        // (capture_channel mirror, enrichment_status) are populated by
        // downstream daemons or held at zero by default. Mirrors EstateVerbs.swift.
        let provenance_bitmap = bit_field::write_field(
            frame.provenance_sensitivity.raw_value(),
            bit_field::write_field(
                frame.confidence.raw_value(),
                bit_field::write_field(
                    frame.confirmation.raw_value(),
                    bit_field::write_field(
                        frame.provenance_channel.raw_value(),
                        bit_field::write_field(frame.source_type.raw_value(), 0, 0, 6),
                        6,
                        6,
                    ),
                    18,
                    6,
                ),
                24,
                6,
            ),
            30,
            6,
        );

        // resolve wing/room display names to node IDs via
        // NodeStore's create-on-demand resolution. The root must exist
        // (seeded at provision time); wing and room nodes are created
        // if absent, returned if already present.
        let wing_name = frame
            .wing
            .clone()
            .unwrap_or_else(|| DEFAULT_WING_NAME.to_string());
        let room_name = frame.room.clone();

        let node_store = self.node_store.as_ref().ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "capture: NodeStore not available — estate not fully initialized".to_string(),
            )
        })?;
        let root = node_store.root_node()?.ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "capture: estate root node not found — estate not provisioned".to_string(),
            )
        })?;
        let wing_node = node_store.create_node(&wing_name, root.id, now)?;
        let room_node = node_store.create_node(&room_name, wing_node.id, now)?;

        // Stamp a lineage id: use the caller's if provided, otherwise fresh.
        let lineage_id = frame.lineage_id.unwrap_or_else(Uuid::new_v4);

        let drawer_id = Uuid::new_v4().to_string();
        let mut drawer = Drawer::new(
            drawer_id,
            frame.content,
            room_node.id.to_string(),
            frame.added_by,
            now,
            frame.embedding_model_id,
        );
        drawer.adjective_bitmap = adj_bitmap;
        drawer.operational_bitmap = op_bitmap;
        drawer.provenance = provenance_bitmap;
        drawer.lineage_id = lineage_id;
        drawer.udc_code = frame.lattice_anchor.udc_code;
        drawer.udc_facets = frame.lattice_anchor.udc_facets;
        drawer.wikidata_qid = frame.lattice_anchor.wikidata_qid;
        drawer.wikidata_qids_secondary = frame.lattice_anchor.wikidata_qids_secondary;
        // Two-clock ingest (ING-01): caller-supplied event time for bulk
        // historical ingestion; streaming capture defaults to now. Resolves
        // eagerly: CaptureFrame.event_time is Option (legitimately optional
        // input frame), but Drawer.event_time is non-optional — fold here.
        drawer.event_time = frame.event_time.unwrap_or(now);
        // Subject trio at birth (SPEC § 14). The producer at the capture
        // boundary is the calling AI, so the pipeline version is ai-v1; a
        // None frame subject leaves the whole trio NULL (debt, B-21).
        // Mirrors the Swift capture() translation.
        if let Some(subject) = frame.subject {
            drawer.subject = Some(subject);
            drawer.subject_pipeline_version = Some(SUBJECT_PIPELINE_AI_V1.to_string());
            drawer.subject_at = Some(now);
        }

        // add_drawer atomically maintains the per-container OR aggregate
        // (spec § 11.5 Option B): coverage is now structurally guaranteed
        // inside the DrawerStore implementation — no separate
        // or_in_container_fingerprint call is needed or correct here.
        // The clear-side (withdraw / bit-off) is intentionally a no-op.
        self.store.add_drawer(&drawer, now)?;
        // NT-L3: the Merkle rollup is NOT done inline here — doing it per drawer
        // is O(room) per write → O(N²) for a bulk import and pegs the CPU on the
        // write path. The rollup is deferred and rides the estate's QueueKit work
        // queue: streaming captures (capture_with_mode Regular) enqueue an encode
        // job, and the encode drain worker rolls up the touched rooms off-path
        // (coalesced); bulk-import paths defer to the O(N) full-tree pass in
        // `reindex_missing` (rollup_all_merkle_roots). Same mechanism as encode.
        // Emit a Capture event for the new drawer. NounType::Drawer = 0 (wire-stable,
        // matches SubstrateTypes/NounType.swift). The report!() macro is a no-op when
        // no sink is installed, so this is zero-cost in stdio/test mode.
        report!(StatSample::event(
            EventKind::Capture,
            0i64,
            drawer.id.clone(),
            self.estate_uuid().to_string(),
            now as f64,
        ));
        Ok(drawer)
    }

    // -----------------------------------------------------------------------
    // capture_batch
    // -----------------------------------------------------------------------

    /// Capture a batch of drawers without triggering per-drawer Merkle rollup.
    ///
    /// Intended for bulk-import paths (e.g. `moot_palace_import`) where calling
    /// `rollup_merkle_roots` after every drawer write produces O(N²) recomputation
    /// work. Callers MUST call `rollup_all_merkle_roots(now)` — or trigger
    /// `reindex_missing` (which calls it) — after the batch.
    ///
    /// Each frame passes the same validation guards as the single-drawer `capture` verb.
    ///
    /// # Arguments
    /// * `frames` - Capture frames to store.
    /// * `now` - Epoch-seconds wall-clock passed to store write operations.
    pub fn capture_batch(
        &self,
        frames: Vec<CaptureFrame>,
        now: i64,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        let node_store = self.node_store.as_ref().ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "capture_batch: NodeStore not available — estate not fully initialized".to_string(),
            )
        })?;
        let root = node_store.root_node()?.ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "capture_batch: estate root node not found — estate not provisioned".to_string(),
            )
        })?;

        let mut drawers = Vec::with_capacity(frames.len());
        // Node cache: avoids N redundant create_node round-trips for frames that
        // share a wing/room (common in bulk import where all content lands in one
        // room). Key = "wingName\0roomName" (null separator avoids collision).
        let mut room_node_cache: std::collections::HashMap<String, crate::node::Node> =
            std::collections::HashMap::new();

        for frame in frames {
            // Validate all required fields (same contract as capture).
            if frame.content.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "content must not be empty".to_string(),
                ));
            }
            if frame.room.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "room must not be empty".to_string(),
                ));
            }
            if frame.lattice_anchor.udc_code.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "latticeAnchor.udcCode must not be empty (spec I-5)".to_string(),
                ));
            }
            if frame.added_by.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "addedBy must not be empty".to_string(),
                ));
            }
            if frame.embedding_model_id.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "embeddingModelID must not be empty".to_string(),
                ));
            }
            // Same subject contract as capture() (SPEC B-18): 1–120 chars
            // when present; None files as subject debt (B-21).
            if let Some(ref subject) = frame.subject {
                let n = subject.chars().count();
                if n == 0 || n > SUBJECT_LENGTH_CONTRACT {
                    return Err(LocusKitError::InvalidContent(format!(
                        "subject must be 1–{SUBJECT_LENGTH_CONTRACT} characters (got {n}); \
                         omit it entirely to file as subject debt"
                    )));
                }
            }

            // Bitmap assembly (same layout as capture verb, spec §§ 5.6 / 2.3 / 2.5).
            let op_bitmap = bit_field::write_field(
                frame.kind.raw_value(),
                bit_field::write_field(frame.channel.raw_value(), 0, 0, 6),
                6,
                6,
            ) | (frame.feature_flags & DrawerFeatureFlags::FIELD_MASK);

            let adj_bitmap = bit_field::write_field(
                frame.exportability.raw_value(),
                bit_field::write_field(frame.sensitivity.raw_value(), 0, 6, 6),
                12,
                6,
            );

            let provenance_bitmap = bit_field::write_field(
                frame.provenance_sensitivity.raw_value(),
                bit_field::write_field(
                    frame.confidence.raw_value(),
                    bit_field::write_field(
                        frame.confirmation.raw_value(),
                        bit_field::write_field(
                            frame.provenance_channel.raw_value(),
                            bit_field::write_field(frame.source_type.raw_value(), 0, 0, 6),
                            6,
                            6,
                        ),
                        18,
                        6,
                    ),
                    24,
                    6,
                ),
                30,
                6,
            );

            // Resolve wing/room nodes; create_node is create-on-demand (idempotent).
            let wing_name = frame
                .wing
                .clone()
                .unwrap_or_else(|| DEFAULT_WING_NAME.to_string());
            let room_name = frame.room.clone();
            let cache_key = format!("{}\0{}", wing_name, room_name);
            let room_node = if let Some(cached) = room_node_cache.get(&cache_key) {
                cached.clone()
            } else {
                let wing_node = node_store.create_node(&wing_name, root.id, now)?;
                let fresh = node_store.create_node(&room_name, wing_node.id, now)?;
                room_node_cache.insert(cache_key, fresh.clone());
                fresh
            };

            let lineage_id = frame.lineage_id.unwrap_or_else(Uuid::new_v4);
            let drawer_id = Uuid::new_v4().to_string();
            let mut drawer = Drawer::new(
                drawer_id,
                frame.content,
                room_node.id.to_string(),
                frame.added_by,
                now,
                frame.embedding_model_id,
            );
            drawer.adjective_bitmap = adj_bitmap;
            drawer.operational_bitmap = op_bitmap;
            drawer.provenance = provenance_bitmap;
            drawer.lineage_id = lineage_id;
            drawer.udc_code = frame.lattice_anchor.udc_code;
            drawer.udc_facets = frame.lattice_anchor.udc_facets;
            drawer.wikidata_qid = frame.lattice_anchor.wikidata_qid;
            drawer.wikidata_qids_secondary = frame.lattice_anchor.wikidata_qids_secondary;
            // Subject trio at birth — identical translation to capture().
            if let Some(subject) = frame.subject {
                drawer.subject = Some(subject);
                drawer.subject_pipeline_version = Some(SUBJECT_PIPELINE_AI_V1.to_string());
                drawer.subject_at = Some(now);
            }
            drawer.event_time = frame.event_time.unwrap_or(now);

            // Store drawer. Unlike capture, rollup_merkle_roots is deliberately omitted —
            // that O(N²) call is the root cause of the moot_palace_import hang (NT_R1).
            // The deferred full-tree pass (rollup_all_merkle_roots) must be called after
            // the batch. DrawerStore.add_drawer maintains the container FP aggregate
            // internally (spec § 11.5 Option B), so no separate or_in call is needed.
            self.store.add_drawer(&drawer, now)?;

            drawers.push(drawer);
        }
        Ok(drawers)
    }

    // -----------------------------------------------------------------------
    // seed_wing
    // -----------------------------------------------------------------------

    /// Seed a named wing by writing a hint memory into the `AI_Charter_Hint` room.
    ///
    /// wing organization / node-tree integrity: wings are node rows in the `nodes` table.
    /// `seed_wing` resolves `wing_name` to a wing node (create-on-demand
    /// via NodeStore) and files the hint drawer under it. Other capture
    /// paths resolve wing via `CaptureFrame.wing`, falling back to
    /// `DEFAULT_WING_NAME` when no wing is supplied.
    ///
    /// `seed_wing` routes through `DrawerStore::add_drawer` (the same
    /// structural chokepoint as `capture`) so the container fingerprint OR
    /// aggregate is maintained. The hint drawer is filed with:
    /// - `wing`: the supplied `wing_name`
    /// - `room`: `HINT_ROOM` ("AI_Charter_Hint")
    /// - `added_by`: `HINT_ADDED_BY` ("estate-provision") — honest provenance only
    /// - `embedding_model_id`: the caller-supplied model id (normal embedding)
    /// - `lattice_anchor`: UDC "001" (Knowledge class — spec I-5)
    ///
    /// `seed_wing` performs the covered ROW write only; the GLK caller
    /// enqueues the hint onto the Corpus encode stream
    /// (`seed_default_wings`, DISTILL_SEED_STALL), which is what delivers
    /// BM25/vector indexing and drain-stage distillation for the hints.
    ///
    /// Idempotent at the business level: re-seeding an already-seeded wing
    /// adds a second hint drawer, but the seven default wings are seeded
    /// exactly once at `provision`. GeniusLocusKit's seed loop is the only
    /// caller in production.
    ///
    /// Returns an error if `wing_name` is empty (same guard as Swift
    /// `seedWing` in `EstateVerbs.swift`).
    ///
    /// Mirrors Swift `Estate.seedWing(_:hint:addedBy:embeddingModelID:now:)`.
    pub fn seed_wing(
        &self,
        wing_name: &str,
        hint: &str,
        embedding_model_id: &str,
        now: i64,
    ) -> Result<Drawer, LocusKitError> {
        if wing_name.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "seed_wing: wing_name must not be empty".to_string(),
            ));
        }
        // resolve wing/room to node IDs via NodeStore's
        // create-on-demand resolution, same as the capture verb.
        let node_store = self.node_store.as_ref().ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "seed_wing: NodeStore not available — estate not fully initialized".to_string(),
            )
        })?;
        let root = node_store.root_node()?.ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "seed_wing: estate root node not found — estate not provisioned".to_string(),
            )
        })?;
        let wing_node = node_store.create_node(wing_name, root.id, now)?;
        let room_node = node_store.create_node(HINT_ROOM, wing_node.id, now)?;

        let drawer_id = Uuid::new_v4().to_string();
        let lattice_anchor = LatticeAnchor::udc(HINT_UDC_CODE);
        let mut drawer = Drawer::new(
            drawer_id,
            hint.to_string(),
            room_node.id.to_string(),
            HINT_ADDED_BY.to_string(),
            now,
            embedding_model_id.to_string(),
        );
        drawer.udc_code = lattice_anchor.udc_code;
        drawer.udc_facets = lattice_anchor.udc_facets;
        // Structural seeds emit their own subject (SPEC § 14): a hint drawer
        // exists in EVERY estate, so a NULL subject here would be permanent,
        // unpayable debt in every debt count. Deterministic — the wing name
        // states exactly what the hint asserts. Distinct pipeline tag so a
        // regeneration sweep can target seeds. Mirrors Swift seedWing.
        drawer.subject = Some(
            format!("Charter hint: how to use the {wing_name} wing.")
                .chars()
                .take(SUBJECT_LENGTH_CONTRACT)
                .collect(),
        );
        drawer.subject_pipeline_version = Some("seed-v1".to_string());
        drawer.subject_at = Some(now);
        // add_drawer maintains the container fingerprint OR aggregate
        // (spec § 11.5), identical to the capture path. No separate
        // fingerprint call needed — coverage is structurally guaranteed.
        self.store.add_drawer(&drawer, now)?;
        Ok(drawer)
    }

    // -----------------------------------------------------------------------
    // capture (tunnel)
    // -----------------------------------------------------------------------

    /// File a new standalone **tunnel** (graph edge) into the estate.
    ///
    /// `capture` is legal on exactly two nouns — drawer and tunnel. Swift
    /// overloads `capture` on the frame type; Rust cannot overload, so the
    /// tunnel entry point is `capture_tunnel`.
    ///
    /// Byte-identical to the row the supersession cascade writes
    /// (`add_drawer_with_cascade`): builds a `Tunnel` with the same all-zero
    /// bitmap defaults and files it through `DrawerStore::add_tunnel`, a bare
    /// row insert — exactly what the cascade does for its `supersedes`
    /// tunnel. One tunnel shape, two entry points (mission VERB-CAP-01).
    ///
    /// # Genesis-event treatment
    ///
    /// Drawer capture emits a gated genesis `AuditEvent` (`gated_capture` →
    /// `audit_gate::admit`). The supersession cascade does **not** emit such
    /// an event for the tunnel it files — it inserts the tunnel row directly,
    /// and `add_tunnel` does the same. Source is ground truth: to stay
    /// byte-identical to what the cascade produces, standalone tunnel capture
    /// matches the cascade and files via the bare-insert `add_tunnel`. (Doc/
    /// source drift noted in the completion report.)
    ///
    /// `now` (epoch seconds) is threaded in per the deterministic-clock rule.
    ///
    /// # Errors
    ///
    /// Returns `LocusKitError::InvalidContent` when either endpoint's
    /// `wing`/`room`, or `label`, or `added_by` is empty.
    pub fn capture_tunnel(
        &self,
        frame: TunnelCaptureFrame,
        now: i64,
    ) -> Result<Tunnel, LocusKitError> {
        if frame.source_wing.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "sourceWing must not be empty".to_string(),
            ));
        }
        if frame.source_room.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "sourceRoom must not be empty".to_string(),
            ));
        }
        if frame.target_wing.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "targetWing must not be empty".to_string(),
            ));
        }
        if frame.target_room.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "targetRoom must not be empty".to_string(),
            ));
        }
        if frame.label.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "label must not be empty".to_string(),
            ));
        }
        if frame.added_by.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "addedBy must not be empty".to_string(),
            ));
        }

        // Encode origin_class into bits 6–8 and lifecycle into bits 3–5 of
        // the tunnel operational bitmap. The decoders (`Tunnel::origin_class()`
        // / `Tunnel::lifecycle()` in `tunnel_operational.rs`) use
        // `bit_field::extract_field` with the same shift/width, so these
        // writes are the exact inverse. Defaults (`UserExplicit`, `Active` —
        // both raw 0) produce 0, preserving byte-identical all-zero defaults
        // for existing callers (spec § 5.6 / cookbook §2.4).
        let op_bitmap = bit_field::write_field(
            frame.lifecycle.raw_value(),
            bit_field::write_field(frame.origin_class.raw_value(), 0, 6, 3),
            3,
            3,
        );
        let mut tunnel = Tunnel::new(
            Uuid::new_v4().to_string(),
            frame.source_wing,
            frame.source_room,
            frame.target_wing,
            frame.target_room,
            frame.label,
            frame.added_by,
            now,
        );
        tunnel.kind = frame.kind;
        tunnel.source_drawer_id = frame.source_drawer_id.clone();
        tunnel.target_drawer_id = frame.target_drawer_id.clone();
        tunnel.operational_bitmap = op_bitmap;
        // Sensitivity ceiling (#57): a tunnel inherits the highest
        // sensitivity of its two endpoints so filtering one endpoint
        // automatically hides the tunnel. Look up both endpoint drawers
        // (when drawer-level — None means room-level, sensitivity = Normal).
        let endpoint_ids: Vec<&str> = [&frame.source_drawer_id, &frame.target_drawer_id]
            .iter()
            .filter_map(|opt| opt.as_deref())
            .collect();
        if !endpoint_ids.is_empty() {
            let mut max_sens: u8 = 0; // Normal = 0
            for eid in &endpoint_ids {
                if let Some(d) = self.store.get_drawer(eid)? {
                    let s = bit_field::extract_field(d.adjective_bitmap, 6, 6) as u8;
                    if s > max_sens { max_sens = s; }
                }
            }
            // Write max sensitivity into bits 6–11 of adjectiveBitmap
            // (cookbook §2.3, same layout as drawers).
            tunnel.adjective_bitmap = bit_field::write_field(max_sens as i64, tunnel.adjective_bitmap, 6, 6);
        }
        self.store.add_tunnel(&tunnel)?;
        // Emit a Capture event for the new tunnel. NounType::Tunnel = 1 (wire-stable,
        // matches SubstrateTypes/NounType.swift).
        report!(StatSample::event(
            EventKind::Capture,
            1i64,
            tunnel.id.clone(),
            self.estate_uuid().to_string(),
            now as f64,
        ));
        Ok(tunnel)
    }

    // -----------------------------------------------------------------------
    // recall
    // -----------------------------------------------------------------------

    /// Recall rows matching the filter chain. Per spec § 7.8.1 / § 7.9.
    ///
    /// Fetches the non-tombstoned drawer set (`tombstoned_at == None`)
    /// from the substrate and hands it to `BitmapEvaluator::evaluate`,
    /// which applies default-filter insertion (§ 7.9.5), bitmap-tier
    /// predicates (§ 7.9.2 / § 7.9.3), structured-tier filters
    /// (§ 7.9.4 step 3), content-tier filters (§ 7.9.4 step 4),
    /// ordering, and historical reconstruction (§ 7.9.6).
    ///
    /// This method is **non-throwing** (matching Swift semantics): an
    /// internal-read failure (the bounded scan, room-fingerprint enumeration,
    /// a surviving room's drawer read, or the bitmap evaluator) is SURFACED as
    /// a named stage on `RecallStream::degraded_stages` rather than collapsing
    /// to a genuine-looking empty result. A GENUINE-EMPTY estate (every read
    /// succeeded, no rows matched) returns an empty stream with EMPTY
    /// `degraded_stages`; a FAILED read returns an empty (or short) stream with
    /// the failing stage named — so the two are distinguishable. Callers that
    /// need the rows behind a fault go through the substrate directly; callers
    /// that need only to tell failed-from-empty read `degraded_stages()`.
    /// Spec § 7.8.1 / LOCUSKIT SPEC § 5 B-3.
    ///
    /// Trace rows are written only when the caller opts in via
    /// `frame.trace_limit`. `None` (the default) writes ZERO trace rows —
    /// internal scans, VaultBridge scans, and any other non-reward caller do
    /// not participate in the reward cycle. `Some(n)` writes at most the first
    /// `min(n, filtered.len())` surfaced rows: the "later two-source reward"
    /// hook from NEURONKIT_SPEC § 3.1, where the reward path later sets
    /// `used = true` for rows the caller acted on. Trace insertion failures are
    /// silenced so a storage fault does not break the caller's result.
    ///
    /// `now` is stamped once at the verb boundary per the
    /// deterministic-clock rule (CLAUDE.md). The trace rows record
    /// `recalled_at` so the reward sweep can group rows by recall session.
    pub fn recall(&self, frame: RecallFrame, now: i64) -> RecallStream {
        // ----------------------------------------------------------------
        // Bounded scan, no-blob projection, opt-in trace. Mirrors Swift
        // EstateVerbs.recall / liveRows.
        //
        // Scan bound: max(frame.limit.unwrap_or(0), RECALL_CANDIDATE_CAP).
        // Director-style callers (limit ~20) keep the 256-row floor; explicit
        // large-limit callers (e.g. VaultBridge limit 10_000_000) get a true
        // full scan so no drawer is silently truncated. The 256 cap alone was
        // a data-integrity bug: limit > 256 truncated to 256, so a full-estate
        // scan missed drawers #257+.
        //
        // No-blob projection: when the filter chain has no content-tier
        // predicate AND the caller does not need the blob (hydration != Full),
        // the scan projects away the content column via
        // all_drawers_bounded_projected, so a `.structured` caller receives
        // content == "" (spec § 7.3) without paying the blob I/O — exactly the
        // Swift `.structured` projection. A content predicate or a `.full`
        // caller uses the blob-loading scan so the substring match can run and
        // `.full` callers receive real content.
        //
        // Opt-in trace: written only when frame.trace_limit is Some(n), bounded
        // to min(n, filtered.len()) surfaced rows. One batch insert.
        // ----------------------------------------------------------------

        let scan_bound = frame.limit.unwrap_or(0).max(RECALL_CANDIDATE_CAP);

        // Internal-read failures are SURFACED on the stream's degraded_stages,
        // not silently swallowed to an empty result. A failed read produces an
        // empty candidate set for a reason OTHER than "no matches"; recording
        // the named stage lets the GLK consumer tell a FAILED recall from a
        // GENUINE-EMPTY estate (spec § 7.8.1). `recall` stays non-throwing.
        let mut degraded_stages: Vec<String> = Vec::new();

        // Consume the single-use fault seam once at the top (test/test-seams
        // builds only). `forced` is always `None` in a production build.
        #[cfg(any(test, feature = "test-seams"))]
        let forced = self.take_test_force_internal_read_error();
        #[cfg(not(any(test, feature = "test-seams")))]
        let forced: Option<()> = None;
        // Per-read forced-fault predicates. In production `forced` is `()`-typed
        // and these are always false, so the optimizer drops the branches.
        #[cfg(any(test, feature = "test-seams"))]
        let force_live_rows = forced == Some(crate::estate::RecallInternalRead::LiveRows);
        #[cfg(any(test, feature = "test-seams"))]
        let force_room_fingerprints =
            forced == Some(crate::estate::RecallInternalRead::RoomFingerprints);
        #[cfg(any(test, feature = "test-seams"))]
        let force_room_drawer = forced == Some(crate::estate::RecallInternalRead::RoomDrawerRead);
        #[cfg(any(test, feature = "test-seams"))]
        let force_bitmap_eval = forced == Some(crate::estate::RecallInternalRead::BitmapEval);
        // Trace-WRITE fault: fires AFTER reads + eval succeed, so a forced
        // `.traceWrite` yields a populated result WITH the
        // `recall.trace_write_failed` stage (recall stays non-throwing).
        #[cfg(any(test, feature = "test-seams"))]
        let force_trace_write = forced == Some(crate::estate::RecallInternalRead::TraceWrite);
        #[cfg(not(any(test, feature = "test-seams")))]
        let (
            force_live_rows,
            force_room_fingerprints,
            force_room_drawer,
            force_bitmap_eval,
            force_trace_write,
        ) = {
            let _ = forced;
            (false, false, false, false, false)
        };

        // The blob is needed when a content predicate must run the substring
        // match (needs the body for the filter pass) or when the caller asked
        // for Full hydration (wants the body in the result). Otherwise the
        // no-blob projected scan is sufficient and correct.
        let needs_content_for_filter =
            BitmapEvaluator::chain_has_content_predicate(&frame.filter_chain);
        let caller_needs_blob = frame.hydration_level == HydrationLevel::Full;

        let candidates: Vec<Drawer> =
            if BitmapEvaluator::chain_has_prunable_filter(&frame.filter_chain) {
                // Fingerprint-pruning path: walk surviving rooms and fetch their
                // rows, mirroring Swift EstateVerbs.liveRows (spec § 7.9.4 step 1).
                //
                // 1. Enumerate room-level container fingerprints.
                // 2. For each room, check the wing-level rollup first (cached in a
                //    local map). If the wing rollup fails `container_survives` the
                //    entire wing is skipped without fetching individual rooms.
                // 3. If the wing survives, check the room fingerprint. Only rooms
                //    that survive fetch their drawers via `drawers_in_wing_room`.
                // 4. Apply `prefix(scan_bound)` after collection so both paths emit
                //    at most `scan_bound` rows — identical bound semantics to the
                //    non-pruning path.
                //
                // `drawers_in_wing_room` already excludes tombstoned rows (same as
                // Swift `store.drawersIn(wing:room:)`), so no post-filter is needed.
                //
                // Note on hydration: `drawers_in_wing_room` always loads full rows
                // (content included). For .structured and .bitmapOnly callers the
                // blob is loaded unnecessarily, but the pruning path visits only
                // surviving rooms — typically a small fraction of the estate — so
                // the dominant cost is the SQL scan, not the blob transfer.
                // Room-fingerprint enumeration. A failure here means the pruning
                // path cannot decide which rooms survive — surface it as a named
                // stage rather than silently scanning nothing.
                let entries = if force_room_fingerprints {
                    degraded_stages.push(recall_stage::ROOM_FINGERPRINTS_READ_FAILED.to_string());
                    Vec::new()
                } else {
                    match self.store.room_level_fingerprints() {
                        Ok(e) => e,
                        Err(_) => {
                            degraded_stages
                                .push(recall_stage::ROOM_FINGERPRINTS_READ_FAILED.to_string());
                            Vec::new()
                        }
                    }
                };

                // Cache wing-level survive decisions so each wing is checked once.
                // Keyed by wing name; value is true if the wing rollup survives.
                let mut wing_survives: std::collections::HashMap<String, bool> =
                    std::collections::HashMap::new();

                let mut rows: Vec<Drawer> = Vec::new();
                for entry in &entries {
                    // Wing-level pre-check: fetch the wing rollup (room == "")
                    // and test it. Cache the decision to avoid re-querying for
                    // subsequent rooms in the same wing.
                    let wing_ok = wing_survives
                        .entry(entry.wing.clone())
                        .or_insert_with(|| {
                            // get() returns None when no wing rollup row exists
                            // yet (possible on an estate that never called
                            // or_in/rebuild). None → treat as surviving (sound:
                            // absent aggregate must not prune, per spec § 11.5).
                            match self.store.get_container_fingerprint(
                                &entry.wing,
                                crate::container_fingerprint_store::ContainerFingerprintStore::WING_ROLLUP_ROOM,
                            ) {
                                Ok(Some(fp)) => BitmapEvaluator::container_survives(
                                    &frame.filter_chain,
                                    fp,
                                ),
                                _ => true,
                            }
                        });
                    if !*wing_ok {
                        continue;
                    }
                    // Room-level check.
                    if !BitmapEvaluator::container_survives(&frame.filter_chain, entry.fingerprint)
                    {
                        continue;
                    }
                    // Surviving room: fetch its non-tombstoned drawers. A failure
                    // here means a room that SHOULD contribute rows silently
                    // contributed none — surface it as a named stage instead of
                    // returning a short result that looks like a genuine match set.
                    let room_drawers = if force_room_drawer {
                        if !degraded_stages
                            .iter()
                            .any(|s| s == recall_stage::ROOM_DRAWER_READ_FAILED)
                        {
                            degraded_stages
                                .push(recall_stage::ROOM_DRAWER_READ_FAILED.to_string());
                        }
                        Vec::new()
                    } else {
                        match self.store.drawers_in_wing_room(&entry.wing, &entry.room) {
                            Ok(d) => d,
                            Err(_) => {
                                if !degraded_stages
                                    .iter()
                                    .any(|s| s == recall_stage::ROOM_DRAWER_READ_FAILED)
                                {
                                    degraded_stages.push(
                                        recall_stage::ROOM_DRAWER_READ_FAILED.to_string(),
                                    );
                                }
                                Vec::new()
                            }
                        }
                    };
                    rows.extend(room_drawers);
                }
                // Apply bound after collection: both paths emit at most scan_bound rows.
                rows.into_iter().take(scan_bound).collect()
            } else {
                // No pruning possible: bounded corpus scan in filed_at order.
                // Uses no-blob projection when safe (no content predicate AND
                // caller does not need the blob), matching Swift's no-blob path.
                // A scan failure is surfaced as the live-rows stage rather than
                // masquerading as a genuine-empty corpus.
                if force_live_rows {
                    degraded_stages.push(recall_stage::LIVE_ROWS_READ_FAILED.to_string());
                    Vec::new()
                } else {
                    // P4-secfix: use DESC-ordered bounded scan so the cap
                    // selects the NEWEST drawers rather than the oldest.
                    // With ASC ordering and a 256-row cap, any drawer filed
                    // after the 256th-oldest was permanently invisible to
                    // Director-style callers. DESC ordering guarantees the
                    // cap window covers the most-recently-filed content.
                    let scanned = if needs_content_for_filter || caller_needs_blob {
                        self.store.all_drawers_bounded_desc(Some(scan_bound))
                    } else {
                        self.store.all_drawers_bounded_projected_desc(Some(scan_bound))
                    };
                    match scanned {
                        Ok(rows) => rows
                            .into_iter()
                            .filter(|d| d.tombstoned_at.is_none())
                            .collect(),
                        Err(_) => {
                            degraded_stages.push(recall_stage::LIVE_ROWS_READ_FAILED.to_string());
                            Vec::new()
                        }
                    }
                }
            };

        // Hint memories (seeded at provision in AI_Charter_Hint room) are normal
        // drawers — embedded and recallable like any other drawer. No filter here.

        // Run the four-tier bitmap evaluator pipeline. A failure is SURFACED as
        // a named degraded stage rather than masquerading as a genuine-empty
        // result — recall is non-throwing per spec § 7.8.1, so the stream's
        // degraded_stages is the channel. Skipped when an upstream read already
        // failed (candidates is empty for a named reason; re-evaluating would
        // only re-confirm empty).
        let filtered: Vec<Drawer> = if !degraded_stages.is_empty() {
            Vec::new()
        } else if force_bitmap_eval {
            degraded_stages.push(recall_stage::BITMAP_EVAL_FAILED.to_string());
            Vec::new()
        } else {
            match BitmapEvaluator::evaluate(&frame, &candidates, self.store.as_ref(), &self.resolve_node_names_for_drawers(&candidates)) {
                Ok(f) => f,
                Err(_) => {
                    degraded_stages.push(recall_stage::BITMAP_EVAL_FAILED.to_string());
                    Vec::new()
                }
            }
        };

        // Opt-in trace writes (Swift parity): nil/None → write nothing; Some(n)
        // → write at most the first min(n, filtered.len()) surfaced rows. The
        // reward sweep cares only about what was returned to the caller.
        // `recalled_at` is stored as TEXT ISO8601 per the fleet date rule.
        //
        // FAIL-CLOSED (Swift parity): a trace-write fault does NOT empty the
        // result — recall stays non-throwing and the caller still receives its
        // rows. But a DROPPED trace is the reward sweep's missing input, so it
        // is SURFACED as `recall.trace_write_failed` on the same degraded_stages
        // channel the internal-read failures use, rather than silently swallowed.
        // Genuine success records nothing.
        if let Some(trace_limit) = frame.trace_limit {
            let count = trace_limit.min(filtered.len());
            if count > 0 {
                let recalled_at = epoch_to_iso8601(now);
                let traces: Vec<RecallTraceItem> = filtered[..count]
                    .iter()
                    .map(|drawer| {
                        RecallTraceItem::new(
                            Uuid::new_v4().to_string(),
                            drawer.id.clone(),
                            recalled_at.clone(),
                            None, // ordered-by-capture-time recalls carry no score
                            0,    // operational_bitmap = 0 (used = false)
                        )
                    })
                    .collect();
                // TEST-ONLY seam: a forced `.traceWrite` drives this write to
                // fail without a genuinely-broken store. No production caller
                // arms it; in a production build `force_trace_write` is `false`
                // and the branch is optimised away.
                let write_result = if force_trace_write {
                    Err(LocusKitError::SqliteError(
                        "forced trace-write fault (test seam)".to_string(),
                    ))
                } else {
                    self.store.insert_recall_traces(&traces)
                };
                if write_result.is_err() {
                    degraded_stages.push(recall_stage::TRACE_WRITE_FAILED.to_string());
                }
            }
        }

        let page_size = frame.limit.unwrap_or(RecallStream::DEFAULT_PAGE_SIZE);
        RecallStream::new(filtered, page_size, frame.hydration_level)
            .with_degraded_stages(degraded_stages)
    }

    /// FRAME-AWARE by-id load. Loads `ids` by row, then applies the frame's
    /// bitmap/structured/content filter chain (via `BitmapEvaluator`, the exact
    /// pipeline `recall` runs) so `admissible` is precisely the frame-filtered
    /// subset of `ids` — identical semantics to a `recall(frame)` scan
    /// intersected with `ids`, but as an O(candidates) by-id load.
    ///
    /// Parity peer of Swift `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`.
    /// The Rust GLK recall path derives its `drawer_index` from a full
    /// `estate.recall(frame)` scan and so does not call this on its hot path;
    /// the capability is mirrored here for cross-port surface parity and for the
    /// frame-faithful drop conformance tests.
    ///
    /// `loaded_ids` reports every id whose row was returned by storage,
    /// regardless of the frame filter, so callers can gate a drop on load
    /// success: an id that loaded but is absent from `admissible` failed the
    /// frame filter (drop it); an id absent from `loaded_ids` did not load (a
    /// transient/partial read) and must be DEGRADED gracefully, never dropped.
    /// Tombstone exclusion is always enforced by `BitmapEvaluator` independent
    /// of the chain.
    ///
    /// `BitmapOnly` hydration strips the content body (parity with the recall
    /// page-emission `hydrate`); `Structured`/`Full` return the loaded row as-is
    /// (`get_drawer` reads full rows — the no-blob projection is a scan-level
    /// optimization not available on the single-row by-id path, and a content
    /// predicate in the frame needs the body anyway).
    pub fn get_drawers_matching_frame(
        &self,
        ids: &[RowID],
        frame: &RecallFrame,
    ) -> Result<FrameFilteredDrawers, LocusKitError> {
        // P6-secfix: load full rows (with content) so BitmapEvaluator::evaluate can
        // run ContentMatches predicates correctly. Content stripping for BitmapOnly
        // callers is applied AFTER evaluation so the predicate sees the real body.
        // The old ordering stripped first, then evaluated — so a ContentMatches
        // predicate always saw "" and never matched.
        let mut loaded: Vec<Drawer> = Vec::with_capacity(ids.len());
        let mut loaded_ids: HashSet<String> = HashSet::with_capacity(ids.len());
        for id in ids {
            if let Some(drawer) = self.store.get_drawer(id)? {
                loaded_ids.insert(drawer.id.clone());
                loaded.push(drawer);
            }
        }
        let node_names = self.resolve_node_names_for_drawers(&loaded);
        // Evaluate with full content available for ContentMatches predicates.
        let mut admissible =
            BitmapEvaluator::evaluate(frame, &loaded, self.store.as_ref(), &node_names)?;
        // Honor BitmapOnly stripping AFTER evaluation so the hydration contract
        // for the requested level is applied to the already-filtered result set.
        if frame.hydration_level == HydrationLevel::BitmapOnly {
            for d in &mut admissible {
                d.content = String::new();
            }
        }
        Ok(FrameFilteredDrawers {
            admissible,
            loaded_ids,
        })
    }

    /// Delete recall-trace rows whose `recalled_at` is strictly before
    /// `cutoff`. Estate-level pass-through over
    /// `DrawerStore::prune_recall_traces`. Returns the number of rows deleted.
    ///
    /// Called by the dreaming daemon's reward sweep to keep the recall_trace
    /// table bounded. `cutoff` is an ISO8601 TEXT string derived from the
    /// caller's deterministic `now`. Mirrors Swift
    /// `Estate.pruneRecallTraces(olderThan:)`.
    pub fn prune_recall_traces(&self, cutoff: &str) -> Result<usize, LocusKitError> {
        self.store.prune_recall_traces(cutoff)
    }

    /// Bulk-mark recall-trace rows for `target` in the window `[since, now]`.
    ///
    /// Estate-level pass-through over `DrawerStore::mark_recall_traces_used`.
    /// Both `since` and `now` are ISO8601 TEXT strings (fleet date rule).
    /// Returns the number of rows whose `used` bit was flipped. Mirrors Swift
    /// `Estate.markRecallTracesUsed(target:since:now:)`.
    pub fn mark_recall_traces_used(
        &self,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, LocusKitError> {
        self.store.mark_recall_traces_used(target, since, now)
    }

    /// Count all rows in the recall_trace table.
    ///
    /// Estate-level pass-through over `DrawerStore::count_recall_traces`.
    /// Used by estate-status reporting. Mirrors Swift
    /// `Estate.countRecallTraces()`.
    pub fn count_recall_traces(&self) -> Result<usize, LocusKitError> {
        self.store.count_recall_traces()
    }

    /// Count raw rows in the `drawers` table via `COUNT(*)`, bypassing all
    /// row-decode logic. Corrupt rows (e.g. a poison timestamp) are still
    /// counted. Used by the vault-export fail-loud path to distinguish
    /// "estate is genuinely empty" from "recall returned 0 because all rows
    /// are corrupt." Delegates to `DrawerStore::count_drawer_rows`. Mirrors
    /// Swift `Estate.countDrawerRows()`.
    pub fn count_drawer_rows(&self) -> Result<usize, LocusKitError> {
        self.store.count_drawer_rows()
    }

    /// Count all rows in the `tunnels` table via `COUNT(*)` — O(1), bypasses
    /// row-decode. Delegates to `DrawerStore::count_tunnel_rows`. Mirrors Swift
    /// `Estate.countTunnelRows()`.
    pub fn count_tunnel_rows(&self) -> Result<usize, LocusKitError> {
        self.store.count_tunnel_rows()
    }

    /// Count all rows in the `kg_facts` table via `COUNT(*)` — O(1), bypasses
    /// row-decode. Delegates to `DrawerStore::count_kg_fact_rows`. Mirrors Swift
    /// `Estate.countKGFactRows()`.
    pub fn count_kg_fact_rows(&self) -> Result<usize, LocusKitError> {
        self.store.count_kg_fact_rows()
    }

    // -----------------------------------------------------------------------
    // tunnels_from_wing
    // -----------------------------------------------------------------------

    /// Read the tunnels originating in `wing` — the estate-level surface over
    /// `DrawerStore::tunnels_from_wing`. The drawer-to-drawer tunnels are the
    /// edges of the estate's association graph; a reasoning lens (e.g.
    /// keystone centrality) consumes them through the kit. Read-only.
    ///
    /// Sensitivity gate: the underlying store query filters only by source
    /// wing + tombstone, so it would return restricted/secret tunnel edges
    /// (endpoint ids, free-form labels, adjective bitmaps) that the drawer
    /// recall pipeline excludes by default. This surface applies the same
    /// no-claims sensitivity ceiling BitmapEvaluator inserts for drawers —
    /// Normal tier (normal + elevated) visible, restricted/secret excluded —
    /// so a reasoning lens reading the graph never sees an edge whose tier is
    /// above the default recall ceiling. Trust/state axes are not gated here
    /// (sensitivity is the disclosure-relevant axis; the drawer endpoints are
    /// independently sensitivity-gated on recall). Synthetic containment
    /// edges carry adjective_bitmap 0 (Normal) and always pass. Mirrors the
    /// Swift `Estate.tunnelsFromWing` gate and the AriaMcpKit MCP-boundary
    /// filter, now enforced at the source so every caller is covered.
    pub fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.tunnels_from_wing_with_ceiling(wing, false)
    }

    /// `including_restricted` is the ONE sanctioned widening of the tunnel
    /// sensitivity gate: the vault export's `believed-including-private`
    /// scope — the owner's explicit opt-in for Private-tier bulk export
    /// — must carry provenance tunnels to restricted
    /// drawers, mirroring the drawer-side tier rule
    /// (`VaultExportScope::includes_private_tier`). Secret-tier edges are
    /// excluded UNCONDITIONALLY — no parameter widens past restricted,
    /// matching the drawer side where secret never bulk-exports. Mirrors
    /// Swift `Estate.tunnelsFromWing(_:includingRestricted:)`.
    pub fn tunnels_from_wing_with_ceiling(
        &self,
        wing: &str,
        including_restricted: bool,
    ) -> Result<Vec<Tunnel>, LocusKitError> {
        use crate::adjectives::AdjectiveSensitivity;
        Ok(self
            .store
            .tunnels_from_wing(wing)?
            .into_iter()
            .filter(|t| match t.adjective_sensitivity() {
                AdjectiveSensitivity::Normal | AdjectiveSensitivity::Elevated => true,
                AdjectiveSensitivity::Restricted => including_restricted,
                AdjectiveSensitivity::Secret => false,
            })
            .collect())
    }

    /// Add a tunnel (an association-graph edge) to the estate — the
    /// estate-level surface over `DrawerStore::add_tunnel`. The reasoning
    /// graph the keystone lens consumes is built from these.
    pub fn add_tunnel(&self, tunnel: &Tunnel) -> Result<(), LocusKitError> {
        self.store.add_tunnel(tunnel)
    }

    // -----------------------------------------------------------------------
    // Unfiltered full-corpus reads (recall surface)
    // -----------------------------------------------------------------------

    /// All non-tombstoned proposals in the estate, ordered by `filed_at`
    /// ascending. Estate-level pass-through over `DrawerStore::all_proposals`.
    pub fn all_proposals(&self) -> Result<Vec<crate::proposal::Proposal>, LocusKitError> {
        self.store.all_proposals()
    }

    /// All non-tombstoned associations in the estate, ordered by `filed_at`
    /// ascending. Estate-level pass-through over `DrawerStore::all_associations`.
    pub fn all_associations(&self) -> Result<Vec<crate::association::Association>, LocusKitError> {
        self.store.all_associations()
    }

    /// All non-tombstoned learned references in the estate, ordered by
    /// `filed_at` ascending. Estate-level pass-through over
    /// `DrawerStore::all_learned_references`.
    pub fn all_learned_references(
        &self,
    ) -> Result<Vec<crate::learned_reference::LearnedReference>, LocusKitError> {
        self.store.all_learned_references()
    }

    /// All kg-facts in the estate that are in the RowState Cluster-A
    /// (active) set — `g_state_cluster < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`
    /// (16) — ordered by `filed_at` ascending. Estate-level pass-through
    /// over `DrawerStore::all_kg_facts`.
    pub fn all_kg_facts(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.store.all_kg_facts()
    }

    /// All kg-facts in the estate regardless of lifecycle state — active AND
    /// retired — ordered by `filed_at` ascending. Estate-level pass-through
    /// over `DrawerStore::all_kg_facts_including_retired`.
    /// Peer of the Swift `Estate.allKGFactsIncludingRetired()`.
    pub fn all_kg_facts_including_retired(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.store.all_kg_facts_including_retired()
    }

    /// Insert a kg-fact into the estate. Estate-level pass-through over
    /// `DrawerStore::add_kg_fact`. Required by GLK since `estate.store`
    /// is `pub(crate)` and inaccessible from `GeniusLocusKit` (B-1 compliance).
    pub fn add_kg_fact(&self, fact: &crate::kg_fact::KGFact) -> Result<(), LocusKitError> {
        self.store.add_kg_fact(fact)
    }

    /// Retire a kg-fact by transitioning its state to `Withdrawn`. Estate-level
    /// pass-through over `DrawerStore::withdraw_kg_fact`. Required by GLK for
    /// the same B-1 compliance reason as `add_kg_fact`.
    pub fn withdraw_kg_fact(&self, id: &str, now: i64) -> Result<(), LocusKitError> {
        self.store.withdraw_kg_fact(id, now)
    }

    /// All non-tombstoned diary entries in the estate, ordered by `filed_at`
    /// ascending. Estate-level pass-through over `DrawerStore::all_diary_entries`.
    pub fn all_diary_entries(&self) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.store.all_diary_entries()
    }

    /// Insert a diary entry into the estate. Estate-level pass-through over
    /// `DrawerStore::add_diary_entry`. Required by GLK for B-1 compliance.
    pub fn add_diary_entry(
        &self,
        entry: &crate::diary_entry::DiaryEntry,
    ) -> Result<(), LocusKitError> {
        self.store.add_diary_entry(entry)
    }

    /// Most-recent `last_n` non-tombstoned diary entries for `agent_name`,
    /// newest first. Estate-level pass-through over `DrawerStore::read_diary`.
    /// Required by GLK for B-1 compliance.
    pub fn read_diary(
        &self,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<crate::diary_entry::DiaryEntry>, LocusKitError> {
        self.store.read_diary(agent_name, last_n)
    }

    /// All drawers in the estate, including tombstoned rows. Estate-level
    /// pass-through over `DrawerStore::all_drawers`. Used by GLK to expose
    /// the full-corpus snapshot the dreaming and maintenance readers need
    /// without NeuronKit calling the store directly (B-1 compliance).
    pub fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
        self.store.all_drawers()
    }

    /// Write the distilled representation of one drawer — all four
    /// representation columns in one atomic UPDATE. Estate-level
    /// pass-through over `DrawerStore::set_distilled_representation`; see
    /// the trait method for the full contract (direct column write, no
    /// audit event, no index-feed involvement —
    /// SPEC_DISTILLATION_STORAGE §4/§7.2). This is the seam GLK's
    /// distillation paths write through. Mirrors Swift
    /// `Estate.setDistilledRepresentation`.
    pub fn set_distilled_representation(
        &self,
        drawer_id: &str,
        distilled: &str,
        pipeline_version: &str,
        token_count: i64,
        generated_at: i64,
    ) -> Result<usize, LocusKitError> {
        self.store.set_distilled_representation(
            drawer_id,
            distilled,
            pipeline_version,
            token_count,
            generated_at,
        )
    }

    /// Count of active drawers still awaiting distillation (§7.1
    /// eligibility predicate as an aggregate). Estate-level pass-through
    /// over `DrawerStore::count_undistilled` — the distillation
    /// drain-accounting observable. Mirrors Swift `Estate.countUndistilled`.
    pub fn count_undistilled(&self, pipeline_version: &str) -> Result<usize, LocusKitError> {
        self.store.count_undistilled(pipeline_version)
    }

    /// Write one drawer's subject line (PR-01). Estate-level pass-through
    /// over `DrawerStore::set_subject_representation` — the seam the
    /// filing surface, backfill, and the (future) subject rider write
    /// through. Mirrors Swift `Estate.setSubjectRepresentation`.
    pub fn set_subject_representation(
        &self,
        drawer_id: &str,
        subject: &str,
        pipeline_version: &str,
        generated_at: i64,
    ) -> Result<usize, LocusKitError> {
        self.store
            .set_subject_representation(drawer_id, subject, pipeline_version, generated_at)
    }

    /// Count of active drawers still awaiting a subject line (PR-01
    /// backfill-eligibility aggregate — the estate-status subject-debt
    /// counter's source). Estate-level pass-through over
    /// `DrawerStore::count_missing_subject`. Mirrors Swift
    /// `Estate.countMissingSubject`.
    pub fn count_missing_subject(&self, pipeline_version: &str) -> Result<usize, LocusKitError> {
        self.store.count_missing_subject(pipeline_version)
    }

    /// Presence debt, NULL-only (PR-09) — the subject-backfill drain
    /// lane's `pending`. See `DrawerStore::count_subject_debt`.
    pub fn count_subject_debt(&self) -> Result<usize, LocusKitError> {
        self.store.count_subject_debt()
    }

    /// The subject-backfill sweep enumerator (PR-09). See
    /// `DrawerStore::subject_debt_batch`.
    pub fn subject_debt_batch(&self, limit: usize) -> Result<Vec<Drawer>, LocusKitError> {
        self.store.subject_debt_batch(limit)
    }

    /// Tier-aware variants (PR-10). See the DrawerStore twins.
    pub fn count_subject_debt_including(&self, pipelines: &[String]) -> Result<usize, LocusKitError> {
        self.store.count_subject_debt_including(pipelines)
    }

    pub fn subject_debt_batch_including(
        &self,
        limit: usize,
        pipelines: &[String],
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.store.subject_debt_batch_including(limit, pipelines)
    }

    /// Up to `limit` drawers in the estate (including tombstoned rows),
    /// in the store's natural `filedAt`-ascending order. Estate-level
    /// pass-through over `DrawerStore::all_drawers_bounded`. The bound is
    /// applied at the storage layer (LIMIT), so the I/O is O(limit), not
    /// O(estate)-then-truncate. `None` reads the full corpus, matching
    /// `all_drawers`. Used by GLK to give the maintenance reader a bounded
    /// scan without NeuronKit reaching the store directly (B-1 compliance).
    pub fn all_drawers_bounded(
        &self,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.store.all_drawers_bounded(limit)
    }

    /// Bounded page of active (non-tombstoned) drawers ordered by `id`
    /// ascending, optionally starting strictly after `after_id`.
    /// Estate-level pass-through over `DrawerStore::active_drawers_after`.
    /// Used by GeniusLocusKit's reindex-missing sweep to walk the drawers
    /// table in bounded, cursor-advancing pages instead of reloading the
    /// full table on every pass (MEDIUM perf fix; mirrors the Swift
    /// `Estate.activeDrawersAfter(id:limit:)`).
    pub fn active_drawers_after(
        &self,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        self.store.active_drawers_after(after_id, limit)
    }

    /// Fingerprints of every non-tombstoned drawer captured in the closed
    /// epoch-milliseconds window `[start_epoch, end_epoch]`, in
    /// HLC-ascending order within the window. Estate-level pass-through over
    /// `DrawerStore::fingerprints_captured_in`. Used by GLK to expose the
    /// per-window fingerprint read the Moment lens needs without NeuronKit
    /// (or aria-mcp) reaching the store directly (B-1 compliance — mirrors
    /// the Swift `GeniusLocusKit.glkFingerprintsCaptured(in:window:)` flow).
    pub fn fingerprints_captured_in(
        &self,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<substrate_types::fingerprint256::Fingerprint256>, LocusKitError> {
        self.store.fingerprints_captured_in(start_epoch, end_epoch)
    }

    /// Every room-level container fingerprint (room non-empty) with its
    /// bitwise-OR aggregate. Estate-level pass-through over
    /// `DrawerStore::room_level_fingerprints`. The maintenance daemon's
    /// fingerprint-drift signal reads these through GLK as the live
    /// per-scope fingerprint (B-1 compliance — NeuronKit never touches the
    /// store).
    pub fn room_level_fingerprints(
        &self,
    ) -> Result<Vec<crate::container_fingerprint_store::RoomLevelEntry>, LocusKitError> {
        self.store.room_level_fingerprints()
    }

    /// All non-tombstoned drawers in a room, ordered by `filedAt` ascending.
    ///
    /// Used by `distill_items_sweep` (GeniusLocusKit coordinator) for the
    /// rooms-first sweep: rooms that pass the `operationalAND` skip-gate
    /// are loaded via this call rather than a full `all_drawers` scan.
    /// Delegates to `store.drawers_in_wing_room(wing, room)`.
    pub fn drawers_in_wing_room(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.store.drawers_in_wing_room(wing, room)
    }

    /// Time-bucketed fingerprint bit-activity series for `bit` over the most
    /// recent `bucket_count` buckets of width `bucket_seconds` (a SECONDS width;
    /// the store scales it to ms internally), ending at `ending_at` (epoch
    /// milliseconds, epoch-millisecond instants — deterministic clock, never read system time).
    ///
    /// Estate-level pass-through over `DrawerStore::fingerprint_bit_series`.
    /// Used by GLK to expose the bit-series surface the Rhythm lens needs without
    /// NeuronKit (or CognitionKit) reaching the store directly (B-1 compliance —
    /// mirrors Swift `GeniusLocusKit.glkFingerprintBitSeries`).
    ///
    /// Returns `Err(LocusKitError::InvalidContent)` when `bit > 255`
    /// or `bucket_seconds < 1`. Returns an empty `Vec` when `bucket_count == 0`.
    pub fn fingerprint_bit_series(
        &self,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, LocusKitError> {
        self.store.fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
    }

    /// All tunnels in the estate across all wings. Estate-level pass-through
    /// over `DrawerStore::all_tunnels`. Used by GLK to expose the full
    /// association graph the dreaming reader needs (B-1 compliance).
    pub fn all_tunnels(&self) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.store.all_tunnels()
    }

    /// All non-tombstoned, non-retired tunnels estate-wide.
    ///
    /// Active-edge view: retired tunnels (bit 13 of `operational_bitmap` set) are
    /// excluded so that OMEGA retirement removes a tunnel from the dreaming
    /// suppression set — allowing a later co-recall to re-propose it.
    /// Full history remains available via `all_tunnels()`.
    pub fn all_active_tunnels(&self) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.store.all_active_tunnels()
    }

    /// Flip bit 13 of `operational_bitmap` to retire a tunnel.
    ///
    /// Throws `TunnelNotFound` if no non-tombstoned tunnel with `tunnel_id` exists.
    /// The caller (NeuronKit via the GLK seam) is responsible for writing a diary
    /// entry recording the OMEGA retirement decision — this method performs only
    /// the bitmap update (B-1 compliant).
    pub fn retire_tunnel(
        &self,
        tunnel_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.retire_tunnel(tunnel_id, changed_by, now)
    }

    /// Clear bit 13 of `operational_bitmap` to un-retire a tunnel.
    ///
    /// Reverses a prior `retire_tunnel`. The tunnel re-enters active reads
    /// (`all_active_tunnels`) and the dreaming suppression set once persisted.
    /// Throws `TunnelNotFound` if no non-tombstoned tunnel with `tunnel_id` exists.
    pub fn unretire_tunnel(
        &self,
        tunnel_id: &str,
        changed_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.unretire_tunnel(tunnel_id, changed_by, now)
    }

    /// Review a `Proposed` tunnel: accept → `Active`, reject → `Withdrawn`.
    /// Estate-level surface over `DrawerStore::respond_to_tunnel` — the
    /// review verb the ARIA `moot_review_tunnel` tool and the dreaming
    /// pipeline call. Only `Proposed` tunnels are reviewable; see the store
    /// method for the lifecycle guard and audit contract. Mirrors Swift
    /// `Estate.respondToTunnel(id:accept:changedBy:reason:now:)`.
    pub fn respond_to_tunnel(
        &self,
        tunnel_id: &str,
        accept: bool,
        changed_by: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.respond_to_tunnel(tunnel_id, accept, changed_by, reason, now)
    }

    /// Recall-trace rows whose `recalled_at` falls in `[since, now]` (both
    /// bounds inclusive). Both parameters are ISO8601 strings. Estate-level
    /// pass-through over `DrawerStore::recent_recall_traces`. Used by GLK
    /// to surface the dreaming daemon's reward window (B-1 compliance).
    pub fn recent_recall_traces(
        &self,
        since: &str,
        now: &str,
    ) -> Result<Vec<crate::recall_trace_item::RecallTraceItem>, LocusKitError> {
        self.store.recent_recall_traces(since, now)
    }

    /// Wave-2 §3.2: atomic consolidation act. Delegates to
    /// `DrawerStore::consolidate_transactionally`.
    pub fn consolidate_transactionally(
        &self,
        vague_drawer: &crate::drawer::Drawer,
        constituent_ids: &[&str],
        added_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store
            .consolidate_transactionally(vague_drawer, constituent_ids, added_by, now)
    }

    /// Wave-2 §5.1: fold-in reconsolidation. Delegates to
    /// `DrawerStore::fold_in_transactionally`.
    pub fn fold_in_transactionally(
        &self,
        vague_v2: &crate::drawer::Drawer,
        prior_vague_id: &str,
        enlarged_constituent_ids: &[&str],
        added_by: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.fold_in_transactionally(
            vague_v2,
            prior_vague_id,
            enlarged_constituent_ids,
            added_by,
            now,
        )
    }

    /// Wave-2 §4.4 hop 2: constituent IDs behind a vague item's active
    /// `_consolidated_from` tunnels. Delegates to
    /// `DrawerStore::constituent_ids_for_vague_item`.
    pub fn constituent_ids_for_vague_item(
        &self,
        vague_drawer_id: &str,
    ) -> Result<Vec<String>, LocusKitError> {
        self.store.constituent_ids_for_vague_item(vague_drawer_id)
    }

    /// Insert recall-trace rows directly — maintenance/test seeding for the
    /// Wave-2 D3 quiet clock (mirrors Swift `Estate.insertRecallTraces`).
    pub fn insert_recall_traces(
        &self,
        items: &[crate::recall_trace_item::RecallTraceItem],
    ) -> Result<(), LocusKitError> {
        self.store.insert_recall_traces(items)
    }

    /// Fetch one drawer by id (None when absent). Delegates to
    /// `DrawerStore::get_drawer` (mirrors Swift `Estate.getDrawers(ids:)`
    /// for the singular case).
    pub fn get_drawer(
        &self,
        id: &str,
    ) -> Result<Option<crate::drawer::Drawer>, LocusKitError> {
        self.store.get_drawer(id)
    }

    /// Batch fetch by ids; absent ids are skipped (mirrors Swift
    /// `Estate.getDrawers(ids:)`).
    pub fn get_drawers(
        &self,
        ids: &[&str],
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        let mut out = Vec::with_capacity(ids.len());
        for &id in ids {
            if let Some(d) = self.store.get_drawer(id)? {
                out.push(d);
            }
        }
        Ok(out)
    }

    // -----------------------------------------------------------------------
    // Repair helpers — sensitivity inheritance repair prologue (§D.6 #4)
    // -----------------------------------------------------------------------

    /// Promote a drawer's adjective bitmap (full i64) via the store's
    /// audit-trail mutation path. Used by the consolidation repair prologue
    /// (§D.6 #4) to restamp under-tiered vague drawers. Callers must
    /// compute the new full bitmap (preserving all non-sensitivity bits)
    /// before invoking. Mirrors Swift `Estate.repairVagueAdjectiveBitmap`.
    pub fn repair_adjective_bitmap(
        &self,
        drawer_id: &str,
        new_adjective: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.mutate_adjective(
            drawer_id,
            new_adjective,
            "consolidation-repair",
            Some("sensitivity repair prologue §D.6 #4 — promoting under-tiered vague drawer"),
            now,
        )
    }

    /// Promote a drawer's provenance bitmap (full i64) via the store's
    /// mutation path. Used by the consolidation repair prologue (§D.6 #4).
    /// Callers compute the new full bitmap before invoking.
    /// Mirrors Swift `Estate.repairVagueProvenance`.
    pub fn repair_provenance_bitmap(
        &self,
        drawer_id: &str,
        new_provenance: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.store.mutate_provenance(
            drawer_id,
            new_provenance,
            "consolidation-repair",
            Some("sensitivity repair prologue §D.6 #4 — promoting under-tiered vague drawer"),
            now,
        )
    }

    /// Overwrite `adjective_bitmap` on a tunnel directly. Used by the
    /// consolidation repair prologue (§D.6 #4) to restamp pre-existing
    /// lineage tunnels. No audit event — correction write only.
    /// Mirrors Swift `Estate.updateTunnelAdjBitmap(id:adjBitmap:)`.
    pub fn stamp_tunnel_adjective_bitmap(
        &self,
        tunnel_id: &str,
        adj_bitmap: i64,
    ) -> Result<(), LocusKitError> {
        self.store.stamp_tunnel_adjective_bitmap(tunnel_id, adj_bitmap)
    }

    // -----------------------------------------------------------------------
    // withdraw
    // -----------------------------------------------------------------------

    /// Withdraw a drawer — move its `State` axis to `Withdrawn`.
    ///
    /// Composes the new adjective bitmap by clearing bits 0–3 with
    /// `& !0x3F` and OR-ing in `State::Withdrawn.raw_value()`, preserving
    /// the upper adjective axes (sensitivity / exportability / trust).
    /// `DrawerStore::mutate_state(State::Withdrawn, RowVerb::Retract)`
    /// updates the projection and appends one sealed `AuditEvent`
    /// atomically.
    ///
    /// # Parameters
    ///
    /// - `row_id`: the drawer's stable id.
    /// - `reason`: optional free-text justification written verbatim into
    ///   the audit row's `reason` column.
    /// - `now`: deterministic clock value (epoch seconds).
    ///
    /// # Errors
    ///
    /// Returns `LocusKitError::DrawerNotFound` when the row id is not
    /// present in the store.
    pub fn withdraw(
        &self,
        row_id: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let drawer =
            self.store
                .get_drawer(row_id)?
                .ok_or_else(|| LocusKitError::DrawerNotFound {
                    id: row_id.to_string(),
                })?;

        let _ = &drawer;

        // Withdrawal is a STATE transition (→ withdrawn via `retract`),
        // so it MUST go through mutate_state, which validates the
        // transition against the automaton. The earlier path wrote the
        // state bits through mutate_adjective, bypassing that check — the
        // write gate now forbids moving state through a field edit, so
        // this is the correct route. Mirror of Swift Estate.withdraw.
        let changed_by = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let changed_by = if changed_by.is_empty() {
            "estate".to_string()
        } else {
            changed_by
        };

        self.store.mutate_state(
            row_id,
            State::Withdrawn,
            RowVerb::Retract,
            &changed_by,
            Some(reason.unwrap_or("withdrawn via Estate.withdraw")),
            now,
        )?;
        // NT-L3: Merkle rollup after state change.
        if let Ok(room_uuid) = Uuid::parse_str(&drawer.parent_node_id) {
            let _ = self.rollup_merkle_roots(room_uuid, now);
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // expunge
    // -----------------------------------------------------------------------

    /// Expunge a drawer, with optional deferred audit seal.
    ///
    /// When `seal_audit` is `true` (the default for direct LocusKit callers),
    /// the audit event is sealed inside this call — preserving the historical
    /// atomic single-call contract.
    ///
    /// When `seal_audit` is `false` (the GLK orchestration path), the gate-
    /// produced event is returned unsealed. The caller seals via
    /// `seal_expunge_audit` after the cross-kit vector delete succeeds, or via
    /// `seal_expunge_orphan_audit` if it fails. This satisfies the §B-2a audit
    /// ordering invariant: success audit seals only after the full expunge
    /// (storage + cross-kit delete) completes.
    ///
    /// The `now` parameter is epoch seconds (same unit as `capture` and
    /// `withdraw`). Passing it explicitly makes the operation deterministic —
    /// callers use their own clock snapshot.
    pub fn expunge(
        &self,
        row_id: &str,
        reason: &str,
        confirmation: bool,
        now: i64,
        seal_audit: bool,
    ) -> Result<substrate_lib::verbs::AuditEvent, LocusKitError> {
        if !confirmation {
            return Err(LocusKitError::InvalidContent(
                "expunge requires confirmation: true (destructive op)".to_string(),
            ));
        }
        // Resolve to validate existence before the destructive op; the drawer
        // value itself is not needed past this guard.
        let _drawer = self.store.get_drawer(row_id)?
            .ok_or_else(|| LocusKitError::DrawerNotFound {
                id: row_id.to_string(),
            })?;
        let changed_by = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let changed_by = if changed_by.is_empty() {
            "estate".to_string()
        } else {
            changed_by
        };
        let reason_opt = if reason.is_empty() {
            Some("expunged via Estate.expunge")
        } else {
            Some(reason)
        };
        // WS2-F2: expunge_gated tombstones the full lineage chain, which
        // may span multiple rooms (lineage members can migrate via reanchor).
        // Collect all distinct parent room IDs for the lineage BEFORE
        // expunge so they can all be rolled up after tombstoning.
        let lineage_ids = self.store.lineage_chain(row_id).unwrap_or_default();
        let ids_to_fetch: Vec<&str> = if lineage_ids.is_empty() {
            vec![row_id]
        } else {
            lineage_ids.iter().map(String::as_str).collect()
        };
        let mut affected_room_ids: std::collections::HashSet<Uuid> =
            std::collections::HashSet::new();
        for id in &ids_to_fetch {
            if let Ok(Some(d)) = self.store.get_drawer(id) {
                if let Ok(room_uuid) = Uuid::parse_str(&d.parent_node_id) {
                    affected_room_ids.insert(room_uuid);
                }
            }
        }

        let result = self.store
            .expunge_gated(row_id, &changed_by, reason_opt, now, seal_audit)?;
        // NT-L3: Merkle rollup after expunge. Roll up ALL rooms that
        // contained any lineage member — not just the room of the
        // initiating drawer — so cross-room lineage expunge keeps every
        // affected room's root correct (WS2-F2, fixed 2026-06-28).
        for room_uuid in affected_room_ids {
            let _ = self.rollup_merkle_roots(room_uuid, now);
        }
        Ok(result)
    }

    /// Return all drawer ids sharing the same lineage as `row_id`.
    ///
    /// Used by GLK's cross-kit vector-delete fan-out: after the storage
    /// expunge walks the lineage and scrubs all versions, GLK needs the
    /// same id set to delete vectors for every version.
    pub fn lineage_chain(&self, row_id: &str) -> Result<Vec<String>, LocusKitError> {
        self.store.lineage_chain(row_id)
    }

    /// Seal the success audit event produced by `expunge(seal_audit: false)`.
    ///
    /// Called by the GLK orchestration path after the cross-kit vector delete
    /// (step 2) succeeds. The event was produced in step 1 but held unsealed
    /// until the full expunge completed, per the §B-2a audit ordering invariant.
    pub fn seal_expunge_audit(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        self.store.seal_expunge_audit(event)
    }

    /// Seal an "expungeOrphan" audit event when step 2 (cross-kit vector
    /// delete) failed after step 1 (storage expunge) already committed.
    ///
    /// Records the partial expunge honestly: the row is tombstoned and content
    /// is zeroed, but the vector embedding was NOT removed. The substrate verb
    /// string `"expungeOrphan"` maps to `UnifiedAuditVerb::Expunge` in the
    /// unified log, so downstream consumers see the storage-level expunge.
    ///
    /// Returns `Err` when the underlying store cannot write the orphan audit
    /// event (double-failure: step-2 vector delete already failed). The GLK
    /// coordinator folds this error into the returned `CrossKitVectorDeleteFailed`
    /// reason string so callers learn both failures from a single typed error.
    pub fn seal_expunge_orphan_audit(
        &self,
        row_id: &str,
        success_event: &substrate_lib::verbs::AuditEvent,
        now: i64,
    ) -> Result<(), LocusKitError> {
        // Test seam: force a one-shot orphan-seal failure to exercise the
        // double-failure path in the GLK coordinator without needing a
        // genuinely-broken store. Compiled out in production builds.
        #[cfg(any(test, feature = "test-seams"))]
        if self.take_test_force_orphan_seal_error() {
            return Err(LocusKitError::InvalidContent(
                "forced orphan-seal failure".to_string(),
            ));
        }

        let changed_by = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let changed_by = if changed_by.is_empty() {
            "estate".to_string()
        } else {
            changed_by
        };
        self.store
            .seal_expunge_orphan_audit(row_id, success_event, &changed_by, now)
    }

    /// Seal a synthetic `"expungeOrphan"` audit event for use by the
    /// expunge integrity sweep.
    ///
    /// Unlike `seal_expunge_orphan_audit` — which requires the original
    /// step-1 gate event (held in memory, lost on crash) — this path
    /// reads the drawer's current bitmaps and lattice anchor directly from
    /// the store to construct the event. The "before" bitmaps are
    /// approximated as the current (post-tombstone) state; this is
    /// acceptable for crash-recovery forensics where the pre-tombstone
    /// snapshot is unavailable.
    ///
    /// Called by `GLK::run_expunge_integrity_sweep` for each row in the
    /// orphan set (tombstoned without any expunge audit event).
    pub fn seal_expunge_orphan_audit_synthetic(
        &self,
        row_id: &str,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let changed_by = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let changed_by = if changed_by.is_empty() {
            "estate".to_string()
        } else {
            changed_by
        };
        self.store
            .seal_expunge_orphan_for_sweep(row_id, &changed_by, now)
    }

    // -----------------------------------------------------------------------
    // Dataset handle verb surface (MX-TAB-4)
    // -----------------------------------------------------------------------

    /// Return the drawer for `row_id`, or `None` when no row exists.
    ///
    /// Tombstoned and content-zeroed rows are returned unfiltered so the
    /// caller can inspect state after an expunge. Used by the GLK coordinator's
    /// `expunge` to read the drawer content BEFORE the storage expunge zeroes
    /// the blob, enabling the dataset-erase cascade to extract `dataset_id`
    /// from a `ContentKind::Dataset` handle.
    ///
    /// Mirrors Swift `Estate.drawerById(rowID:)` in `DatasetHandle.swift`.
    pub fn drawer_by_id(&self, row_id: &str) -> Result<Option<crate::drawer::Drawer>, LocusKitError> {
        self.store.get_drawer(row_id)
    }

    /// Append an arbitrary audit event to this estate's audit log.
    ///
    /// The underlying storage operation is identical to `seal_expunge_audit` —
    /// both call the DrawerStore's audit-append path. The distinct name signals
    /// the different semantic intent at the call site: `seal_expunge_audit`
    /// closes a deferred expunge event; `append_audit_event` records
    /// supplementary events such as the dataset table-drop that accompanies
    /// an erase of a `ContentKind::Dataset` handle.
    ///
    /// Mirrors Swift `Estate.appendAuditEvent(_:)` in `DatasetHandle.swift`.
    pub fn append_audit_event(
        &self,
        event: &substrate_lib::verbs::AuditEvent,
    ) -> Result<(), LocusKitError> {
        // Delegates to seal_expunge_audit because both operations are
        // audit-log appends — DrawerStore exposes no separate generic-append
        // method, and introducing one would require changes to every
        // DrawerStore conformer. The semantic distinction lives in the verb
        // string inside the AuditEvent, not in the storage path.
        self.store.seal_expunge_audit(event)
    }

    /// Construct and append a supplementary audit event derived from an
    /// existing (unsealed) event, using a caller-supplied verb and reason.
    ///
    /// This is the only correct way for the GLK coordinator to append
    /// side-channel audit events (such as "datasetTableDrop") without needing
    /// direct access to `substrate_lib` — which is a LocusKit-layer dep, not a
    /// GLK dep. The coordinator passes the `unsealed_event` it already holds
    /// from `estate.expunge()`; this method computes the deterministic
    /// `event_id` (SHA-256 content-ID over the wire fields) and appends.
    ///
    /// Append failure is returned to the caller but is intentionally swallowed
    /// by the GLK coordinator (mirrors Swift: `catch { os_log.error }` pattern)
    /// so tombstone step-3 sealing can still proceed.
    ///
    /// Used by: `GeniusLocusKit::coordinator::expunge` Step 2.5.
    pub fn append_supplementary_audit(
        &self,
        from: &substrate_lib::verbs::AuditEvent,
        verb: &str,
        reason: &str,
    ) -> Result<(), LocusKitError> {
        let event_id = substrate_lib::audit_gate::content_id(
            from.estate_uuid,
            from.row_id,
            &from.hlc,
            verb,
            from.after_bitmaps,
            from.after_lattice_anchor,
        );
        let event = substrate_lib::verbs::AuditEvent {
            event_id,
            estate_uuid: from.estate_uuid,
            row_id: from.row_id,
            hlc: from.hlc,
            verb: verb.to_string(),
            before_bitmaps: None,
            after_bitmaps: from.after_bitmaps,
            before_lattice_anchor: None,
            after_lattice_anchor: from.after_lattice_anchor,
            actor: from.actor.clone(),
            reason: Some(reason.to_string()),
        };
        self.store.seal_expunge_audit(&event)
    }

    /// Return all drawers with `content_kind() == ContentKind::Dataset` that
    /// reference `dataset_id`, ordered by `filed_at` ascending (the natural
    /// `allDrawers` order).
    ///
    /// Performs a full-corpus scan in v1 because dataset handles are rare
    /// (O(datasets), not O(drawers)). A targeted index is deferred to a
    /// future mission if the corpus grows large enough to require it.
    ///
    /// Mirrors Swift `Estate.findDatasetHandles(datasetId:)` in
    /// `DatasetHandle.swift`.
    pub fn find_dataset_handles(
        &self,
        dataset_id: uuid::Uuid,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        let all = self.store.all_drawers()?;
        let handles = all
            .into_iter()
            .filter(|d| {
                if d.content_kind() != crate::drawer_operational::ContentKind::Dataset {
                    return false;
                }
                match crate::dataset_handle::DatasetHandleContent::decode(&d.content) {
                    Ok(h) => h.dataset_id == dataset_id,
                    Err(_) => false,
                }
            })
            .collect();
        Ok(handles)
    }

    /// Return the active dataset handle for `dataset_id`, or an error.
    ///
    /// - When no handle exists: returns `LocusKitError::DrawerNotFound`.
    /// - When all handles are in cluster B (Withdrawn, Superseded, etc.):
    ///   returns `LocusKitError::WithdrawnDatasetHandle`.
    /// - When an active (cluster A) handle exists: returns it.
    ///
    /// Withdrawal is a belief-state change, NOT a destructive erase. The
    /// backing dataset table is NOT dropped by this call. Use GLK `expunge`
    /// to erase both the handle and the table.
    ///
    /// Mirrors Swift `Estate.resolveActiveDatasetHandle(datasetId:)` in
    /// `DatasetHandle.swift`.
    pub fn resolve_active_dataset_handle(
        &self,
        dataset_id: uuid::Uuid,
    ) -> Result<crate::drawer::Drawer, LocusKitError> {
        // bit_field is re-exported from substrate_kernel; bitmap_ops only
        // shadows it locally and the re-export is private.
        use substrate_kernel::bit_field;
        let handles = self.find_dataset_handles(dataset_id)?;
        if handles.is_empty() {
            return Err(LocusKitError::DrawerNotFound {
                id: dataset_id.to_string(),
            });
        }
        // Search for a cluster-A (currently believed) non-tombstoned handle.
        // Bits 0–5 of adjective_bitmap encode the State raw value (cookbook §2.3).
        if let Some(active) = handles.iter().find(|d| {
            if d.tombstoned_at.is_some() {
                return false;
            }
            let state_raw = bit_field::extract_field(d.adjective_bitmap, 0, 6);
            let state = crate::adjectives::State::from_raw(state_raw);
            state.is_cluster_a()
        }) {
            return Ok(active.clone());
        }
        // All handles are withdrawn, superseded, expired, or tombstoned.
        Err(LocusKitError::WithdrawnDatasetHandle { dataset_id })
    }

    /// Create a dataset handle drawer — the only authorised path for
    /// drawers with `content_kind() == ContentKind::Dataset`.
    ///
    /// ## Why a dedicated creation seam
    ///
    /// The FDC classifier (`run_n_fdc`) is explicitly barred from emitting
    /// `ContentKind::Dataset` and skips dataset-kind drawers. The ordinary
    /// `capture(frame, now)` path validates `embedding_model_id` is non-empty
    /// and `content` is non-empty — dataset handles need both a sentinel
    /// model ID and structured JSON content, which `capture` does not produce.
    ///
    /// ## Sensitivity floor invariant (v1)
    ///
    /// Rows appended to the backing table are expected to carry sensitivity
    /// at or below `sensitivity_raw`. Enforcement is deferred to MX-TAB-5.
    ///
    /// ## Parameters
    ///
    /// - `dataset_id`: UUID of the already-created dataset in the DatasetStore.
    /// - `columns`: Column schema summary at creation time.
    /// - `row_count`: Row count at creation time. Informational; may drift.
    /// - `source_description`: Human-readable provenance.
    /// - `wing`: Wing name. `None` resolves to the estate's default wing.
    /// - `room`: Room name. Must be non-empty.
    /// - `added_by`: Actor identifier. Must be non-empty.
    /// - `sensitivity_raw`: `AdjectiveSensitivity` raw value (0/16/32/48).
    /// - `udc_code`: UDC classification code. Must be non-empty (I-5).
    /// - `now`: Epoch seconds timestamp from the caller.
    ///
    /// Mirrors Swift `Estate.captureDatasetHandle(...)` in `DatasetHandle.swift`.
    #[allow(clippy::too_many_arguments)]
    pub fn capture_dataset_handle(
        &self,
        dataset_id: uuid::Uuid,
        columns: Vec<crate::dataset_handle::DatasetColumnSummary>,
        row_count: i64,
        source_description: &str,
        wing: Option<&str>,
        room: &str,
        added_by: &str,
        sensitivity_raw: i64,
        udc_code: &str,
        now: i64,
    ) -> Result<crate::drawer::Drawer, LocusKitError> {
        // bit_field is re-exported from substrate_kernel; bitmap_ops only
        // shadows it locally and the re-export is private.
        use substrate_kernel::bit_field;
        use crate::dataset_handle::{DatasetHandleContent, DATASET_HANDLE_EMBEDDING_MODEL_ID};
        use crate::default_wings::DEFAULT_WING_NAME;
        use crate::drawer::Drawer;
        use crate::drawer_operational::{CaptureChannel, ContentKind};
        use crate::provenance::SourceType;
        use uuid::Uuid;

        if room.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "captureDatasetHandle: room must not be empty".to_string(),
            ));
        }
        if added_by.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "captureDatasetHandle: added_by must not be empty".to_string(),
            ));
        }
        if udc_code.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "captureDatasetHandle: udc_code must not be empty (spec I-5)".to_string(),
            ));
        }

        // Encode handle payload as JSON for Drawer.content.
        let handle_content = DatasetHandleContent {
            dataset_id,
            columns,
            row_count,
            source_description: source_description.to_string(),
            table_signature: None,
            column_signatures: None,
        };
        let content_json = handle_content
            .encode()
            .map_err(LocusKitError::InvalidContent)?;

        // Operational bitmap (cookbook §2.4 v0.6):
        //   bits 0–5   capture_channel — Typed (raw 0)
        //   bits 6–11  content_kind    — Dataset (raw 7)
        //   bits 12–23 feature_flags   — none in v1
        let op_bitmap = bit_field::write_field(
            ContentKind::Dataset.raw_value(),
            bit_field::write_field(CaptureChannel::Typed.raw_value(), 0, 0, 6),
            6,
            6,
        );

        // Adjective bitmap (cookbook §2.3 v0.6):
        //   bits 0–5   state       — Active (raw 0)
        //   bits 6–11  sensitivity — caller-supplied scale-gapped raw
        //   bits 12–17 exportability — Private (raw 0)
        //   bits 18–23 trust       — Verbatim (raw 0)
        let adj_bitmap = bit_field::write_field(sensitivity_raw, 0, 6, 6);

        // Provenance bitmap (cookbook §2.5):
        //   bits 0–5   source_type — User (raw 0)
        //   all other fields default to 0
        let provenance_bitmap = bit_field::write_field(SourceType::User.raw_value(), 0, 0, 6);

        // Resolve wing/room to node IDs via NodeStore.
        let wing_name = wing
            .map(|s| s.to_string())
            .unwrap_or_else(|| DEFAULT_WING_NAME.to_string());
        let node_store = self.node_store.as_ref().ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "captureDatasetHandle: NodeStore not available — estate not fully initialized"
                    .to_string(),
            )
        })?;
        let root = node_store.root_node()?.ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "captureDatasetHandle: estate root node not found — estate not provisioned"
                    .to_string(),
            )
        })?;
        let wing_node = node_store.create_node(&wing_name, root.id, now)?;
        let room_node = node_store.create_node(room, wing_node.id, now)?;

        let drawer_id = Uuid::new_v4().to_string();
        let mut drawer = Drawer::new(
            drawer_id,
            content_json,
            room_node.id.to_string(),
            added_by.to_string(),
            now,
            DATASET_HANDLE_EMBEDDING_MODEL_ID.to_string(),
        );
        drawer.adjective_bitmap = adj_bitmap;
        drawer.operational_bitmap = op_bitmap;
        drawer.provenance = provenance_bitmap;
        drawer.lineage_id = Uuid::new_v4();
        drawer.udc_code = udc_code.to_string();
        drawer.event_time = now;

        self.store.add_drawer(&drawer, now)?;
        Ok(drawer)
    }

    // -----------------------------------------------------------------------
    // Integrity sweep query surface
    // -----------------------------------------------------------------------

    /// Tombstoned drawers that have no sealed "tombstone" or "expungeOrphan"
    /// audit event — the input set for `GLK::run_expunge_integrity_sweep`.
    ///
    /// A row is in this set when storage-expunge step 1 completed (tombstone
    /// written) but neither the success-audit (step 3) nor the orphan-audit
    /// (step-2-failure path) was sealed. This covers two root causes:
    ///
    ///   1. **Crash window**: the process crashed between step 1 and step 3.
    ///   2. **Double-failure**: both the step-2 vector delete and the
    ///      orphan-seal write failed; the row is tombstoned with no audit record.
    ///
    /// The GLK coordinator re-attempts the cross-kit delete for each returned
    /// row and seals the appropriate audit. The query is bounded because
    /// tombstoned rows are rare — each successful expunge removes one from this
    /// set permanently.
    pub fn tombstoned_rows_without_expunge_audit(
        &self,
    ) -> Result<Vec<crate::drawer::Drawer>, LocusKitError> {
        self.store.tombstoned_rows_without_expunge_audit()
    }

    /// Zero the `content` column for every row in the `drawers` table.
    ///
    /// Called by the GLK coordinator's `destroy` path to erase all drawer
    /// content blobs from LocusKit's SQLite storage before `close()` releases
    /// the connection. Part of the destruction contract (secfix/ws2-coredelete
    /// §Cluster E): after `wipe_all_content` returns, no verbatim captured
    /// text survives in the LocusKit SQLite rows. The application layer
    /// (moot-mgr) then deletes the SQLite file itself.
    pub fn wipe_all_content(&self) -> Result<(), LocusKitError> {
        self.store.wipe_all_content()
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Resolve the owner identifier from the manifest, falling back to
    /// "estate" when empty. Mirrors the `let changedBy = ...` pattern
    /// repeated across every Swift verb that calls a store mutator.
    fn changed_by_or_estate(&self) -> String {
        let id = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        if id.is_empty() {
            "estate".to_string()
        } else {
            id
        }
    }

    /// Current time as epoch **milliseconds**. Used anywhere a store method
    /// takes `now: i64`.
    ///
    /// Milliseconds is the unit the whole boundary consumes: `HLCGenerator::send`
    /// (`hlc.rs`) stores the value directly as `last_physical`, and
    /// `TypedValue::Timestamp` (`persistence_kit::sqlite`) serializes it with
    /// `from_timestamp_millis`. Nothing multiplies on the way in — the store
    /// passes the caller's value straight through.
    ///
    /// Passing seconds here backdates the event to 1970. That is not merely a
    /// wrong date: audit consumers order by packed HLC, so once a restart clears
    /// the in-memory generator, a seconds-valued mutation sorts *before* the
    /// capture it modified.
    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    // -----------------------------------------------------------------------
    // mutate
    // -----------------------------------------------------------------------

    /// Mutate a row along one of its mutation axes per cookbook §7.8.3.
    ///
    /// `MutationKind::Confirm` moves the confirmation axis (provenance bits
    /// 18–23, cookbook §2.5) to `UserConfirmed` via
    /// `DrawerStore::mutate_provenance`. All state-axis kinds (Reject, Contest,
    /// Resolve, Accept, Supersede, Revive) route through
    /// `DrawerStore::mutate_state`, which validates against the canonical
    /// automaton (cookbook §9.2). Adjective-axis kinds (CorrectSensitivity,
    /// CorrectTrust, CorrectExportability) recompose `adjective_bitmap` and
    /// persist via `DrawerStore::mutate_adjective`. Guard conditions: Resolve
    /// requires current state == Contested; Accept requires trust >= Canonical (S-1);
    /// Revive requires current state in Cluster B. Mirror of Swift `Estate.mutate`.
    pub fn mutate(
        &self,
        row_id: &str,
        kind: MutationKind,
        _payload: Option<&str>,
    ) -> Result<(), LocusKitError> {
        match kind {
            MutationKind::Confirm => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;

                // Confirmation lives in provenance bits 18–23; write_field
                // clears that field and ORs in UserConfirmed, leaving the
                // other provenance axes intact.
                let new_provenance = bit_field::write_field(
                    Confirmation::UserConfirmed.raw_value(),
                    drawer.provenance,
                    18,
                    6,
                );

                let changed_by = self.changed_by_or_estate();
                // Store `now` is epoch-milliseconds (HLC physical_time).
                let now = Self::now_ms();

                self.store.mutate_provenance(
                    row_id,
                    new_provenance,
                    &changed_by,
                    Some("confirmed via Estate.mutate"),
                    now,
                )
            }
            MutationKind::Reject => {
                self.store.get_drawer(row_id)?.ok_or_else(|| LocusKitError::DrawerNotFound {
                    id: row_id.to_string(),
                })?;
                // Pending → reject → Rejected and Contested → reject → Rejected
                // per automaton §9.2. A contested memory judged false must be
                // terminally rejectable; the automaton now admits both source
                // states via the same verb. The DrawerStore write gate consults
                // SubstrateLib's transition table and returns
                // `InvalidContent(disciplineViolation)` if the current state is
                // anything else (e.g. Active, Accepted), so no extra guard is
                // needed here.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Rejected,
                    RowVerb::Reject,
                    &changed_by,
                    Some(_payload.unwrap_or("rejected via Estate.mutate")),
                    now,
                )
            }

            MutationKind::Contest => {
                self.store.get_drawer(row_id)?.ok_or_else(|| LocusKitError::DrawerNotFound {
                    id: row_id.to_string(),
                })?;
                // active/pending → contest → contested per automaton §9.2.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Contested,
                    RowVerb::Contest,
                    &changed_by,
                    Some(_payload.unwrap_or("contested via Estate.mutate")),
                    now,
                )
            }

            MutationKind::Resolve => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                // Guard: resolve is only legal from Contested per automaton
                // (contested → resolveContest → active). Any other prior state
                // throws before touching the store.
                let state = State::from_raw(bit_field::extract_field(drawer.adjective_bitmap, 0, 6));
                if state != State::Contested {
                    return Err(LocusKitError::InvalidContent(format!(
                        "resolve: only valid from Contested (current: {state:?})"
                    )));
                }
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Active,
                    RowVerb::ResolveContest,
                    &changed_by,
                    Some(_payload.unwrap_or("resolved via Estate.mutate")),
                    now,
                )
            }

            MutationKind::Accept => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                // S-1 pre-check (cookbook §9.5.1): accepted rows require trust ≥
                // Canonical. Raising this guard before the store call produces a
                // clearer diagnostic than the raw invariant message the gate emits.
                let trust = Trust::from_raw(bit_field::extract_field(drawer.adjective_bitmap, 18, 6));
                if trust < Trust::Canonical {
                    return Err(LocusKitError::InvalidContent(format!(
                        "accept: S-1 requires trust >= Canonical (current: {trust:?})"
                    )));
                }
                // active → promote → accepted per automaton §9.2.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Accepted,
                    RowVerb::Promote,
                    &changed_by,
                    Some(_payload.unwrap_or("accepted via Estate.mutate")),
                    now,
                )
            }

            MutationKind::Supersede => {
                self.store.get_drawer(row_id)?.ok_or_else(|| LocusKitError::DrawerNotFound {
                    id: row_id.to_string(),
                })?;
                // active/accepted → supersede → superseded per automaton §9.2.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Superseded,
                    RowVerb::Supersede,
                    &changed_by,
                    Some(_payload.unwrap_or("superseded via Estate.mutate")),
                    now,
                )
            }

            MutationKind::Revive => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                let state = State::from_raw(bit_field::extract_field(drawer.adjective_bitmap, 0, 6));
                // revive restores a terminal-but-recoverable row to active.
                // Legality is decided per source state (cookbook §9.3, §6.2):
                //
                //   Decayed   → Active   LEGAL (re-observation revives)
                //   Withdrawn → Active   LEGAL (unwithdraw an explicit retraction)
                //   Expired   → Active   LEGAL (TTL revive; no fresh TTL until a
                //                                later mutation sets one)
                //   Superseded→ Active   CONDITIONAL on the lineage rule below
                //   Active/Pending/Contested/Accepted   REFUSED (not historical —
                //                                a live row has nothing to revive)
                //   Rejected  → Active   REFUSED (a review verdict; the recovery
                //                                path is re-propose, not revive)
                //   Tombstoned→ Active   REFUSED (hard delete; content erased)
                //
                // Each refusal is a real domain rule surfaced as
                // `DisciplineViolation` naming the rule — never `NotSupported`.
                match state {
                    // Unconditionally recoverable Cluster-B states.
                    State::Decayed | State::Withdrawn | State::Expired => {}
                    State::Superseded => {
                        // Lineage rule (cookbook §6.2): a superseded row was
                        // replaced by a successor sharing its lineage_id. If
                        // that successor (or a later link) still lives — i.e.
                        // some row in this lineage is in Cluster A — reviving
                        // the predecessor would put TWO active rows at the same
                        // lineage head. That is a domain contradiction, so
                        // revive refuses and names the conflicting successor.
                        // When NO living successor remains (it was itself
                        // withdrawn/expired/decayed or tombstoned/expunged), the
                        // head is vacant and the predecessor may reclaim it.
                        if let Some(successor_id) = self.store.living_successor_in_lineage(
                            &drawer.lineage_id.to_string(),
                            row_id,
                        )? {
                            return Err(LocusKitError::DisciplineViolation {
                                from: state.raw_value(),
                                to: State::Active.raw_value(),
                                reason: format!(
                                    "revive: superseded row has a living successor \
                                     ({successor_id}) holding the lineage head; revive the \
                                     lineage head or withdraw/expunge the successor first"
                                ),
                            });
                        }
                    }
                    State::Active | State::Pending | State::Contested | State::Accepted => {
                        // Cluster A — already live; nothing to revive.
                        return Err(LocusKitError::DisciplineViolation {
                            from: state.raw_value(),
                            to: State::Active.raw_value(),
                            reason: format!(
                                "revive: row is already live ({state:?}); revive applies \
                                 only to historical Cluster-B states"
                            ),
                        });
                    }
                    State::Rejected => {
                        // Cluster C — a review verdict, not a recoverable
                        // historical state. Re-entry is via re-proposal.
                        return Err(LocusKitError::DisciplineViolation {
                            from: state.raw_value(),
                            to: State::Active.raw_value(),
                            reason: "revive: rejected rows are not revivable; a rejection \
                                     is a review verdict — re-propose the content instead"
                                .to_string(),
                        });
                    }
                    State::Tombstoned => {
                        // Cluster C terminal — content erased; row gone in every
                        // sense but the audit trail.
                        return Err(LocusKitError::DisciplineViolation {
                            from: state.raw_value(),
                            to: State::Active.raw_value(),
                            reason: "revive: tombstoned rows are unrecoverable; the \
                                     content blob has been expunged"
                                .to_string(),
                        });
                    }
                }
                // decayed/withdrawn/expired/superseded(head vacant) → active.
                // The automaton legalizes all four via Observe (re-observation
                // revives); the lineage contradiction for superseded was caught
                // above, so by here the transition is unconditionally legal.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_state(
                    row_id,
                    State::Active,
                    RowVerb::Observe,
                    &changed_by,
                    Some(_payload.unwrap_or("revived via Estate.mutate")),
                    now,
                )
            }

            MutationKind::CorrectSensitivity(sensitivity) => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                // Sensitivity lives in adjective_bitmap bits 6–11 (cookbook §2.3,
                // 6-bit scale-gapped field; raws 0/16/32/48 for the four tiers).
                let new_adjective = bit_field::write_field(
                    sensitivity.raw_value(),
                    drawer.adjective_bitmap,
                    6,
                    6,
                );
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_adjective(
                    row_id,
                    new_adjective,
                    &changed_by,
                    Some(_payload.unwrap_or("sensitivity corrected via Estate.mutate")),
                    now,
                )
            }

            MutationKind::CorrectTrust(trust) => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                // Trust lives in adjective_bitmap bits 18–23 (cookbook §2.3,
                // 6-bit gradient field; raws 0–6 for Verbatim through Ambient).
                let new_adjective = bit_field::write_field(
                    trust.raw_value(),
                    drawer.adjective_bitmap,
                    18,
                    6,
                );
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_adjective(
                    row_id,
                    new_adjective,
                    &changed_by,
                    Some(_payload.unwrap_or("trust corrected via Estate.mutate")),
                    now,
                )
            }

            MutationKind::CorrectExportability(exportability) => {
                let drawer = self.store.get_drawer(row_id)?.ok_or_else(|| {
                    LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    }
                })?;
                // Exportability lives in adjective_bitmap bits 12–17 (cookbook §2.3,
                // 6-bit scale-gapped field; raw 0 = Private, raw 32 = Public).
                // write_field clears that 6-bit window and ORs in the new value,
                // preserving all other adjective axes (state, sensitivity, trust,
                // obligation flags). This is the write-side counterpart to the
                // existing `exportability()` accessor in adjectives.rs
                // (DEBT-1: this is the mutation path that sets the exportability bit).
                // Mirrors Swift MutationKind::CorrectExportability in EstateVerbs.swift.
                let new_adjective = bit_field::write_field(
                    exportability.raw_value(),
                    drawer.adjective_bitmap,
                    12,
                    6,
                );
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_ms();
                self.store.mutate_adjective(
                    row_id,
                    new_adjective,
                    &changed_by,
                    Some(_payload.unwrap_or("exportability corrected via Estate.mutate")),
                    now,
                )
            }
            MutationKind::SetSubject(subject) => {
                if self.store.get_drawer(row_id)?.is_none() {
                    return Err(LocusKitError::DrawerNotFound {
                        id: row_id.to_string(),
                    });
                }
                // Backfill/correction write path for the subject trio
                // (SPEC § 14). No bitmap, no state transition, no
                // container-fingerprint rollup — the store verb writes the
                // three columns in one UPDATE and enforces the 1–120-char
                // contract (B-18). The producer at this boundary is the
                // calling AI, so the pipeline version is ai-v1. Mirrors
                // Swift MutationKind.setSubject in EstateVerbs.swift.
                let now = Self::now_ms();
                self.store
                    .set_subject_representation(row_id, &subject, SUBJECT_PIPELINE_AI_V1, now)
                    .map(|_| ())
            }
        }
    }

    /// Reanchor a drawer to a different room and/or lattice position.
    ///
    /// Moves the row's placement: `to_room`/`to_wing` resolve to a new
    /// room node and update `parent_node_id` via NodeStore;
    /// `to_lattice` updates the lattice anchor columns. At least one must
    /// be supplied (belt-and-suspenders; the primary empty check is GLK's
    /// boundary). An absent row returns `LocusKitError::DrawerNotFound`.
    ///
    /// Delegates to `DrawerStore::reanchor_gated`, which reads the row,
    /// admits a `Mutate` event through the gate (active→active self-loop,
    /// anchor delta carried via before/after anchor), and writes the updated
    /// columns + the sealed audit event. The three bitmaps are unchanged.
    pub fn reanchor(
        &self,
        row_id: &str,
        to_room: Option<&str>,
        to_wing: Option<&str>,
        to_lattice: Option<crate::estate_types::LatticeAnchor>,
    ) -> Result<(), LocusKitError> {
        if to_room.is_none() && to_wing.is_none() && to_lattice.is_none() {
            return Err(LocusKitError::InvalidContent(
                "reanchor requires toRoom, toWing, or toLattice".to_string(),
            ));
        }
        // Wing non-empty invariant: when to_wing is supplied it must be
        // non-empty. An empty wing string would create a nameless wing
        // node and violate the same invariant the capture path enforces.
        // Mirror the capture-path guard so reanchor cannot produce estate
        // state that capture would refuse to create.
        if let Some(w) = to_wing {
            if w.trim().is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "reanchor: to_wing must not be empty or whitespace-only".to_string(),
                ));
            }
        }
        // Room non-empty invariant: mirror the capture-path guard. An empty
        // room is the ContainerFingerprintStore wing-rollup sentinel and is
        // excluded from room_level_entries — a drawer reanchored to "" is
        // skipped by pruned recall paths (hidden from recall).
        if let Some(r) = to_room {
            if r.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "reanchor: to_room must not be empty".to_string(),
                ));
            }
        }
        // UDC non-empty invariant (spec I-5): mirror the capture-path guard.
        if let Some(ref l) = to_lattice {
            if l.udc_code.is_empty() {
                return Err(LocusKitError::InvalidContent(
                    "reanchor: to_lattice.udc_code must not be empty (spec I-5)".to_string(),
                ));
            }
        }
        if self.store.get_drawer(row_id)?.is_none() {
            return Err(LocusKitError::DrawerNotFound {
                id: row_id.to_string(),
            });
        }
        let changed_by = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let changed_by = if changed_by.is_empty() {
            "estate".to_string()
        } else {
            changed_by
        };
        // Store expects epoch milliseconds and passes the value straight to the
        // HLC — the same contract `reanchor_anchor` relies on below.
        let now = Self::now_ms();
        self.store.reanchor_gated(
            row_id,
            to_room,
            to_wing,
            to_lattice,
            &changed_by,
            Some("reanchored via Estate.reanchor"),
            now,
        )
    }

    /// Update a drawer's lattice anchor with an explicit audit identity and
    /// reason, rather than the generic estate-owner attribution `reanchor`
    /// (above) stamps. Mirrors `Estate.reanchorAnchor(rowID:toLattice:changedBy:reason:now:)`
    /// in `EstateVerbs.swift` semantically (same purpose: let an automated
    /// caller — e.g. an MCP tool applying a bulk repair — stamp its own
    /// identity and reason into the audit trail instead of inheriting
    /// `reanchor`'s generic "estate owner / reanchored via Estate.reanchor"
    /// attribution). Unlike the Swift port, `now` is generated internally
    /// via `Self::now_ms()` rather than threaded in as a parameter — this
    /// mirrors `reanchor`'s own `now` handling exactly (same layer, same
    /// convention) rather than introducing a second `now`-unit contract for
    /// `reanchor_gated` in this file.
    pub fn reanchor_anchor(
        &self,
        row_id: &str,
        to_lattice: crate::estate_types::LatticeAnchor,
        changed_by: &str,
        reason: &str,
    ) -> Result<(), LocusKitError> {
        if self.store.get_drawer(row_id)?.is_none() {
            return Err(LocusKitError::DrawerNotFound {
                id: row_id.to_string(),
            });
        }
        // Store expects epoch milliseconds and passes the value straight to the
        // HLC — same contract `reanchor` relies on via `Self::now_ms()`.
        let now = Self::now_ms();
        self.store.reanchor_gated(
            row_id,
            None,
            None,
            Some(to_lattice),
            changed_by,
            Some(reason),
            now,
        )
    }

    // MARK: - propose

    /// Create a proposal targeting a row in the estate. Mirrors `Estate.propose` in Swift.
    ///
    /// Validates that the target drawer exists, assembles `operational_bitmap`
    /// from `ProposeFrame.kind` (bits 0–5), `ProposalTargetObjectType::Drawer`
    /// (bits 6–11, raw 0), and the three provenance axes `frame.confirmation`
    /// (bits 12–17), `frame.generated_by` (bits 18–23), and `frame.confidence`
    /// (bits 24–29), sets `adjective_bitmap` state to `State::Pending` (raw 1)
    /// at bits 0–5, derives `candidate_state` and `lattice_anchor` from the target
    /// drawer, then calls `DrawerStore::add_proposal`. Per cookbook §§2.4, 10.7.
    ///
    /// - `frame.target` must be non-empty and identify an existing drawer;
    ///   returns `LocusKitError::DrawerNotFound` otherwise.
    /// - `now` is epoch seconds (TEXT ISO8601 stored in the proposals table).
    pub fn propose(
        &self,
        frame: ProposeFrame,
        now: i64,
    ) -> Result<crate::proposal::Proposal, LocusKitError> {
        if frame.target.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "propose target must not be empty".to_string(),
            ));
        }
        let target_drawer = self
            .store
            .get_drawer(&frame.target)?
            .ok_or_else(|| LocusKitError::DrawerNotFound { id: frame.target.clone() })?;

        // Operational bitmap, five typed axes per cookbook §2.4, each packed into
        // its own 6-bit window via the conformance-gated bit_field::write_field:
        //   bits 0–5   ProposalKind             = frame.kind
        //   bits 6–11  ProposalTargetObjectType = Drawer (propose targets a drawer)
        //   bits 12–17 ProposalConfirmationSource = frame.confirmation
        //   bits 18–23 ProposalGeneratedByClass   = frame.generated_by
        //   bits 24–29 ProposalConfidenceBucket   = frame.confidence
        // The three provenance axes default (Human / DreamingDaemon / Null) to
        // their raw-0 values, so a frame that leaves them unset yields the same
        // bitmap as before the slots were wired. The read accessors in
        // proposal_operational.rs (confirmation_source / generated_by_class /
        // confidence_bucket) decode these exact positions.
        // bit_field::write_field(value, into_bitmap, shift, width).
        let mut op_bitmap = bit_field::write_field(frame.kind.raw_value(), 0i64, 0, 6);
        op_bitmap = bit_field::write_field(
            crate::proposal_operational::ProposalTargetObjectType::Drawer.raw_value(),
            op_bitmap,
            6,
            6,
        );
        op_bitmap = bit_field::write_field(frame.confirmation.raw_value(), op_bitmap, 12, 6);
        op_bitmap = bit_field::write_field(frame.generated_by.raw_value(), op_bitmap, 18, 6);
        op_bitmap = bit_field::write_field(frame.confidence.raw_value(), op_bitmap, 24, 6);

        // Adjective bitmap: state .pending at bits 0–5, raw value 1.
        // bit_field::write_field(value, into_bitmap, shift, width).
        let adj_bitmap = bit_field::write_field(
            crate::adjectives::State::Pending as i64,
            0i64,
            0,
            6,
        );
        // Sensitivity inheritance (§D.2): stamp proposal's adjective sensitivity
        // in bits 6–11 with the target drawer's sensitivity tier. A proposal IS a
        // derived artifact of its target — it must never be less sensitive than what
        // it acts on. Mirrors Swift `EstateVerbs.propose` (lines 1700-1718).
        let adj_bitmap = bit_field::write_field(
            target_drawer.adjective_sensitivity().raw_value(),
            adj_bitmap,
            6,
            6,
        );

        // Candidate state derives from the target drawer's current adjective_bitmap —
        // the accept path applies this to the target if confirmed.
        let candidate_state = target_drawer.adjective_bitmap;

        // Lattice anchor derives from the target drawer's four anchor fields.
        let lattice_anchor = crate::estate_types::LatticeAnchor {
            udc_code: target_drawer.udc_code.clone(),
            udc_facets: target_drawer.udc_facets.clone(),
            wikidata_qid: target_drawer.wikidata_qid.clone(),
            wikidata_qids_secondary: target_drawer.wikidata_qids_secondary.clone(),
        };

        let proposal = crate::proposal::Proposal {
            id: Uuid::new_v4().to_string(),
            target_row_id: frame.target,
            justification: frame.justification,
            candidate_state,
            lattice_anchor,
            adjective_bitmap: adj_bitmap,
            operational_bitmap: op_bitmap,
            provenance_bitmap: 0,
            filed_at: now,
        };
        self.store.add_proposal(&proposal)?;
        Ok(proposal)
    }

    // MARK: - associate

    /// Create an association between two rows in the estate. Mirrors `Estate.associate` in Swift.
    ///
    /// Validates both endpoints, looks up both drawers, derives `lattice_anchor`
    /// from endpoint A (the source), sets state to `.active` (associations are born
    /// active, adjectiveBitmap = 0), and calls `DrawerStore::add_association`.
    /// Per cookbook §10.8.
    ///
    /// - `frame.a` and `frame.b` must be non-empty and identify existing drawers;
    ///   returns `LocusKitError::DrawerNotFound` on any missing endpoint.
    /// - `now` is epoch seconds.
    pub fn associate(
        &self,
        frame: AssociateFrame,
        now: i64,
    ) -> Result<crate::association::Association, LocusKitError> {
        if frame.a.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "associate endpoint a must not be empty".to_string(),
            ));
        }
        if frame.b.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "associate endpoint b must not be empty".to_string(),
            ));
        }
        let drawer_a = self
            .store
            .get_drawer(&frame.a)?
            .ok_or_else(|| LocusKitError::DrawerNotFound { id: frame.a.clone() })?;
        let drawer_b = self
            .store
            .get_drawer(&frame.b)?
            .ok_or_else(|| LocusKitError::DrawerNotFound { id: frame.b.clone() })?;

        // Resolve wing/room names from the node tree for each drawer's
        // parent_node_id. Room node (depth 2) → parent is wing node (depth 1).
        // Falls back to empty strings if node_store is unavailable.
        let resolve_names = |parent_node_id: &str| -> (String, String) {
            if let Some(ref ns) = self.node_store {
                let room_uuid = Uuid::parse_str(parent_node_id).ok();
                let room_node = room_uuid.and_then(|u| ns.get_node(u).ok().flatten());
                let room_name = room_node
                    .as_ref()
                    .map(|n| n.display_name.clone())
                    .unwrap_or_default();
                let wing_node = room_node
                    .and_then(|n| n.parent_id)
                    .and_then(|pid| ns.get_node(pid).ok().flatten());
                let wing_name = wing_node
                    .map(|n| n.display_name)
                    .unwrap_or_default();
                (wing_name, room_name)
            } else {
                (String::new(), String::new())
            }
        };

        let (source_wing, source_room) = resolve_names(&drawer_a.parent_node_id);
        let (target_wing, target_room) = resolve_names(&drawer_b.parent_node_id);

        // Association label derives from endpoint A's room and endpoint B's room.
        let label = format!("{}→{}", source_room, target_room);

        // Adjective bitmap: state .active is the zero baseline (raw 0),
        // so adjective_bitmap = 0. Associations are born active, not pending.

        // Lattice anchor derives from endpoint A (the source drawer).
        let lattice_anchor = crate::estate_types::LatticeAnchor {
            udc_code: drawer_a.udc_code.clone(),
            udc_facets: drawer_a.udc_facets.clone(),
            wikidata_qid: drawer_a.wikidata_qid.clone(),
            wikidata_qids_secondary: drawer_a.wikidata_qids_secondary.clone(),
        };

        let association = crate::association::Association {
            id: Uuid::new_v4().to_string(),
            source_wing,
            source_room,
            source_drawer_id: Some(drawer_a.id.clone()),
            target_wing,
            target_room,
            target_drawer_id: Some(drawer_b.id.clone()),
            label,
            lattice_anchor,
            adjective_bitmap: 0, // .active is raw 0
            operational_bitmap: 0,
            provenance_bitmap: 0,
            added_by: "associate".to_string(),
            filed_at: now,
            tombstoned_at: None,
            removed_by_batch: None,
        };
        self.store.add_association(&association)?;
        Ok(association)
    }

    // MARK: - learn

    /// Bring an external reference into the estate, grounded against its
    /// source. Per spec § 7.8.2 / cookbook §10.9. Mirrors Swift
    /// `Estate.learn`.
    ///
    /// The reference's genuine lattice anchor is derived from
    /// `frame.source` — a `SourceCatalogEntry` carries the source's
    /// classified lattice position, which the learned reference inherits.
    /// No sentinel anchor is ever fabricated (P1 mandate, Bob's board
    /// item 7). The verb:
    ///
    /// 1. Validates `frame.handle` is non-empty — the only fail-loud path
    ///    on a normal beta call (`LocusKitError::InvalidContent`).
    /// 2. Catalogs `frame.source` durably if no entry already holds its
    ///    handle (idempotent by source handle), then resolves the catalog
    ///    entry whose anchor the reference inherits.
    /// 3. Writes a `LearnedReference` anchored to the catalog entry's
    ///    genuine anchor, with `source_catalog_id` pointing at it and the
    ///    operational bitmap encoding `mode` (bit 12) and `refresh_policy`
    ///    (bits 0–5) per cookbook § 2.4.
    ///
    /// - `now` is epoch seconds (deterministic write timestamp).
    pub fn learn(
        &self,
        frame: LearnFrame,
        now: i64,
    ) -> Result<crate::learned_reference::LearnedReference, LocusKitError> {
        // Fail loud only on genuinely invalid input. An empty reference
        // handle has nothing to point at — there is no reference to learn.
        if frame.handle.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "learn: handle must not be empty".to_string(),
            ));
        }

        // Resolve (or catalog) the source. The source carries the genuine
        // anchor; cataloging is idempotent by source handle so repeated
        // learns from one source share a single catalog entry.
        let catalog_entry = match self
            .store
            .source_catalog_entry_for_handle(&frame.source.handle)?
        {
            Some(existing) => existing,
            None => {
                self.store.add_source_catalog_entry(&frame.source)?;
                frame.source.clone()
            }
        };

        // Encode mode (bit 12) and refresh policy (bits 0–5) into the
        // operational bitmap per cookbook § 2.4. The source acquisition
        // axis (bits 13–18) maps from the catalog entry's kind so the
        // reference records the channel it arrived through.
        let mut operational: i64 = 0;
        operational =
            bit_field::write_field(frame.refresh_policy.raw_value(), operational, 0, 6);
        operational = bit_field::write_flag(
            frame.mode == crate::learned_reference::LearnMode::ByIngestion,
            operational,
            12,
        );
        operational =
            bit_field::write_field(catalog_entry.kind.raw_value(), operational, 13, 6);

        let mut reference = crate::learned_reference::LearnedReference::new(
            Uuid::new_v4().to_string(),
            catalog_entry.id.clone(),
            frame.handle.clone(),
            // Genuine anchor, inherited from the source's catalog entry —
            // never a sentinel.
            catalog_entry.lattice_anchor.clone(),
            "learn".to_string(),
            now,
        );
        reference.operational_bitmap = operational;
        self.store.add_learned_reference(&reference)?;
        Ok(reference)
    }

}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Format an epoch-seconds timestamp as an ISO8601 string for storage in
/// TEXT columns (fleet date-storage rule: TEXT ISO8601, never REAL).
/// Used by `recall` to stamp `recalled_at` on `RecallTraceItem` rows.
///
/// Produces the canonical fractional-seconds form `YYYY-MM-DDTHH:MM:SS.000Z`,
/// matching Swift's `LKISO8601` formatter (`.withInternetDateTime +
/// .withFractionalSeconds`) and the `format_iso8601` helper in
/// `drawer_store_inmemory.rs`. This MUST agree with `format_iso8601` because a
/// `recalledAt` value written here is parsed back to epoch and re-rendered via
/// `format_iso8601` on durable-backend reads (the `.timestamp` column decodes
/// to `TypedValue::Timestamp`); a format drift would make the read-back string
/// differ from the written string. Input is epoch MILLISECONDS; the
/// millisecond component is emitted as the 3-digit `.SSS` field.
fn epoch_to_iso8601(epoch_ms: i64) -> String {
    // Simple Gregorian calendar conversion without external crates.
    // Accurate for dates in the range 2001–2100 (the LocusKit operational
    // window); leap-second handling matches the `drawer_store_inmemory`
    // implementation — both ignore leap seconds. The calendar helper is
    // seconds-based, so split the millisecond fraction out here.
    let secs = epoch_ms.div_euclid(1000);
    let millis = epoch_ms.rem_euclid(1000);
    let (year, month, day, hour, minute, second) = epoch_to_components(secs);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        year, month, day, hour, minute, second, millis
    )
}

/// Decompose epoch seconds into (year, month, day, hour, minute, second).
/// Gregorian calendar, UTC. Mirrors `epoch_to_components` in
/// `drawer_store_inmemory.rs` so both sites produce the same string.
fn epoch_to_components(epoch: i64) -> (i64, i64, i64, i64, i64, i64) {
    let second = epoch % 60;
    let epoch = epoch / 60;
    let minute = epoch % 60;
    let epoch = epoch / 60;
    let hour = epoch % 24;
    let mut days = epoch / 24;

    // Days since 1970-01-01.
    let mut year: i64 = 1970;
    loop {
        let days_in_year = if is_leap(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }
    let months = [
        31i64,
        if is_leap(year) { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month: i64 = 1;
    for days_in_month in &months {
        if days < *days_in_month {
            break;
        }
        days -= days_in_month;
        month += 1;
    }
    (year, month, days + 1, hour, minute, second)
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::drawer_operational::CaptureChannel;
    use crate::drawer_store_inmemory::InMemoryDrawerStore;
    use crate::estate_types::{LatticeAnchor, OwnerCredentials};
    use crate::filter::Filter;
    use std::sync::Arc;

    fn make_estate() -> Estate {
        // InMemoryDrawerStore::new allocates InMemoryStorage internally —
        // backend identity is visible at the type, not the argument.
        let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000_000, None).unwrap());
        Estate::create(store, OwnerCredentials::new("owner"), None).unwrap()
    }

    fn basic_capture(estate: &Estate, content: &str, room: &str) -> Drawer {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        // Epoch MILLISECONDS.
        estate.capture(frame, 1_700_000_001_000).unwrap()
    }

    // --- capture provenance: confirmation + confidence axes ---

    #[test]
    fn capture_default_provenance_confirmation_confidence_zero() {
        // A frame that omits confirmation/confidence must produce the SAME
        // provenance bytes as before those slots existed: both default to raw
        // 0 (Unconfirmed / Null), so the confirmation window (bits 18–23) and
        // confidence window (bits 24–29) are both zero. Byte-identical default.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "default provenance", "kitchen");
        assert_eq!(
            Confirmation::from_raw(bit_field::extract_field(drawer.provenance, 18, 6)),
            Confirmation::Unconfirmed
        );
        assert_eq!(
            crate::provenance::Confidence::from_raw(bit_field::extract_field(
                drawer.provenance,
                24,
                6
            )),
            crate::provenance::Confidence::Null
        );
        // Combined confirmation+confidence window (bits 18–29) is zero.
        assert_eq!(drawer.provenance & 0x3FFC_0000, 0);
    }

    #[test]
    fn capture_non_default_provenance_confirmation_confidence_round_trips() {
        // A daemon capturing with a known review status and confidence band
        // records them at birth — no separate confirm/enrichment mutation.
        let estate = make_estate();
        let mut frame = CaptureFrame::new(
            "daemon-confirmed",
            CaptureChannel::Typed,
            "kitchen",
            LatticeAnchor::udc("5"),
            "daemon",
            "test-v1",
        );
        frame.confirmation = Confirmation::AutomatedConfirmed;
        frame.confidence = crate::provenance::Confidence::High;
        let drawer = estate.capture(frame, 1_700_000_001).unwrap();
        assert_eq!(
            Confirmation::from_raw(bit_field::extract_field(drawer.provenance, 18, 6)),
            Confirmation::AutomatedConfirmed
        );
        assert_eq!(
            crate::provenance::Confidence::from_raw(bit_field::extract_field(
                drawer.provenance,
                24,
                6
            )),
            crate::provenance::Confidence::High
        );
        // The two new axes do not disturb source_type (bits 0–5, default User=0)
        // or provenance sensitivity (bits 30–35, default Normal=0).
        assert_eq!(bit_field::extract_field(drawer.provenance, 0, 6), 0);
        assert_eq!(bit_field::extract_field(drawer.provenance, 30, 6), 0);
    }

    // --- capture validation ---

    #[test]
    fn capture_empty_content_is_invalid() {
        let estate = make_estate();
        let mut frame = CaptureFrame::new(
            "",
            CaptureChannel::Typed,
            "room",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        frame.content = String::new();
        let err = estate.capture(frame, 1_700_000_000).unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    #[test]
    fn capture_empty_udc_is_invalid() {
        let estate = make_estate();
        let frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            "room",
            LatticeAnchor::udc(""), // empty UDC code — violates I-5
            "alice",
            "test-v1",
        );
        let err = estate.capture(frame, 1_700_000_000).unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    // --- capture bitmap assembly ---

    #[test]
    fn capture_sets_active_state_in_adjective_bitmap() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "hello", "kitchen");
        // State Active = 0; bits 0–3 must be zero.
        let state = State::from_raw(drawer.adjective_bitmap & 0x3F);
        assert_eq!(state, State::Active);
    }

    #[test]
    fn capture_stores_content_and_resolves_room() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "my content", "study");
        assert_eq!(drawer.content, "my content");
        // room is resolved from the node tree via parent_node_id,
        // not stored on the Drawer struct. Verify via resolve_node_names.
        let names = estate.store.resolve_node_names(&[drawer.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&drawer.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "study");
    }

    #[test]
    fn capture_uses_default_wing_name() {
        // all captures use the fixed DEFAULT_WING_NAME constant
        // ("Agentic Memory") regardless of the estate's owner identifier.
        // The prior dynamic derivation ("wing_<owner>" / "wing_default")
        // is retired.
        // wing resolved from node tree via parent_node_id.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "x", "r");
        let names = estate.store.resolve_node_names(&[drawer.parent_node_id.clone()]).unwrap();
        let (wing, _) = names.get(&drawer.parent_node_id).expect("wing node must resolve");
        assert_eq!(wing, DEFAULT_WING_NAME);
    }

    // --- capture container-fingerprint maintenance (P0-PARITY #33) ---

    #[test]
    fn capture_ors_into_room_level_container_fingerprint() {
        // After a capture the room-level container aggregate is non-empty —
        // the capture-time OR-in maintained it. Before this fix the Rust
        // capture path never OR'd, so the aggregate stayed empty and the
        // maintenance fingerprint-drift signal read nothing.
        let estate = make_estate();
        let d = basic_capture(&estate, "alpha", "study");

        let entries = estate.store.room_level_fingerprints().unwrap();
        assert_eq!(entries.len(), 1, "the captured drawer's room is enumerated");
        let entry = &entries[0];
        // wing is resolved from the node tree, not stored on Drawer.
        let names = estate.store.resolve_node_names(&[d.parent_node_id.clone()]).unwrap();
        let (d_wing, _) = names.get(&d.parent_node_id).expect("room node must resolve");
        assert_eq!(&entry.wing, d_wing);
        assert_eq!(entry.room, "study");
        // The room aggregate equals the OR of the (single) captured drawer's
        // own bitmaps — the canonical container-fingerprint definition.
        assert_eq!(entry.fingerprint.adjective, d.adjective_bitmap);
        assert_eq!(entry.fingerprint.operational, d.operational_bitmap);
        assert_eq!(entry.fingerprint.provenance, d.provenance);
    }

    #[test]
    fn capture_n_drawers_room_aggregate_is_or_fold_of_all() {
        // Capture N drawers into one room; the room aggregate is the bitwise
        // OR of every drawer's three bitmap fields. This is the bit-identical
        // shape Swift produces: same drawer contents → same room aggregate on
        // both ports, because both OR the identical per-drawer bitmaps through
        // the conformance-gated or_reduce kernel.
        let estate = make_estate();
        let mut expected_adj = 0i64;
        let mut expected_op = 0i64;
        let mut expected_prov = 0i64;
        for i in 0..5 {
            let d = basic_capture(&estate, &format!("c{i}"), "den");
            expected_adj |= d.adjective_bitmap;
            expected_op |= d.operational_bitmap;
            expected_prov |= d.provenance;
        }
        let entry = estate
            .store
            .room_level_fingerprints()
            .unwrap()
            .into_iter()
            .find(|e| e.room == "den")
            .expect("den room aggregate present");
        assert_eq!(entry.fingerprint.adjective, expected_adj);
        assert_eq!(entry.fingerprint.operational, expected_op);
        assert_eq!(entry.fingerprint.provenance, expected_prov);
    }

    #[test]
    fn capture_distinct_rooms_yield_distinct_room_aggregates() {
        // Two rooms each get their own room-level aggregate; the wing-rollup
        // row (room == "") is excluded by room_level_fingerprints, so exactly
        // two entries appear.
        let estate = make_estate();
        basic_capture(&estate, "a", "study");
        basic_capture(&estate, "b", "kitchen");
        let entries = estate.store.room_level_fingerprints().unwrap();
        assert_eq!(entries.len(), 2);
        let mut rooms: Vec<String> = entries.iter().map(|e| e.room.clone()).collect();
        rooms.sort();
        assert_eq!(rooms, vec!["kitchen".to_string(), "study".to_string()]);
    }

    #[test]
    fn populated_aggregate_drives_container_pruning_decision() {
        // Component-level prune decision over the populated aggregate. Capture
        // a hasVoice drawer into room r1 and a hasImage drawer into room r2;
        // the capture-time OR-in records each room's feature bits. A chain
        // requiring hasVoice prunes r2 (its OR lacks the bit) and keeps r1.
        // Tests BitmapEvaluator::container_survives directly; the end-to-end
        // recall path wiring is covered by recall_prunes_non_matching_container
        // and result_identity_pruned_vs_unpruned below.
        let estate = make_estate();

        let mut voice = CaptureFrame::new(
            "v", CaptureChannel::Typed, "r1",
            LatticeAnchor::udc("5"), "alice", "test-v1",
        );
        voice.feature_flags = DrawerFeatureFlags::HAS_VOICE;
        estate.capture(voice, 1_700_000_001).unwrap();

        let mut image = CaptureFrame::new(
            "i", CaptureChannel::Typed, "r2",
            LatticeAnchor::udc("5"), "alice", "test-v1",
        );
        image.feature_flags = DrawerFeatureFlags::HAS_IMAGE;
        estate.capture(image, 1_700_000_001).unwrap();

        let entries = estate.store.room_level_fingerprints().unwrap();
        let r1 = entries.iter().find(|e| e.room == "r1").expect("r1 aggregate");
        let r2 = entries.iter().find(|e| e.room == "r2").expect("r2 aggregate");

        let chain = [Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE)];
        // r1 carries the hasVoice bit → survives the prune; r2 does not → pruned.
        assert!(BitmapEvaluator::container_survives(&chain, r1.fingerprint));
        assert!(!BitmapEvaluator::container_survives(&chain, r2.fingerprint));
    }

    #[test]
    fn reopen_backfills_container_aggregate_from_active_drawers() {
        // Soundness contract (spec § 11.5): the aggregate must cover every
        // active row. Capture builds the aggregate incrementally; reopening the
        // estate over the same storage rebuilds it from the active drawer set.
        // Either way the room aggregate covers the captured drawer's bits.
        let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000_000, None).unwrap());
        let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();
        let d = basic_capture(&estate, "alpha", "study");

        // Reopen over the SAME backing store; from_manifest backfills.
        let reopened = Estate::open(store, OwnerCredentials::new("owner")).unwrap();
        let entry = reopened
            .store
            .room_level_fingerprints()
            .unwrap()
            .into_iter()
            .find(|e| e.room == "study")
            .expect("study aggregate present after reopen");
        assert_eq!(entry.fingerprint.adjective, d.adjective_bitmap);
        assert_eq!(entry.fingerprint.operational, d.operational_bitmap);
        assert_eq!(entry.fingerprint.provenance, d.provenance);
    }

    // --- recall ---

    #[test]
    fn recall_returns_captured_drawers() {
        let estate = make_estate();
        basic_capture(&estate, "alpha", "den");
        basic_capture(&estate, "beta", "den");
        let frame = RecallFrame::new(vec![
            Filter::InRoom("den".to_string()),
            Filter::CurrentlyBelieve,
            Filter::Unconfirmed,
        ]);
        let stream = estate.recall(frame, 1_700_000_002);
        let rows = stream.collect_all();
        assert_eq!(rows.len(), 2);
    }

    #[test]
    fn recall_excludes_withdrawn_drawers() {
        let estate = make_estate();
        basic_capture(&estate, "live", "hall");
        let d2 = basic_capture(&estate, "gone", "hall");
        estate.withdraw(&d2.id, None, 1_700_000_003).unwrap();

        // .full hydration so the content body is returned — a .structured
        // recall correctly returns content == "" (spec § 7.3 / Swift parity),
        // which would defeat the content assertion below.
        let mut frame = RecallFrame::new(vec![
            Filter::InRoom("hall".to_string()),
            Filter::CurrentlyBelieve,
            Filter::Unconfirmed,
        ]);
        frame.hydration_level = HydrationLevel::Full;
        let stream = estate.recall(frame, 1_700_000_004);
        let rows = stream.collect_all();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].content, "live");
    }

    // --- withdraw ---

    #[test]
    fn withdraw_not_found_returns_error() {
        let estate = make_estate();
        let err = estate
            .withdraw("no-such-id", None, 1_700_000_000)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn withdraw_transitions_state_to_withdrawn() {
        let estate = make_estate();
        let d = basic_capture(&estate, "will be withdrawn", "office");
        estate
            .withdraw(&d.id, Some("test reason"), 1_700_000_002)
            .unwrap();
        let updated = estate.store.get_drawer(&d.id).unwrap().unwrap();
        let state = State::from_raw(updated.adjective_bitmap & 0x3F);
        assert_eq!(state, State::Withdrawn);
    }

    // --- mutate ---

    #[test]
    fn mutate_confirm_transitions_confirmation_to_user_confirmed() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "to confirm", "study");
        // Freshly captured rows are Unconfirmed.
        assert_eq!(drawer.confirmation(), Confirmation::Unconfirmed);

        estate
            .mutate(&drawer.id, MutationKind::Confirm, None)
            .unwrap();

        // Re-read: the confirmation axis is now UserConfirmed and every
        // other axis is preserved (room/state unchanged).
        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(after.confirmation(), Confirmation::UserConfirmed);
        // room resolved from node tree via parent_node_id.
        let names = estate.store.resolve_node_names(&[after.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&after.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "study");
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Active
        );
    }

    #[test]
    fn mutate_confirm_missing_row_returns_not_found() {
        let estate = make_estate();
        let err = estate
            .mutate("no-such-id", MutationKind::Confirm, None)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn mutate_reject_from_active_throws_gate_violation() {
        // The automaton permits reject from Pending and Contested (§9.2).
        // Active → reject is still an illegal transition; the gate throws InvalidContent.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "x", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Reject, None)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    #[test]
    fn mutate_reject_from_contested_becomes_rejected() {
        // Cookbook §9.2: a contested memory judged false is terminally
        // rejectable via Contested → Reject → Rejected.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "contested-reject target", "study");
        // Move to Contested first.
        estate
            .mutate(&drawer.id, MutationKind::Contest, None)
            .unwrap();
        let mid = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(mid.adjective_bitmap & 0x3F),
            State::Contested,
            "state should be Contested before reject"
        );
        // Now reject from Contested — must land Rejected.
        estate
            .mutate(&drawer.id, MutationKind::Reject, None)
            .unwrap();
        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Rejected,
            "contested → reject must land Rejected"
        );
    }

    #[test]
    fn mutate_reject_from_accepted_throws_gate_violation() {
        // Accepted is an audit-grade terminal state. Reject from Accepted is
        // illegal per §9.2; the gate must block it (audit-grade coverage).
        use substrate_kernel::bit_field;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "accepted-reject target", "study");
        // Lift trust to Canonical so the Accept guard passes.
        estate
            .mutate(&drawer.id, MutationKind::CorrectTrust(Trust::Canonical), None)
            .unwrap();
        estate
            .mutate(&drawer.id, MutationKind::Accept, None)
            .unwrap();
        let accepted = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(bit_field::extract_field(accepted.adjective_bitmap, 0, 6)),
            State::Accepted
        );
        // Now try to reject — must fail.
        let err = estate
            .mutate(&drawer.id, MutationKind::Reject, None)
            .unwrap_err();
        assert!(
            matches!(err, LocusKitError::InvalidContent(_)),
            "accepted → reject must be blocked by the gate: {err:?}"
        );
    }

    // --- MutationKind round-trip tests (parity with Swift MutateMutationKindTests) ---

    #[test]
    fn mutate_contest_from_active_becomes_contested() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "contest target", "study");
        assert_eq!(State::from_raw(drawer.adjective_bitmap & 0x3F), State::Active);

        estate
            .mutate(&drawer.id, MutationKind::Contest, None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Contested,
            "state should be Contested after Contest"
        );
    }

    #[test]
    fn mutate_resolve_from_contested_becomes_active() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "resolve target", "study");
        // Contest first so resolve has a valid source state.
        estate
            .mutate(&drawer.id, MutationKind::Contest, None)
            .unwrap();

        estate
            .mutate(&drawer.id, MutationKind::Resolve, None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Active,
            "resolve should return a contested row to Active"
        );
    }

    #[test]
    fn mutate_resolve_from_active_throws_guard() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "non-contested", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Resolve, None)
            .unwrap_err();
        if let LocusKitError::InvalidContent(msg) = &err {
            assert!(
                msg.contains("resolve") || msg.contains("Contested"),
                "error should mention resolve guard: {msg}"
            );
        } else {
            panic!("expected InvalidContent, got {err:?}");
        }
    }

    #[test]
    fn mutate_supersede_from_active_becomes_superseded() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "supersede target", "study");

        estate
            .mutate(&drawer.id, MutationKind::Supersede, None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Superseded,
            "state should be Superseded after Supersede"
        );
    }

    #[test]
    fn mutate_accept_with_canonical_trust_becomes_accepted() {
        use substrate_kernel::bit_field;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "accept target", "study");

        // Lift trust to Canonical (raw 3) so the S-1 guard and gate both pass.
        estate
            .mutate(&drawer.id, MutationKind::CorrectTrust(Trust::Canonical), None)
            .unwrap();
        let with_trust = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let trust = Trust::from_raw(bit_field::extract_field(with_trust.adjective_bitmap, 18, 6));
        assert_eq!(trust, Trust::Canonical);

        estate
            .mutate(&drawer.id, MutationKind::Accept, None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            State::from_raw(after.adjective_bitmap & 0x3F),
            State::Accepted,
            "state should be Accepted after Accept with canonical trust"
        );
    }

    #[test]
    fn mutate_accept_with_low_trust_throws_s1_guard() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "low-trust target", "r");
        // Trust defaults to Verbatim (raw 0) — below Canonical (raw 3).
        let err = estate
            .mutate(&drawer.id, MutationKind::Accept, None)
            .unwrap_err();
        if let LocusKitError::InvalidContent(msg) = &err {
            assert!(
                msg.contains("S-1") || msg.contains("canonical") || msg.contains("Canonical"),
                "error should mention S-1 or Canonical trust: {msg}"
            );
        } else {
            panic!("expected InvalidContent, got {err:?}");
        }
    }

    // --- revive: complete state semantics (cookbook §9.3 / §6.2) ---

    /// Capture with a shared lineage so the supersession cascade fires.
    fn capture_in_lineage(estate: &Estate, content: &str, lineage: Uuid, now: i64) -> Drawer {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "r",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        frame.lineage_id = Some(lineage);
        estate.capture(frame, now).unwrap()
    }

    fn state_of(estate: &Estate, id: &str) -> State {
        let d = estate.store.get_drawer(id).unwrap().unwrap();
        State::from_raw(d.adjective_bitmap & 0x3F)
    }

    #[test]
    fn mutate_revive_from_active_refused_already_live() {
        // Cluster A — already live; revive refuses with a named domain rule.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "cluster-a target", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Revive, None)
            .unwrap_err();
        match err {
            LocusKitError::DisciplineViolation { from, reason, .. } => {
                assert_eq!(from, State::Active.raw_value());
                assert!(reason.contains("already live"), "names the rule: {reason}");
            }
            other => panic!("expected DisciplineViolation, got {other:?}"),
        }
    }

    #[test]
    fn mutate_revive_from_withdrawn_becomes_active() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "withdraw target", "r");
        estate.withdraw(&drawer.id, Some("test"), 1_700_000_002).unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Withdrawn);
        let before = estate.store.audit_events_for_row(&drawer.id).unwrap().len();

        estate.mutate(&drawer.id, MutationKind::Revive, None).unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Active);
        let after = estate.store.audit_events_for_row(&drawer.id).unwrap().len();
        assert_eq!(after, before + 1, "revive appends exactly one audit row");
    }

    #[test]
    fn mutate_revive_from_expired_becomes_active() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "expire target", "r");
        // expire is a dreaming transition, staged via the validated store call.
        estate
            .store
            .mutate_state(&drawer.id, State::Expired, RowVerb::Expire, "t", Some("fixture"), 1_700_000_002)
            .unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Expired);

        estate.mutate(&drawer.id, MutationKind::Revive, None).unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Active);
    }

    #[test]
    fn mutate_revive_from_decayed_becomes_active() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "decay target", "r");
        estate
            .store
            .mutate_state(&drawer.id, State::Decayed, RowVerb::Decay, "t", Some("fixture"), 1_700_000_002)
            .unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Decayed);

        estate.mutate(&drawer.id, MutationKind::Revive, None).unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Active);
    }

    #[test]
    fn mutate_revive_from_superseded_legal_when_successor_dead() {
        // Successor was itself withdrawn → lineage head vacant → revive LEGAL.
        let estate = make_estate();
        let lineage = Uuid::new_v4();
        let v1 = capture_in_lineage(&estate, "v1", lineage, 1_700_000_001);
        let v2 = capture_in_lineage(&estate, "v2", lineage, 1_700_000_002);
        assert_eq!(state_of(&estate, &v1.id), State::Superseded);
        estate.withdraw(&v2.id, Some("test"), 1_700_000_003).unwrap();

        estate.mutate(&v1.id, MutationKind::Revive, None).unwrap();
        assert_eq!(
            state_of(&estate, &v1.id),
            State::Active,
            "vacant head: superseded predecessor reclaims active"
        );
    }

    #[test]
    fn mutate_revive_from_superseded_refused_with_living_successor() {
        // Successor still live → reviving would create two lineage heads →
        // refuse with the named lineage-conflict domain error.
        let estate = make_estate();
        let lineage = Uuid::new_v4();
        let v1 = capture_in_lineage(&estate, "v1", lineage, 1_700_000_001);
        let v2 = capture_in_lineage(&estate, "v2", lineage, 1_700_000_002);
        assert_eq!(state_of(&estate, &v1.id), State::Superseded);
        assert_eq!(state_of(&estate, &v2.id), State::Active);

        let err = estate.mutate(&v1.id, MutationKind::Revive, None).unwrap_err();
        match err {
            LocusKitError::DisciplineViolation { from, to, reason } => {
                assert_eq!(from, State::Superseded.raw_value());
                assert_eq!(to, State::Active.raw_value());
                assert!(reason.contains("living successor"), "names the conflict: {reason}");
                assert!(reason.contains(&v2.id), "names the successor id: {reason}");
            }
            other => panic!("expected DisciplineViolation, got {other:?}"),
        }
        // v1 stays superseded; the refused revive changed nothing.
        assert_eq!(state_of(&estate, &v1.id), State::Superseded);
    }

    #[test]
    fn mutate_revive_from_tombstoned_refused_unrecoverable() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "tombstone target", "r");
        estate.expunge(&drawer.id, "test", true, 0, true).unwrap();
        assert_eq!(state_of(&estate, &drawer.id), State::Tombstoned);

        let err = estate.mutate(&drawer.id, MutationKind::Revive, None).unwrap_err();
        match err {
            LocusKitError::DisciplineViolation { from, reason, .. } => {
                assert_eq!(from, State::Tombstoned.raw_value());
                assert!(
                    reason.contains("tombstoned") || reason.contains("unrecoverable"),
                    "names the rule: {reason}"
                );
            }
            other => panic!("expected DisciplineViolation, got {other:?}"),
        }
    }

    #[test]
    fn mutate_correct_sensitivity_updates_bits_6_to_11() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveSensitivity;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "sensitivity target", "study");
        // Default sensitivity: Normal (raw 0).
        let initial_sens = AdjectiveSensitivity::from_raw(
            bit_field::extract_field(drawer.adjective_bitmap, 6, 6)
        );
        assert_eq!(initial_sens, AdjectiveSensitivity::Normal);

        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectSensitivity(AdjectiveSensitivity::Elevated),
                None,
            )
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let sens = AdjectiveSensitivity::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 6, 6)
        );
        assert_eq!(sens, AdjectiveSensitivity::Elevated, "sensitivity should be Elevated");
        // State must be unchanged.
        assert_eq!(State::from_raw(after.adjective_bitmap & 0x3F), State::Active);
    }

    #[test]
    fn mutate_correct_trust_updates_bits_18_to_23() {
        use substrate_kernel::bit_field;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "trust target", "study");
        // Default trust: Verbatim (raw 0).
        let initial_trust = Trust::from_raw(
            bit_field::extract_field(drawer.adjective_bitmap, 18, 6)
        );
        assert_eq!(initial_trust, Trust::Verbatim);

        estate
            .mutate(&drawer.id, MutationKind::CorrectTrust(Trust::Derived), None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let trust = Trust::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 18, 6)
        );
        assert_eq!(trust, Trust::Derived, "trust should be Derived");
        // State must be unchanged.
        assert_eq!(State::from_raw(after.adjective_bitmap & 0x3F), State::Active);
    }

    #[test]
    fn mutate_correct_sensitivity_and_trust_are_independent() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveSensitivity;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "independence target", "r");

        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted),
                None,
            )
            .unwrap();
        estate
            .mutate(&drawer.id, MutationKind::CorrectTrust(Trust::Imported), None)
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let sens = AdjectiveSensitivity::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 6, 6)
        );
        let trust = Trust::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 18, 6)
        );
        assert_eq!(sens, AdjectiveSensitivity::Restricted, "sensitivity must be Restricted");
        assert_eq!(trust, Trust::Imported, "trust must be Imported");
        assert_eq!(State::from_raw(after.adjective_bitmap & 0x3F), State::Active);
    }

    #[test]
    fn mutate_correct_exportability_public_updates_bits_12_to_17() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveExportability;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "exportability target", "study");
        // Default exportability: Private (raw 0) — privacy-preserving default.
        let initial_exp = AdjectiveExportability::from_raw(
            bit_field::extract_field(drawer.adjective_bitmap, 12, 6)
        );
        assert_eq!(initial_exp, AdjectiveExportability::Private);

        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Public),
                None,
            )
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let exp = AdjectiveExportability::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 12, 6)
        );
        assert_eq!(exp, AdjectiveExportability::Public, "exportability should be Public");
        // State must be unchanged.
        assert_eq!(State::from_raw(after.adjective_bitmap & 0x3F), State::Active);
    }

    #[test]
    fn mutate_correct_exportability_private_lowers_from_public() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveExportability;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "re-lower test", "study");

        // Raise to Public first.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Public),
                None,
            )
            .unwrap();
        let raised = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        assert_eq!(
            AdjectiveExportability::from_raw(bit_field::extract_field(raised.adjective_bitmap, 12, 6)),
            AdjectiveExportability::Public
        );

        // Lower back to Private.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Private),
                None,
            )
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let exp = AdjectiveExportability::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 12, 6)
        );
        assert_eq!(exp, AdjectiveExportability::Private, "exportability should be lowered to Private");
    }

    #[test]
    fn mutate_correct_exportability_does_not_disturb_sensitivity_or_trust() {
        use substrate_kernel::bit_field;
        use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity};
        let estate = make_estate();
        let drawer = basic_capture(&estate, "independence target", "r");

        // Stage non-default values on the other two adjective axes.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted),
                None,
            )
            .unwrap();
        estate
            .mutate(&drawer.id, MutationKind::CorrectTrust(Trust::Canonical), None)
            .unwrap();

        // Mutate exportability — the other axes must survive unchanged.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Public),
                None,
            )
            .unwrap();

        let after = estate.store.get_drawer(&drawer.id).unwrap().unwrap();
        let exp = AdjectiveExportability::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 12, 6)
        );
        let sens = AdjectiveSensitivity::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 6, 6)
        );
        let trust = Trust::from_raw(
            bit_field::extract_field(after.adjective_bitmap, 18, 6)
        );
        assert_eq!(exp, AdjectiveExportability::Public, "exportability must be Public");
        assert_eq!(sens, AdjectiveSensitivity::Restricted, "sensitivity must be unchanged");
        assert_eq!(trust, Trust::Canonical, "trust must be unchanged");
        assert_eq!(State::from_raw(after.adjective_bitmap & 0x3F), State::Active);
    }

    #[test]
    fn mutate_correct_exportability_writes_audit_row() {
        use crate::adjectives::AdjectiveExportability;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "audit row test", "r");
        // Count audit rows via the DrawerStore trait method used elsewhere in this file.
        let before = estate.store.audit_events_for_row(&drawer.id).unwrap().len();

        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Public),
                None,
            )
            .unwrap();

        let after = estate.store.audit_events_for_row(&drawer.id).unwrap().len();
        assert_eq!(after, before + 1, "correctExportability must append exactly one audit row");
    }

    #[test]
    fn capture_born_public_exportability_public() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveExportability;
        use crate::drawer_operational::CaptureChannel;
        use crate::estate_types::LatticeAnchor;
        let estate = make_estate();
        let mut frame = CaptureFrame::new(
            "born public",
            CaptureChannel::Typed,
            "r",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        frame.exportability = AdjectiveExportability::Public;
        // Use a distinct timestamp so InMemory store doesn't collide with basic_capture.
        let drawer = estate.capture(frame, 1_700_000_099).unwrap();
        // Read back via bits 12–17 (exportability window, cookbook §2.3).
        let exp = AdjectiveExportability::from_raw(
            bit_field::extract_field(drawer.adjective_bitmap, 12, 6)
        );
        assert_eq!(exp, AdjectiveExportability::Public,
            "a drawer captured with exportability=Public should be born public");
    }

    #[test]
    fn filter_exportable_returns_public_drawers_not_private() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveExportability;
        use crate::drawer_operational::CaptureChannel;
        use crate::estate_types::LatticeAnchor;
        let estate = make_estate();

        // Capture a private drawer (default); verify bits 12–17 are Private.
        let private_drawer = basic_capture(&estate, "private content", "r");
        assert_eq!(
            AdjectiveExportability::from_raw(bit_field::extract_field(private_drawer.adjective_bitmap, 12, 6)),
            AdjectiveExportability::Private
        );

        // Capture a born-public drawer.
        let mut pub_frame = CaptureFrame::new(
            "public content",
            CaptureChannel::Typed,
            "r",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        pub_frame.exportability = AdjectiveExportability::Public;
        let public_drawer = estate.capture(pub_frame, 1_700_000_050).unwrap();
        assert_eq!(
            AdjectiveExportability::from_raw(bit_field::extract_field(public_drawer.adjective_bitmap, 12, 6)),
            AdjectiveExportability::Public
        );

        // Explicit filter chain: bypasses default provenance/trust insertion
        // so captured test drawers (unconfirmed by default) are not excluded
        // for the wrong reason — the chain itself governs who passes.
        let chain = vec![
            Filter::CurrentlyBelieve,
            Filter::UserConfirmed,
            Filter::Trustworthy,
            Filter::SensitivityAtMost(crate::adjectives::AdjectiveSensitivity::Secret),
            Filter::Exportable,
        ];
        // Confirm the public drawer so it satisfies UserConfirmed; the private
        // drawer remains unconfirmed and will be excluded both by UserConfirmed
        // and by Exportable.
        estate.mutate(&public_drawer.id, MutationKind::Confirm, None).unwrap();

        let stream = estate.recall(RecallFrame::new(chain), 1_700_000_060);
        let rows = stream.collect_all();
        let ids: Vec<&str> = rows.iter().map(|d| d.id.as_str()).collect();

        assert!(
            ids.contains(&public_drawer.id.as_str()),
            "filter:Exportable must include the confirmed public drawer"
        );
        assert!(
            !ids.contains(&private_drawer.id.as_str()),
            "filter:Exportable must exclude the private drawer"
        );
    }

    #[test]
    fn mutate_to_public_then_filter_exportable_roundtrip() {
        use substrate_kernel::bit_field;
        use crate::adjectives::AdjectiveExportability;
        let estate = make_estate();
        let drawer = basic_capture(&estate, "roundtrip target", "r");
        // Confirm the drawer so it satisfies UserConfirmed in the filter chain.
        estate.mutate(&drawer.id, MutationKind::Confirm, None).unwrap();
        // Verify born Private.
        assert_eq!(
            AdjectiveExportability::from_raw(bit_field::extract_field(drawer.adjective_bitmap, 12, 6)),
            AdjectiveExportability::Private
        );

        // Explicit filter chain: avoids default insertion; Exportable is the gate
        // under test.
        let exportable_chain = || vec![
            Filter::CurrentlyBelieve,
            Filter::UserConfirmed,
            Filter::Trustworthy,
            Filter::SensitivityAtMost(crate::adjectives::AdjectiveSensitivity::Secret),
            Filter::Exportable,
        ];

        // Before mutation: filter:Exportable must return empty.
        let empty = estate.recall(RecallFrame::new(exportable_chain()), 1_700_000_010).collect_all();
        assert!(empty.is_empty(), "before mutation, filter:Exportable must return empty");

        // Mutate to Public.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Public),
                None,
            )
            .unwrap();

        // After mutation: filter:Exportable must return the drawer.
        let public_rows = estate.recall(RecallFrame::new(exportable_chain()), 1_700_000_020).collect_all();
        assert!(
            public_rows.iter().any(|d| d.id == drawer.id),
            "after CorrectExportability(Public), filter:Exportable must return the drawer"
        );

        // Mutate back to Private.
        estate
            .mutate(
                &drawer.id,
                MutationKind::CorrectExportability(AdjectiveExportability::Private),
                None,
            )
            .unwrap();

        // After lowering: filter:Exportable must return empty again.
        let private_rows = estate.recall(RecallFrame::new(exportable_chain()), 1_700_000_030).collect_all();
        assert!(
            private_rows.is_empty(),
            "after re-lowering to Private, filter:Exportable must return empty"
        );
    }

    #[test]
    fn reanchor_empty_args_returns_invalid_content() {
        // Belt-and-suspenders guard: all of to_room, to_wing, and to_lattice nil.
        let estate = make_estate();
        let err = estate.reanchor("id", None, None, None).unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    #[test]
    fn reanchor_nonexistent_row_returns_not_found() {
        let estate = make_estate();
        let err = estate
            .reanchor(
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                Some("new-room"),
                None,
                None,
            )
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn reanchor_to_new_room_updates_room() {
        let estate = make_estate();
        let d = basic_capture(&estate, "content", "original-room");
        estate.reanchor(&d.id, Some("new-room"), None, None).unwrap();
        let updated = estate.store.get_drawer(&d.id).unwrap().unwrap();
        // room resolved from node tree via parent_node_id.
        let names = estate.store.resolve_node_names(&[updated.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&updated.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "new-room");
        // Bitmaps unchanged.
        assert_eq!(updated.adjective_bitmap, d.adjective_bitmap);
        assert_eq!(updated.operational_bitmap, d.operational_bitmap);
        assert_eq!(updated.provenance, d.provenance);
    }

    #[test]
    fn reanchor_to_new_lattice_updates_udc() {
        let estate = make_estate();
        let d = basic_capture(&estate, "content", "room-x");
        estate
            .reanchor(&d.id, None, None, Some(LatticeAnchor::udc("003.000")))
            .unwrap();
        let updated = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(updated.udc_code, "003.000");
        // Bitmaps unchanged.
        assert_eq!(updated.adjective_bitmap, d.adjective_bitmap);
        assert_eq!(updated.operational_bitmap, d.operational_bitmap);
        assert_eq!(updated.provenance, d.provenance);
    }

    fn sample_source() -> crate::source_catalog_entry::SourceCatalogEntry {
        crate::source_catalog_entry::SourceCatalogEntry::new(
            "src-1",
            crate::source_catalog_entry::SourceKind::User,
            "https://example.com",
            // A genuine, non-empty anchor — what the learned reference inherits.
            LatticeAnchor::udc("004"),
            1_700_000_000,
            "cataloger",
        )
    }

    #[test]
    fn learn_writes_genuine_anchor_from_source() {
        // learn succeeds on a normal beta path: it derives the reference's
        // genuine anchor from the source catalog entry and persists it. No
        // sentinel identity (P1 mandate, Bob's board item 7).
        let estate = make_estate();
        let frame = LearnFrame::new(sample_source(), "https://example.com/page");
        let reference = estate.learn(frame, 1_700_000_100).expect("learn should succeed");

        // Anchor is the source's genuine anchor, never a sentinel.
        assert_eq!(reference.lattice_anchor.udc_code, "004");
        assert!(!reference.lattice_anchor.udc_code.is_empty());
        assert_eq!(reference.source_catalog_id, "src-1");
        assert_eq!(reference.handle, "https://example.com/page");
        assert_eq!(reference.added_by, "learn");

        // Operational axes decode back: mode=byReference (default),
        // refresh=weekly (default), source=user (from catalog kind).
        assert_eq!(reference.mode(), crate::learned_reference::LearnMode::ByReference);
        assert_eq!(
            reference.refresh_policy(),
            crate::learned_reference::RefreshPolicy::Weekly
        );
        assert_eq!(
            reference.acquisition_source(),
            crate::learned_reference::LearnedReferenceSource::User
        );

        // The reference is durable and queryable.
        let fetched = estate
            .store
            .get_learned_reference(&reference.id)
            .unwrap()
            .expect("learned reference must be persisted");
        assert_eq!(fetched.lattice_anchor.udc_code, "004");

        // The source was cataloged durably and is queryable by handle.
        let cataloged = estate
            .store
            .source_catalog_entry_for_handle("https://example.com")
            .unwrap()
            .expect("source must be cataloged");
        assert_eq!(cataloged.id, "src-1");
    }

    #[test]
    fn learn_encodes_mode_and_refresh_policy() {
        let estate = make_estate();
        let mut frame = LearnFrame::new(sample_source(), "https://example.com/doc");
        frame.mode = crate::learned_reference::LearnMode::ByIngestion;
        frame.refresh_policy = crate::learned_reference::RefreshPolicy::Daily;
        let reference = estate.learn(frame, 1_700_000_200).expect("learn should succeed");
        assert_eq!(reference.mode(), crate::learned_reference::LearnMode::ByIngestion);
        assert_eq!(
            reference.refresh_policy(),
            crate::learned_reference::RefreshPolicy::Daily
        );
    }

    #[test]
    fn learn_reuses_existing_catalog_entry() {
        // Two learns from the same source handle share one catalog entry.
        let estate = make_estate();
        let r1 = estate
            .learn(LearnFrame::new(sample_source(), "https://example.com/a"), 1_700_000_300)
            .expect("first learn");
        // A second source value with the same handle but a different id must
        // NOT create a second catalog entry; the existing one is reused.
        let mut other = sample_source();
        other.id = "src-2".to_string();
        let r2 = estate
            .learn(LearnFrame::new(other, "https://example.com/b"), 1_700_000_400)
            .expect("second learn");
        assert_eq!(r1.source_catalog_id, "src-1");
        assert_eq!(r2.source_catalog_id, "src-1", "existing catalog entry must be reused");
    }

    #[test]
    fn learn_fails_loud_only_on_empty_handle() {
        // Fail loud ONLY on genuinely invalid input — an empty reference
        // handle. A valid handle succeeds (see learn_writes_genuine_anchor).
        let estate = make_estate();
        let err = estate
            .learn(LearnFrame::new(sample_source(), ""), 1_700_000_500)
            .unwrap_err();
        assert!(
            matches!(err, LocusKitError::InvalidContent(_)),
            "empty handle must return InvalidContent, got: {:?}",
            err
        );
    }

    #[test]
    fn propose_with_nonexistent_target_returns_drawer_not_found() {
        let estate = make_estate();
        let err = estate
            .propose(
                crate::frames::ProposeFrame::new(
                    "nonexistent-row",
                    crate::proposal_operational::ProposalKind::NewTunnel,
                ),
                1_700_000_000,
            )
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn propose_with_existing_target_returns_proposal() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "content", "room-a");
        let proposal = estate
            .propose(
                crate::frames::ProposeFrame::new(
                    &drawer.id,
                    crate::proposal_operational::ProposalKind::MutateDrawer,
                ),
                1_700_000_000,
            )
            .expect("propose should succeed with an existing target");
        assert_eq!(proposal.target_row_id, drawer.id);
        // Adjective bitmap: state .pending (raw 1) at bits 0–5.
        assert_ne!(proposal.adjective_bitmap, 0);
    }

    // A-3: the propose verb wires the three provenance operational axes
    // (confirmation 12–17, generated-by 18–23, confidence 24–29) from the frame
    // into the proposal's operational bitmap, at the exact positions the read
    // accessors in proposal_operational.rs decode. Mirrors the Swift
    // ProposeProvenanceTests suite.

    #[test]
    fn propose_non_default_provenance_round_trips_through_store() {
        use crate::proposal_operational::{
            ProposalConfidenceBucket, ProposalConfirmationSource, ProposalGeneratedByClass,
            ProposalKind, ProposalTargetObjectType,
        };
        let estate = make_estate();
        let drawer = basic_capture(&estate, "content", "room-a");

        // Distinct non-zero value on each provenance axis so a cross-wired shift
        // would surface as a mismatched read.
        let mut frame = crate::frames::ProposeFrame::new(&drawer.id, ProposalKind::MutateDrawer);
        frame.confirmation = ProposalConfirmationSource::Agent; // raw 1, bits 12–17
        frame.generated_by = ProposalGeneratedByClass::Manual; // raw 3, bits 18–23
        frame.confidence = ProposalConfidenceBucket::High; // raw 32, bits 24–29

        let returned = estate.propose(frame, 1_700_000_000).expect("propose");

        // 1) the returned value carries the axes.
        assert_eq!(returned.proposal_kind(), ProposalKind::MutateDrawer);
        assert_eq!(returned.target_object_type(), ProposalTargetObjectType::Drawer);
        assert_eq!(returned.confirmation_source(), ProposalConfirmationSource::Agent);
        assert_eq!(returned.generated_by_class(), ProposalGeneratedByClass::Manual);
        assert_eq!(returned.confidence_bucket(), ProposalConfidenceBucket::High);

        // 2) the same values survive a store round-trip.
        let reloaded = estate
            .store
            .get_proposal(&returned.id)
            .expect("get_proposal")
            .expect("proposal present after round-trip");
        assert_eq!(reloaded.operational_bitmap, returned.operational_bitmap);
        assert_eq!(reloaded.confirmation_source(), ProposalConfirmationSource::Agent);
        assert_eq!(reloaded.generated_by_class(), ProposalGeneratedByClass::Manual);
        assert_eq!(reloaded.confidence_bucket(), ProposalConfidenceBucket::High);
    }

    #[test]
    fn propose_each_provenance_value_writes_to_own_window() {
        use crate::proposal_operational::{
            ProposalConfidenceBucket, ProposalConfirmationSource, ProposalGeneratedByClass,
            ProposalKind, ProposalTargetObjectType,
        };
        let estate = make_estate();
        let drawer = basic_capture(&estate, "content", "room-a");

        // Exhaustively walk every confirmation × generated-by × confidence value
        // so any width/shift error on one axis surfaces on that axis without
        // disturbing the other two.
        let confirmations = [
            ProposalConfirmationSource::Human,
            ProposalConfirmationSource::Agent,
            ProposalConfirmationSource::AutomatedThreshold,
            ProposalConfirmationSource::Actuator,
        ];
        let generators = [
            ProposalGeneratedByClass::DreamingDaemon,
            ProposalGeneratedByClass::McpAgent,
            ProposalGeneratedByClass::FederationSync,
            ProposalGeneratedByClass::Manual,
            ProposalGeneratedByClass::TierAggregator,
        ];
        let confidences = [
            ProposalConfidenceBucket::Null,
            ProposalConfidenceBucket::Low,
            ProposalConfidenceBucket::Medium,
            ProposalConfidenceBucket::High,
            ProposalConfidenceBucket::Verified,
        ];

        for &c in &confirmations {
            for &g in &generators {
                for &conf in &confidences {
                    let mut frame =
                        crate::frames::ProposeFrame::new(&drawer.id, ProposalKind::NewKGFact);
                    frame.confirmation = c;
                    frame.generated_by = g;
                    frame.confidence = conf;
                    let p = estate.propose(frame, 1_700_000_000).expect("propose");
                    assert_eq!(p.proposal_kind(), ProposalKind::NewKGFact);
                    assert_eq!(p.target_object_type(), ProposalTargetObjectType::Drawer);
                    assert_eq!(p.confirmation_source(), c);
                    assert_eq!(p.generated_by_class(), g);
                    assert_eq!(p.confidence_bucket(), conf);
                }
            }
        }
    }

    #[test]
    fn propose_default_frame_is_byte_identical_to_pre_wire_bitmap() {
        use crate::proposal_operational::{
            ProposalConfidenceBucket, ProposalConfirmationSource, ProposalGeneratedByClass,
            ProposalKind, ProposalTargetObjectType,
        };
        let estate = make_estate();
        let drawer = basic_capture(&estate, "content", "room-a");

        // The pre-A-3 propose verb wrote ONLY kind (bits 0–5) and target object
        // type Drawer=0 (bits 6–11); the provenance windows were zeroed.
        // Reconstruct that exact value independently.
        let mut expected = bit_field::write_field(ProposalKind::MutateDrawer.raw_value(), 0i64, 0, 6);
        expected =
            bit_field::write_field(ProposalTargetObjectType::Drawer.raw_value(), expected, 6, 6);

        // A frame built via `new` takes the provenance defaults
        // (Human / DreamingDaemon / Null), all raw 0.
        let frame = crate::frames::ProposeFrame::new(&drawer.id, ProposalKind::MutateDrawer);
        let p = estate.propose(frame, 1_700_000_000).expect("propose");

        assert_eq!(p.operational_bitmap, expected);
        assert_eq!(p.confirmation_source(), ProposalConfirmationSource::Human);
        assert_eq!(p.generated_by_class(), ProposalGeneratedByClass::DreamingDaemon);
        assert_eq!(p.confidence_bucket(), ProposalConfidenceBucket::Null);
    }

    #[test]
    fn associate_with_missing_endpoint_returns_drawer_not_found() {
        let estate = make_estate();
        let err = estate
            .associate(
                crate::frames::AssociateFrame::new("missing-a", "missing-b", 0.5),
                1_700_000_000,
            )
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn associate_with_existing_endpoints_returns_association() {
        let estate = make_estate();
        let drawer_a = basic_capture(&estate, "endpoint-a", "room-a");
        let drawer_b = basic_capture(&estate, "endpoint-b", "room-b");
        let assoc = estate
            .associate(
                crate::frames::AssociateFrame::new(&drawer_a.id, &drawer_b.id, 0.7),
                1_700_000_000,
            )
            .expect("associate should succeed with existing endpoints");
        assert_eq!(assoc.source_drawer_id, Some(drawer_a.id.clone()));
        assert_eq!(assoc.target_drawer_id, Some(drawer_b.id.clone()));
        assert_eq!(assoc.added_by, "associate");
    }

    // -----------------------------------------------------------------
    // Expunge verb wrapper (cookbook §10.5, F17 second pass item 1)
    // -----------------------------------------------------------------

    #[test]
    fn estate_expunge_requires_confirmation() {
        let estate = make_estate();
        let d = basic_capture(&estate, "to be expunged", "office");
        let err = estate.expunge(&d.id, "", false, 0, true).unwrap_err();
        assert!(
            matches!(err, LocusKitError::InvalidContent(_)),
            "expected InvalidContent for confirmation=false, got {:?}",
            err
        );
        // State unchanged.
        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.adjective_bitmap & 0x3F, State::Active.raw_value());
        assert_eq!(after.adjective_bitmap & (1 << 26), 0);
    }

    #[test]
    fn estate_expunge_forwards_through_to_store_with_confirmation() {
        let estate = make_estate();
        let d = basic_capture(&estate, "to be expunged", "office");
        estate.expunge(&d.id, "operator request", true, 0, true).unwrap();
        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
        assert_ne!(
            after.adjective_bitmap & (1 << 26),
            0,
            "dreaming_recalc_required must be set on tombstone via expunge"
        );
        assert_eq!(after.content, "");
        assert!(after.tombstoned_at.is_some());
    }

    #[test]
    fn estate_expunge_rejects_absent_row() {
        let estate = make_estate();
        let err = estate
            .expunge("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "", true, 0, true)
            .unwrap_err();
        match err {
            LocusKitError::DrawerNotFound { .. } => {}
            other => panic!("expected DrawerNotFound, got {:?}", other),
        }
    }

    // -----------------------------------------------------------------
    // tunnels_from_wing — estate-level read over the association graph.
    // Mirrors Swift `EstateTunnelReadTests` case-for-case.
    // -----------------------------------------------------------------

    fn tunnel_frame(source: &str, target: &str, label: &str) -> TunnelCaptureFrame {
        TunnelCaptureFrame::new(source, "r1", target, "r2", label, "bilby")
    }

    #[test]
    fn tunnels_from_wing_returns_outgoing() {
        let estate = make_estate();
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), 1_700_000_001)
            .unwrap();
        estate
            .capture_tunnel(tunnel_frame("study", "garden", "relates"), 1_700_000_002)
            .unwrap();

        let tunnels = estate.tunnels_from_wing("study").unwrap();
        assert_eq!(tunnels.len(), 2);
        let targets: std::collections::BTreeSet<&str> =
            tunnels.iter().map(|t| t.target_wing.as_str()).collect();
        assert_eq!(targets, ["garden", "kitchen"].into_iter().collect());
        assert!(tunnels.iter().all(|t| t.source_wing == "study"));
    }

    #[test]
    fn tunnels_from_wing_excludes_restricted_and_secret_edges() {
        // The tunnel graph read must apply the same no-claims sensitivity
        // ceiling as drawer recall: Normal tier (normal + elevated) visible,
        // restricted/secret excluded — so a lens reading the graph never sees
        // a sensitive edge the store query (wing + tombstone only) would leak.
        use crate::adjectives::AdjectiveSensitivity;
        let estate = make_estate();
        // A normal edge (adjective_bitmap 0) — visible.
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "normal-link"), 1_700_000_001)
            .unwrap();
        // Restricted and secret edges filed directly with sensitivity bits set
        // (bits 6–11 hold the sensitivity raw value).
        for (target, sens) in [
            ("vault", AdjectiveSensitivity::Restricted),
            ("safe", AdjectiveSensitivity::Secret),
        ] {
            let mut t = crate::tunnel::Tunnel::new(
                format!("t-{target}"),
                "study".into(), "r1".into(),
                target.into(), "r2".into(),
                "sensitive-link".into(), "bilby".into(), 1_700_000_003,
            );
            t.adjective_bitmap = sens.raw_value() << 6;
            estate.add_tunnel(&t).unwrap();
        }

        let tunnels = estate.tunnels_from_wing("study").unwrap();
        let targets: std::collections::BTreeSet<&str> =
            tunnels.iter().map(|t| t.target_wing.as_str()).collect();
        assert_eq!(
            targets,
            ["kitchen"].into_iter().collect(),
            "only the Normal-tier edge is visible; restricted/secret excluded"
        );
    }

    #[test]
    fn tunnels_from_wing_is_empty_for_unlinked_wing() {
        let estate = make_estate();
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), 1_700_000_001)
            .unwrap();

        let tunnels = estate.tunnels_from_wing("attic").unwrap();
        assert!(tunnels.is_empty());
    }

    #[test]
    fn tunnels_from_wing_is_scoped_to_source_wing() {
        let estate = make_estate();
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "a"), 1_700_000_001)
            .unwrap();
        estate
            .capture_tunnel(tunnel_frame("garden", "kitchen", "b"), 1_700_000_002)
            .unwrap();

        let from_study = estate.tunnels_from_wing("study").unwrap();
        assert_eq!(from_study.len(), 1);
        assert_eq!(from_study[0].source_wing, "study");
    }

    // --- recall integrity: traceLimit / scan cap / no-blob projection ---
    // Rust twins of Swift RecallPerfCorrectnessTests (fdd2e763 / 9596ef4f).

    use crate::drawer_store_sqlite::SqliteDrawerStore;

    /// RAII temp SQLite DB path; deletes the file + WAL/SHM on drop.
    struct TempDb {
        path: String,
    }
    impl TempDb {
        fn new() -> Self {
            let name = format!("locus_recall_test_{}.db", uuid::Uuid::new_v4().simple());
            let path = std::env::temp_dir().join(name).to_string_lossy().into_owned();
            TempDb { path }
        }
    }
    impl Drop for TempDb {
        fn drop(&mut self) {
            for suffix in &["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
            }
        }
    }

    /// A SQLite-backed estate at a fresh temp path. Returns the estate and the
    /// `TempDb` guard (which the caller must keep alive for the test's duration).
    fn make_sqlite_estate(db: &TempDb) -> Estate {
        let store = Arc::new(SqliteDrawerStore::from_path(&db.path, 1_700_000_000, None, 5.0).unwrap());
        Estate::create(store, OwnerCredentials::new("owner"), None).unwrap()
    }

    /// Capture `n` drawers into `estate`, content "doc-i" in room "den".
    fn capture_n(estate: &Estate, n: usize) {
        for i in 0..n {
            let frame = CaptureFrame::new(
                format!("doc-{i}"),
                CaptureChannel::Typed,
                "den",
                LatticeAnchor::udc("5"),
                "alice",
                "test-v1",
            );
            // Stagger filedAt so the bounded scan has a deterministic order.
            estate.capture(frame, 1_700_000_001 + i as i64).unwrap();
        }
    }

    fn unconfirmed_frame() -> RecallFrame {
        RecallFrame::new(vec![Filter::CurrentlyBelieve, Filter::Unconfirmed])
    }

    #[test]
    fn trace_limit_none_writes_zero_trace_rows() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 10);

        // trace_limit is None by default — no trace rows written.
        let frame = unconfirmed_frame();
        let stream = estate.recall(frame, 1_700_001_000);
        let _ = stream.collect_all();

        // recent_recall_traces over a wide window must be empty.
        let since = epoch_to_iso8601(1_700_000_000);
        let now = epoch_to_iso8601(1_700_002_000);
        let traces = estate.recent_recall_traces(&since, &now).unwrap();
        assert!(
            traces.is_empty(),
            "trace_limit None must write ZERO trace rows; got {}",
            traces.len()
        );
    }

    #[test]
    fn trace_limit_five_writes_at_most_five_rows() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 20);

        let mut frame = unconfirmed_frame();
        frame.trace_limit = Some(5);
        let stream = estate.recall(frame, 1_700_001_000);
        let _ = stream.collect_all();

        let since = epoch_to_iso8601(1_700_000_000);
        let now = epoch_to_iso8601(1_700_002_000);
        let traces = estate.recent_recall_traces(&since, &now).unwrap();
        assert!(
            traces.len() <= 5,
            "trace_limit 5: expected <= 5 trace rows, got {}",
            traces.len()
        );
        assert!(!traces.is_empty(), "expected at least one trace row with trace_limit 5");
    }

    #[test]
    fn prune_deletes_old_keeps_new() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 10);

        // Two recalls at distinct epochs (epoch MILLISECONDS, epoch-millisecond instants), each
        // writing trace rows.
        let old_epoch = 1_700_001_000_000;
        let new_epoch = 1_700_005_000_000;
        let mut f1 = unconfirmed_frame();
        f1.trace_limit = Some(3);
        let _ = estate.recall(f1, old_epoch).collect_all();
        let mut f2 = unconfirmed_frame();
        f2.trace_limit = Some(3);
        let _ = estate.recall(f2, new_epoch).collect_all();

        // Cutoff between the two recall sessions: prune the old, keep the new.
        let cutoff = epoch_to_iso8601((old_epoch + new_epoch) / 2);
        let deleted = estate.prune_recall_traces(&cutoff).unwrap();
        assert!(deleted >= 1, "expected the old rows pruned; deleted {deleted}");

        // Surviving rows are all at or after the cutoff (the new session).
        let since = epoch_to_iso8601(1_700_000_000_000);
        let now = epoch_to_iso8601(1_700_006_000_000);
        let remaining = estate.recent_recall_traces(&since, &now).unwrap();
        assert!(!remaining.is_empty(), "the new session's rows must survive");
        let new_iso = epoch_to_iso8601(new_epoch);
        for t in &remaining {
            assert!(
                t.recalled_at >= cutoff,
                "surviving row {} predates cutoff {}",
                t.recalled_at,
                cutoff
            );
            assert_eq!(t.recalled_at, new_iso, "survivors are the new session");
        }
    }

    #[test]
    fn large_limit_returns_all_drawers_above_cap() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        // 300 > RECALL_CANDIDATE_CAP (256): the old 256 cap silently truncated.
        capture_n(&estate, 300);

        let mut frame = unconfirmed_frame();
        frame.hydration_level = HydrationLevel::Structured;
        frame.limit = Some(10_000_000); // VaultBridge full-scan intent
        let rows = estate.recall(frame, 1_700_001_000).collect_all();
        assert_eq!(rows.len(), 300, "limit 10_000_000 must return all 300; got {}", rows.len());
    }

    #[test]
    fn small_limit_stays_bounded_at_cap() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 300);

        let mut frame = unconfirmed_frame();
        frame.hydration_level = HydrationLevel::Structured;
        frame.limit = Some(20);
        let rows = estate.recall(frame, 1_700_001_000).collect_all();
        // Director-style callers keep the 256 candidate floor; they never get
        // all 300. The page size is the limit, but collect_all drains every
        // page up to scan_bound = max(20, 256) = 256.
        assert!(
            rows.len() <= RECALL_CANDIDATE_CAP,
            "limit 20 on 300-drawer estate must not exceed cap {}; got {}",
            RECALL_CANDIDATE_CAP,
            rows.len()
        );
    }

    // P4-secfix: DESC-ordered bounded scan returns NEWEST drawers.
    //
    // With 300 drawers (doc-0 .. doc-299, timestamps 1_700_000_001..1_700_000_300)
    // and a Director-style frame (limit = None → scan_bound = 256), the cap must
    // retain the 256 most-recently-filed drawers (doc-44..doc-299), not the
    // oldest 256 (doc-0..doc-255). We verify by checking that the freshly-filed
    // "doc-299" appears in the result and the oldest "doc-0" does not.
    #[test]
    fn desc_bounded_scan_returns_newest_drawers_above_cap() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        // Insert 300 drawers in strictly-ascending filedAt order so the
        // oldest/newest distinction is unambiguous.
        capture_n(&estate, 300);

        // Director-style frame: no explicit limit → scan_bound = max(0, 256) = 256.
        let mut frame = unconfirmed_frame();
        frame.hydration_level = HydrationLevel::Full; // need content to identify drawer

        let rows = estate.recall(frame, 1_700_001_000).collect_all();

        // Exactly 256 rows (the cap); not 300 (full estate) and not fewer.
        assert_eq!(
            rows.len(),
            RECALL_CANDIDATE_CAP,
            "P4-secfix: 300-drawer estate with no limit should yield {} rows; got {}",
            RECALL_CANDIDATE_CAP,
            rows.len(),
        );

        // The newest drawer ("doc-299") must be in the cap window.
        let has_newest = rows.iter().any(|d| d.content == "doc-299");
        assert!(has_newest, "P4-secfix: doc-299 (newest) must be within the 256-row cap");

        // The oldest drawer ("doc-0") must have been excluded by the DESC cap.
        let has_oldest = rows.iter().any(|d| d.content == "doc-0");
        assert!(!has_oldest, "P4-secfix: doc-0 (oldest) must be excluded by the 256-row DESC cap");
    }

    #[test]
    fn structured_recall_returns_empty_content() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 5);

        // .structured with no content predicate → no-blob projected scan →
        // content == "" (Swift parity, spec § 7.3).
        let mut frame = unconfirmed_frame();
        frame.hydration_level = HydrationLevel::Structured;
        let rows = estate.recall(frame, 1_700_001_000).collect_all();
        assert_eq!(rows.len(), 5);
        for r in &rows {
            assert_eq!(r.content, "", "structured recall must return content == \"\"");
        }
    }

    #[test]
    fn full_recall_returns_real_content() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 5);

        // .full → blob-loading scan → real content bodies.
        let mut frame = unconfirmed_frame();
        frame.hydration_level = HydrationLevel::Full;
        let rows = estate.recall(frame, 1_700_001_000).collect_all();
        assert_eq!(rows.len(), 5);
        for r in &rows {
            assert!(
                r.content.starts_with("doc-"),
                "full recall must return real content; got {:?}",
                r.content
            );
        }
    }

    #[test]
    fn get_drawers_matching_frame_drops_withdrawn_under_default_admits_under_override() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        let active = estate
            .capture(
                CaptureFrame::new("active one", CaptureChannel::Typed, "r",
                    LatticeAnchor::udc("5"), "alice", "v1"),
                1_700_000_001,
            )
            .unwrap();
        let gone = estate
            .capture(
                CaptureFrame::new("withdrawn one", CaptureChannel::Typed, "r",
                    LatticeAnchor::udc("5"), "alice", "v1"),
                1_700_000_002,
            )
            .unwrap();
        estate.withdraw(&gone.id, Some("test"), 1_700_000_003).unwrap();

        let ids = vec![active.id.clone(), gone.id.clone()];

        // Default frame (CurrentlyBelieve) → only the active drawer is admissible;
        // both rows physically load.
        let def = estate
            .get_drawers_matching_frame(
                &ids,
                &RecallFrame::new(vec![Filter::CurrentlyBelieve, Filter::Unconfirmed]),
            )
            .unwrap();
        let mut loaded: Vec<&String> = def.loaded_ids.iter().collect();
        loaded.sort();
        let mut expect_loaded = vec![&active.id, &gone.id];
        expect_loaded.sort();
        assert_eq!(loaded, expect_loaded, "both rows must load regardless of frame filter");
        assert_eq!(
            def.admissible.iter().map(|d| d.id.clone()).collect::<Vec<_>>(),
            vec![active.id.clone()],
            "default frame must admit only the active drawer"
        );

        // UsedToBelieve override → the withdrawn (Cluster B) drawer is admitted and
        // the active (Cluster A) one excluded — proving the filter is the frame's.
        let over = estate
            .get_drawers_matching_frame(
                &ids,
                &RecallFrame::new(vec![Filter::UsedToBelieve, Filter::Unconfirmed]),
            )
            .unwrap();
        assert_eq!(
            over.admissible.iter().map(|d| d.id.clone()).collect::<Vec<_>>(),
            vec![gone.id.clone()],
            "a UsedToBelieve frame must admit the withdrawn drawer and exclude the active one"
        );
        assert_eq!(over.admissible[0].state(), State::Withdrawn);

        // A non-existent id is absent from loaded_ids → caller degrades (keeps), not drops.
        let ghost = uuid::Uuid::new_v4().to_string();
        let res = estate
            .get_drawers_matching_frame(
                &[active.id.clone(), ghost.clone()],
                &RecallFrame::new(vec![Filter::CurrentlyBelieve, Filter::Unconfirmed]),
            )
            .unwrap();
        assert!(!res.loaded_ids.contains(&ghost), "non-existent id must be absent from loaded_ids");
        assert_eq!(res.loaded_ids.len(), 1);
        assert_eq!(
            res.admissible.iter().map(|d| d.id.clone()).collect::<Vec<_>>(),
            vec![active.id.clone()]
        );
    }

    #[test]
    fn content_predicate_chain_still_filters() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);
        capture_n(&estate, 5); // doc-0 .. doc-4

        // A content-predicate chain forces the blob-loading scan so the
        // substring match runs — even at .structured hydration the match works.
        let frame = RecallFrame::new(vec![
            Filter::CurrentlyBelieve,
            Filter::Unconfirmed,
            Filter::ContentMatches("doc-3".to_string()),
        ]);
        let rows = estate.recall(frame, 1_700_001_000).collect_all();
        assert_eq!(rows.len(), 1, "exactly one drawer matches 'doc-3'");
        assert_eq!(rows[0].content, "doc-3");
    }

    // P6-secfix: ContentMatches predicate in get_drawers_matching_frame must see
    // real content, not the empty string left by premature BitmapOnly stripping.
    #[test]
    fn get_drawers_matching_frame_content_predicate_sees_real_content() {
        let db = TempDb::new();
        let estate = make_sqlite_estate(&db);

        // Capture two drawers with distinct content bodies.
        let d_alpha = estate
            .capture(
                CaptureFrame::new("needle text", CaptureChannel::Typed, "r",
                    LatticeAnchor::udc("5"), "bilby", "v1"),
                1_700_000_001,
            )
            .unwrap();
        let _d_other = estate
            .capture(
                CaptureFrame::new("haystack", CaptureChannel::Typed, "r",
                    LatticeAnchor::udc("5"), "bilby", "v1"),
                1_700_000_002,
            )
            .unwrap();

        // Query both IDs with a ContentMatches predicate at BitmapOnly hydration.
        // P6-secfix: evaluate must see the real body (not "") so "needle" matches;
        // then the content is stripped AFTER evaluation for the BitmapOnly result.
        let ids = vec![d_alpha.id.clone(), _d_other.id.clone()];
        let mut frame = RecallFrame::new(vec![
            Filter::CurrentlyBelieve,
            Filter::Unconfirmed,
            Filter::ContentMatches("needle".to_string()),
        ]);
        frame.hydration_level = HydrationLevel::BitmapOnly;

        let result = estate.get_drawers_matching_frame(&ids, &frame).unwrap();

        // Only "needle text" matches the predicate.
        assert_eq!(
            result.admissible.len(), 1,
            "P6-secfix: only the drawer containing 'needle' must be admissible; got {}",
            result.admissible.len()
        );
        assert_eq!(result.admissible[0].id, d_alpha.id,
            "P6-secfix: the admissible drawer must be d_alpha");
        // BitmapOnly stripping must still apply to the result (content == "").
        assert_eq!(result.admissible[0].content, "",
            "P6-secfix: BitmapOnly hydration must strip content AFTER predicate eval");
    }

    // --- fingerprint pruning in recall (mirrors Swift RecallPruningTests) ---

    /// Helper: capture a drawer with an explicit `feature_flags` bitmask so
    /// the test controls which operational bits are present.
    ///
    /// Note on confirmation: `CaptureFrame` defaults `confirmation` to
    /// `Unconfirmed` (raw 0) when not explicitly set. The pruning test chains
    /// below include `Filter::Unconfirmed` to suppress the default
    /// `UserConfirmed` insertion so these drawers surface. The Swift mirror
    /// (RecallPruningTests) constructs fixture `Drawer` rows directly with
    /// `provenance: Int64(1) << 18` (UserConfirmed) to keep the feature-flag
    /// bits under explicit control; both admit the row. The key result under
    /// test is the fingerprint-prune decision, which is orthogonal to the
    /// confirmation axis.
    fn capture_with_flags(
        estate: &Estate,
        content: &str,
        room: &str,
        flags: i64,
        now: i64,
    ) -> Drawer {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        // `DrawerFeatureFlags` constants are pre-shifted (e.g. HAS_VOICE = 1<<13),
        // so OR-ing them directly into `feature_flags` lands the correct bits in
        // the 0xFFF000 feature region of the operational bitmap after capture's
        // assembly (cookbook §2.4, mirrors Swift test `op: Int64` construction).
        frame.feature_flags = flags;
        estate.capture(frame, now).unwrap()
    }

    #[test]
    fn chain_has_prunable_filter_true_for_has_feature_flag() {
        // Mirrors Swift: chainHasPrunableFilter([.hasFeatureFlag(.hasVoice)]) == true
        assert!(BitmapEvaluator::chain_has_prunable_filter(&[
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE)
        ]));
    }

    #[test]
    fn chain_has_prunable_filter_true_for_nested_all() {
        // Mirrors Swift: chainHasPrunableFilter([.all([.hasFeatureFlag(.hasImage)])]) == true
        assert!(BitmapEvaluator::chain_has_prunable_filter(&[Filter::All(vec![
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_IMAGE)
        ])]));
    }

    #[test]
    fn chain_has_prunable_filter_false_for_threshold_only() {
        // Mirrors Swift: chainHasPrunableFilter([.currentlyBelieve, .trustworthy]) == false
        assert!(!BitmapEvaluator::chain_has_prunable_filter(&[
            Filter::CurrentlyBelieve,
            Filter::Trustworthy
        ]));
    }

    #[test]
    fn container_survives_set_bit_present_passes() {
        // Fingerprint whose operational field has the HAS_VOICE bit set →
        // a chain requiring HAS_VOICE admits it. Mirrors Swift containerSurvival.
        let with_voice = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_VOICE,
            0,
        );
        assert!(BitmapEvaluator::container_survives(
            &[Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE)],
            with_voice
        ));
    }

    #[test]
    fn container_survives_set_bit_absent_prunes() {
        // Fingerprint with HAS_IMAGE but not HAS_VOICE → a chain requiring
        // HAS_VOICE prunes it. Mirrors Swift containerSurvival.
        let with_image = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_IMAGE,
            0,
        );
        assert!(!BitmapEvaluator::container_survives(
            &[Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE)],
            with_image
        ));
    }

    #[test]
    fn container_survives_threshold_filter_never_prunes() {
        // A threshold filter (CurrentlyBelieve) cannot prune via an OR, so the
        // container always survives regardless of the fingerprint bits.
        // Mirrors Swift: containerSurvives(chain: [.currentlyBelieve], ...) == true
        let with_image = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_IMAGE,
            0,
        );
        assert!(BitmapEvaluator::container_survives(
            &[Filter::CurrentlyBelieve],
            with_image
        ));
    }

    #[test]
    fn container_survives_conjunction_missing_conjunct_prunes() {
        // Conjunction: a missing conjunct makes the whole conjunction
        // unsatisfiable; the container is pruned.
        // Mirrors Swift: !containerSurvives(chain: [.all([.hasVoice, .hasImage])],
        //                                   fingerprint: withVoice)
        let with_voice = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_VOICE,
            0,
        );
        assert!(!BitmapEvaluator::container_survives(
            &[Filter::All(vec![
                Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
                Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_IMAGE),
            ])],
            with_voice
        ));
    }

    #[test]
    fn container_survives_disjunction_one_satisfiable_disjunct_passes() {
        // Disjunction: one satisfiable disjunct is enough; the container survives.
        // Mirrors Swift: containerSurvives(chain: [.any([.hasVoice, .hasImage])],
        //                                  fingerprint: withVoice) == true
        let with_voice = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_VOICE,
            0,
        );
        assert!(BitmapEvaluator::container_survives(
            &[Filter::Any(vec![
                Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
                Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_IMAGE),
            ])],
            with_voice
        ));
    }

    #[test]
    fn container_survives_negation_gives_no_exclusion() {
        // `Not` gives no sound exclusion from an OR fingerprint, so the
        // container always survives under a negation filter.
        // Mirrors Swift: containerSurvives(chain: [.not(.hasVoice)], ...) == true
        let with_image = crate::container_fingerprint_store::ContainerFingerprint::new(
            0,
            DrawerFeatureFlags::HAS_IMAGE,
            0,
        );
        assert!(BitmapEvaluator::container_survives(
            &[Filter::Not(Box::new(Filter::HasFeatureFlag(
                DrawerFeatureFlags::HAS_VOICE
            )))],
            with_image
        ));
    }

    #[test]
    fn recall_prunes_non_matching_container_and_returns_equivalent_rows() {
        // End-to-end pruning path: capture a hasVoice drawer into room r1
        // and a hasImage drawer into room r2. A recall filtering on hasVoice
        // prunes r2 (its OR lacks the bit) and returns only d1.
        //
        // Mirrors Swift RecallPruningTests:
        //   "Recall prunes a non-matching container and returns the equivalent rows"
        let estate = make_estate();

        // d1: hasVoice in room r1 — survives the prune
        let d1 = capture_with_flags(&estate, "c-d1", "r1", DrawerFeatureFlags::HAS_VOICE, 1_700_000_001);
        // d2: hasImage in room r2 — pruned (lacks HAS_VOICE)
        let _d2 = capture_with_flags(&estate, "c-d2", "r2", DrawerFeatureFlags::HAS_IMAGE, 1_700_000_002);

        // Filter::Unconfirmed suppresses the default UserConfirmed insertion so
        // freshly captured (Unconfirmed) drawers surface. The prune decision is
        // orthogonal to the confirmation axis: the HasFeatureFlag filter drives it.
        let frame = RecallFrame::new(vec![
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
            Filter::Unconfirmed,
        ]);
        let rows = estate.recall(frame, 1_700_000_003).collect_all();

        assert_eq!(rows.len(), 1, "only the hasVoice drawer survives the prune");
        assert_eq!(rows[0].id, d1.id, "surviving drawer is d1 (hasVoice)");
    }

    #[test]
    fn recall_pruned_skipped_container_returns_no_rows_from_it() {
        // A pruned container contributes zero rows to the result.
        // Verify both that the pruned room's drawer is absent and that the
        // surviving room's drawer is present.
        let estate = make_estate();

        let d_voice = capture_with_flags(
            &estate, "voice", "voice-room", DrawerFeatureFlags::HAS_VOICE, 1_700_000_001,
        );
        let _d_image = capture_with_flags(
            &estate, "image", "image-room", DrawerFeatureFlags::HAS_IMAGE, 1_700_000_002,
        );

        let frame = RecallFrame::new(vec![
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
            Filter::Unconfirmed,
        ]);
        let rows = estate.recall(frame, 1_700_000_003).collect_all();

        let ids: Vec<&str> = rows.iter().map(|d| d.id.as_str()).collect();
        assert!(ids.contains(&d_voice.id.as_str()), "voice drawer must be present");
        assert!(
            !ids.iter().any(|id| *id == _d_image.id.as_str()),
            "image-only drawer must be absent (pruned)"
        );
    }

    #[test]
    fn result_identity_pruned_vs_unpruned_scan_on_same_fixture() {
        // Pruning is an optimization, never a result change.
        //
        // The pruning path (hasVoice chain, which engages container pruning)
        // and the non-pruning path (same hasVoice chain, same data) must
        // return identical row sets. This assertion holds because:
        //   - Both paths apply the same BitmapEvaluator filter.
        //   - The pruning path only skips containers whose OR proves they
        //     hold no matching row; it never skips a container that could
        //     match.
        //   - Therefore the result is identical to what the per-row filter
        //     would produce over the full corpus.
        //
        // We verify identity by first running the pruned recall, then
        // manually computing what an exhaustive scan returns, and asserting
        // the two ID sets are equal.
        let estate = make_estate();

        let d1 = capture_with_flags(&estate, "a-voice", "room-a", DrawerFeatureFlags::HAS_VOICE, 1_700_000_001);
        let d2 = capture_with_flags(&estate, "b-voice", "room-b", DrawerFeatureFlags::HAS_VOICE, 1_700_000_002);
        let _d3 = capture_with_flags(&estate, "c-image", "room-c", DrawerFeatureFlags::HAS_IMAGE, 1_700_000_003);
        let _d4 = capture_with_flags(&estate, "d-plain", "room-d", 0, 1_700_000_004);

        // Pruning path: chain_has_prunable_filter is true for HasFeatureFlag.
        // Filter::Unconfirmed suppresses default UserConfirmed insertion so
        // freshly captured drawers surface.
        let pruned_frame = RecallFrame::new(vec![
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
            Filter::Unconfirmed,
        ]);
        let mut pruned_ids: Vec<String> =
            estate.recall(pruned_frame, 1_700_000_005).collect_all().into_iter().map(|d| d.id).collect();
        pruned_ids.sort();

        // Expected result: the two hasVoice drawers only.
        let mut expected: Vec<String> = vec![d1.id.clone(), d2.id.clone()];
        expected.sort();

        assert_eq!(
            pruned_ids, expected,
            "pruned recall must return the same rows as a full per-row filter"
        );
    }

    #[test]
    fn bounded_behavior_held_with_pruning_path() {
        // The pruning path applies prefix(scan_bound) after collection so it
        // obeys the same scan_bound as the non-pruning path (mirrors Swift's
        // `candidates = Array(rows.prefix(scanBound))`). Use a small explicit
        // limit to verify the cap is respected.
        let estate = make_estate();

        // Capture 10 drawers with HAS_VOICE into 10 distinct rooms.
        for i in 0..10 {
            capture_with_flags(
                &estate,
                &format!("v{i}"),
                &format!("room-{i}"),
                DrawerFeatureFlags::HAS_VOICE,
                1_700_000_000 + i,
            );
        }

        // limit = 3 → scan_bound = max(3, RECALL_CANDIDATE_CAP) = 256.
        // All 10 are within 256, so all 10 survive. But with limit=3 the
        // RecallStream returns at most 3 per page; collect_all drains pages.
        // The point: the scan_bound does NOT silently truncate 10 to 3 — the
        // limit is for pagination, not for corpus truncation when estate < cap.
        // Filter::Unconfirmed suppresses default UserConfirmed insertion.
        let mut frame = RecallFrame::new(vec![
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
            Filter::Unconfirmed,
        ]);
        frame.limit = Some(3);
        let all_rows = estate.recall(frame, 1_700_000_020).collect_all();
        assert_eq!(
            all_rows.len(),
            10,
            "all 10 hasVoice drawers must be reachable across pages"
        );
    }

    // --- recall internal-read failure surfacing (P0-5 sites 1-5) ---
    //
    // A failed internal read (live_rows / room-fingerprints / room-drawer /
    // bitmap-eval) must be DISTINGUISHABLE from a genuine-empty estate: it
    // names a `locus.*` stage on the stream's degraded_stages, while a genuine
    // recall (empty or not) names none. The fault is injected via the Estate
    // single-use seam (available under cfg(test)).

    /// Seed an estate with one hasVoice drawer in room r1 so the
    /// fingerprint-pruning path visits a surviving room.
    fn seeded_voice_estate() -> Estate {
        let estate = make_estate();
        let mut voice = CaptureFrame::new(
            "v", CaptureChannel::Typed, "r1",
            LatticeAnchor::udc("5"), "alice", "test-v1",
        );
        voice.feature_flags = DrawerFeatureFlags::HAS_VOICE;
        estate.capture(voice, 1_700_000_001).unwrap();
        estate
    }

    #[test]
    fn recall_genuine_empty_has_no_degraded_stage() {
        // Empty estate, no fault armed → empty result, NO degraded stage.
        let estate = make_estate();
        let stream = estate.recall(RecallFrame::new(vec![]), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert!(rows.is_empty());
        assert!(stages.is_empty(), "genuine-empty estate must record no degraded stage");
    }

    #[test]
    fn recall_success_has_no_degraded_stage() {
        let estate = seeded_voice_estate();
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let stream = estate.recall(RecallFrame::new(chain), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert_eq!(rows.len(), 1);
        assert!(stages.is_empty());
    }

    #[test]
    fn recall_live_rows_failure_surfaced() {
        // Empty filter chain → non-pruning bounded scan (live_rows path).
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::LiveRows));
        let stream = estate.recall(RecallFrame::new(vec![]), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert!(rows.is_empty(), "failed scan yields no rows");
        assert_eq!(stages, vec!["locus.liveRows.readFailed".to_string()],
            "a FAILED scan is distinguishable from a genuine-empty estate");
    }

    #[test]
    fn recall_room_fingerprints_failure_surfaced() {
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::RoomFingerprints));
        // Prunable filter → fingerprint-pruning path (room_level_fingerprints).
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let stream = estate.recall(RecallFrame::new(chain), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert!(rows.is_empty());
        assert_eq!(stages, vec!["locus.roomFingerprints.readFailed".to_string()]);
    }

    #[test]
    fn recall_room_drawer_read_failure_surfaced() {
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::RoomDrawerRead));
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let stream = estate.recall(RecallFrame::new(chain), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert!(rows.is_empty(), "a failed surviving-room read yields no rows for that room");
        assert_eq!(stages, vec!["locus.roomDrawerRead.readFailed".to_string()]);
    }

    #[test]
    fn recall_bitmap_eval_failure_surfaced() {
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::BitmapEval));
        let stream = estate.recall(RecallFrame::new(vec![]), 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert!(rows.is_empty());
        assert_eq!(stages, vec!["locus.bitmapEval.failed".to_string()]);
    }

    #[test]
    fn recall_fault_seam_is_single_use() {
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::LiveRows));

        let first = estate.recall(RecallFrame::new(vec![]), 1_700_000_010);
        let (_r1, s1) = first.collect_all_with_degraded();
        assert_eq!(s1, vec!["locus.liveRows.readFailed".to_string()]);

        // Seam consumed — next recall is a normal, successful read.
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let second = estate.recall(RecallFrame::new(chain), 1_700_000_011);
        let (r2, s2) = second.collect_all_with_degraded();
        assert_eq!(r2.len(), 1);
        assert!(s2.is_empty());
    }

    // --- trace-WRITE failure is fail-closed (rows still returned) ---
    //
    // The trace write fires AFTER reads + eval succeed and ONLY when the caller
    // opts in via trace_limit on a non-empty result. A forced `TraceWrite` fault
    // must therefore yield a POPULATED result WITH the `recall.trace_write_failed`
    // stage — proving recall stays non-throwing (spec § 7.8.1) while a dropped
    // trace (the reward sweep's missing input) is observable, not silent.

    #[test]
    fn recall_trace_write_failure_surfaced_rows_still_returned() {
        let estate = seeded_voice_estate();
        estate.set_test_force_internal_read_error(Some(
            crate::estate::RecallInternalRead::TraceWrite));
        // trace_limit opts the caller into the reward cycle so the write runs.
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let mut frame = RecallFrame::new(chain);
        frame.trace_limit = Some(5);
        let stream = estate.recall(frame, 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        // Non-throwing: the caller STILL receives its rows despite the lost trace.
        assert_eq!(rows.len(), 1,
            "recall stays non-throwing — a trace-write fault must not empty the result");
        // The dropped trace is observable on the same degraded_stages channel.
        assert_eq!(stages, vec!["recall.trace_write_failed".to_string()],
            "a lost recall trace must be observable, not silently swallowed");
    }

    #[test]
    fn recall_trace_write_success_records_no_stage() {
        // Healthy control: trace_limit set, write succeeds → rows, NO stage.
        let estate = seeded_voice_estate();
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE), Filter::Unconfirmed];
        let mut frame = RecallFrame::new(chain);
        frame.trace_limit = Some(5);
        let stream = estate.recall(frame, 1_700_000_010);
        let (rows, stages) = stream.collect_all_with_degraded();
        assert_eq!(rows.len(), 1);
        assert!(stages.is_empty(), "a clean trace write records no degraded stage");
    }

    // --- Recall hygiene: charter exclusion (fix/recall-hygiene-charters-ghosts) ---

    /// Charter drawers seeded via seed_wing must never surface in scored recall.
    ///
    /// After seeding one charter wing and capturing two content drawers,
    /// recall (CurrentlyBelieve) must return exactly the two content drawers
    /// and zero charter drawers.
    ///
    /// Hint drawers (seeded at provision in AI_Charter_Hint room) are normal
    /// drawers — they ARE returned by recall like any other drawer.
    ///
    /// Parity with Swift RecallHygieneTests updated for new normal behavior.
    #[test]
    fn recall_includes_hint_drawers_as_normal_content() {
        let estate = make_estate();
        let now = 1_700_000_000_i64;

        // Seed one wing — produces a hint drawer in room "AI_Charter_Hint".
        estate
            .seed_wing("Agentic Memory", "AI observations and inferences.", "test-model", now)
            .expect("seed_wing must succeed");

        // Capture two content drawers in a normal room.
        let content_a = basic_capture(&estate, "content alpha — hint test", "hygiene-room");
        let content_b = basic_capture(&estate, "content beta — hint test", "hygiene-room");

        // Recall with CurrentlyBelieve — hint drawers are now recallable.
        let frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        let rows = estate.recall(frame, now + 10).collect_all();

        // All three drawers (1 hint + 2 content) must be in recall results.
        let hint_hits: Vec<_> = rows
            .iter()
            .filter(|d| d.added_by == crate::default_wings::HINT_ADDED_BY)
            .collect();
        assert_eq!(
            hint_hits.len(),
            1,
            "recall must include the 1 hint drawer; got {}",
            hint_hits.len()
        );

        // The content drawers must also be returned.
        let content_ids: std::collections::HashSet<&str> =
            rows.iter().map(|d| d.id.as_str()).collect();
        assert!(
            content_ids.contains(content_a.id.as_str()),
            "recall must return content drawer A"
        );
        assert!(
            content_ids.contains(content_b.id.as_str()),
            "recall must return content drawer B"
        );

        // Total: 1 hint + 2 content drawers.
        assert_eq!(
            rows.len(),
            3,
            "recall must return 3 drawers (1 hint + 2 content); got {}",
            rows.len()
        );
    }

    /// Hint drawers are accessible via both recall and store reads.
    ///
    /// Parity with Swift RecallHygieneTests H7 updated for new normal behavior.
    #[test]
    fn hint_drawers_present_in_both_recall_and_store() {
        let estate = make_estate();
        let now = 1_700_000_000_i64;

        // Seed two wings → two hint drawers in "AI_Charter_Hint".
        estate
            .seed_wing("Wing One", "First wing hint.", "test-model", now)
            .expect("seed_wing one");
        estate
            .seed_wing("Wing Two", "Second wing hint.", "test-model", now + 1)
            .expect("seed_wing two");

        // Capture one content drawer.
        let _content = basic_capture(&estate, "user content — hint presence test", "content-room");

        // Recall returns hint drawers (normal recall behavior now).
        let frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        let recall_rows = estate.recall(frame, now + 10).collect_all();
        let recalled_hints: Vec<_> = recall_rows
            .iter()
            .filter(|d| d.added_by == crate::default_wings::HINT_ADDED_BY)
            .collect();
        assert_eq!(
            recalled_hints.len(),
            2,
            "recall must include both hint drawers; got {}",
            recalled_hints.len()
        );

        // Hint drawers also exist in the raw store.
        let all_drawers = estate
            .store
            .all_drawers_bounded(None)
            .expect("all_drawers_bounded must succeed");
        let stored_hints: Vec<_> = all_drawers
            .iter()
            .filter(|d| d.added_by == crate::default_wings::HINT_ADDED_BY)
            .collect();
        assert_eq!(
            stored_hints.len(),
            2,
            "store must contain both hint drawers; got {}",
            stored_hints.len()
        );
    }

    // --- Timestamp-unit guards (Codex 0e9d4e43e8cc8191ac913a3fddcad48c) ---
    //
    // The whole boundary is epoch MILLISECONDS: `HLCGenerator::send` stores
    // `now` directly as `last_physical`, and `TypedValue::Timestamp` is a
    // millisecond codec. Nothing multiplies on the way in. A verb that supplies
    // seconds backdates its event to 1970 and breaks HLC audit ordering.

    #[test]
    fn now_ms_returns_epoch_millisecond_magnitude() {
        // Epoch-milliseconds floor: 2023-01-01 UTC ≈ 1_672_531_200_000
        // Epoch-milliseconds ceil:  2035-01-01 UTC ≈ 2_051_222_400_000
        let now = Estate::now_ms();
        assert!(
            now >= 1_672_531_200_000 && now < 2_051_222_400_000,
            "now_ms() must return epoch milliseconds (magnitude ~1.7e12, got {now}); \
             a ~1_000x smaller value means the helper is still returning seconds"
        );
    }

    #[test]
    fn mutate_confirm_hlc_physical_time_is_millisecond_magnitude() {
        // RESTART-HONEST. `HLCGenerator::send` only adopts `now` when
        // `now > last_physical`; otherwise it bumps the logical counter and
        // *inherits* the previous physical time. So if a capture in this same
        // process has already pushed `last_physical` to ~1.7e12, a
        // seconds-valued mutation silently inherits the correct magnitude and
        // the defect is invisible — which is exactly why the previous version
        // of this test passed against the bug.
        //
        // Capturing at an early-1970 instant reproduces the condition a daemon
        // restart creates: a generator whose `last_physical` is NOT already at
        // millisecond magnitude. A seconds-valued mutation (~1.7e9) then
        // exceeds it, is adopted as the physical time, and fails this assert.
        let estate = make_estate();
        let frame = CaptureFrame::new(
            "hlc-magnitude check",
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("5"),
            "alice",
            "test-v1",
        );
        // 1970-01-12 in epoch ms — a valid instant well below both the
        // seconds-magnitude (~1.7e9) and millisecond-magnitude (~1.7e12) values.
        const EARLY_MS: i64 = 1_000_000;
        let drawer = estate.capture(frame, EARLY_MS).unwrap();

        estate
            .mutate(&drawer.id, MutationKind::Confirm, None)
            .unwrap();

        // Two audit events: capture (index 0) and confirm (index 1).
        let events = estate
            .store
            .audit_events_for_row(&drawer.id)
            .expect("InMemoryDrawerStore must return audit events");
        assert_eq!(events.len(), 2, "expected capture + confirm audit events");

        let hlc = events[1].hlc;
        assert!(
            hlc.physical_time >= 1_672_531_200_000 && hlc.physical_time < 2_051_222_400_000,
            "confirm audit HLC physical_time must be epoch milliseconds (~1.7e12, got {}); \
             a ~1.7e9 value means the verb is still supplying seconds",
            hlc.physical_time
        );

        // Ordering: the mutation must sort AFTER the capture it modified.
        // This is the consequence the unit bug actually produces in the audit log.
        assert!(
            events[1].hlc.physical_time > events[0].hlc.physical_time,
            "mutation (physical {}) must sort after the capture it modified (physical {})",
            events[1].hlc.physical_time,
            events[0].hlc.physical_time
        );
    }
}
