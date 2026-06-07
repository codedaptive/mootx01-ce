//! Estate verb surface. Ports `EstateVerbs.swift`.
//!
//! Implements `capture`, `recall`, `withdraw`, and `expunge` as
//! working verbs and `mutate`, `reanchor`, `learn` as stubs that
//! return `LocusKitError::InvalidContent` until their owning missions
//! ship.
//! Mirrors the Swift split: `Estate.swift` carries the lifecycle
//! surface; this file carries the verbs.
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
//!   port mirrors that: evaluate errors collapse to an empty row set, and
//!   a `RecallStream` is returned directly (not wrapped in `Result`).
//! - Swift maintains a `containerFP` OR aggregate for fingerprint pruning
//!   (spec § 11.5). The Rust port omits this because `Estate.store` does
//!   not carry a `containerFP` field and adding one would modify the landed
//!   estate.rs body (out of scope here). The unpruned path —
//!   `store.all_drawers()` filtered to non-tombstoned — is used instead,
//!   which is sound (correct, just slower for large corpora at which point
//!   the SQLite backend and fingerprint pruning land together).

use crate::adjectives::{State, Trust};
use crate::bitmap_evaluator::BitmapEvaluator;
use crate::drawer::Drawer;
use crate::drawer_operational::DrawerFeatureFlags;
use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::frames::TunnelCaptureFrame;
use crate::frames::{AssociateFrame, CaptureFrame, LearnFrame, MutationKind, ProposeFrame};
use crate::provenance::Confirmation;
use crate::recall_stream::RecallStream;
use crate::tunnel::Tunnel;

use crate::filter::RecallFrame;
use crate::recall_trace_item::RecallTraceItem;
use uuid::Uuid;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;
use substrate_lib::row_state::RowVerb;

impl Estate {
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
    /// predecessor's state nibble flips to `Superseded` via
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
    ///   - bits 6–11:  `content_kind`    (contiguous raw 0..6)
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

        // Operational bitmap assembly (cookbook §2.4 v0.6 layout):
        //   bits 0–5   capture_channel (contiguous raw 0..5)
        //   bits 6–11  content_kind    (contiguous raw 0..6)
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
        //   bits 0–5  state                 (default 0 = Active)
        //   bits 6–11 adjective_sensitivity (scale-gapped raw 0/16/32/48)
        //
        // The sensitivity raw values are scale-gapped and packed via
        // write_field into the 6-bit window at bits 6–11.
        // Per Adjectives.swift / spec § 5.5.
        let adj_bitmap = bit_field::write_field(frame.sensitivity.raw_value(), 0, 6, 6);

        // Provenance bitmap assembly (cookbook §2.5 layout):
        //   bits 0–5   source_type           (SourceType raw)
        //   bits 6–11  channel               (provenance Channel raw)
        //   bits 30–35 sensitivity           (provenance Sensitivity raw)
        // Other provenance slots (capture_channel mirror, confirmation,
        // confidence, enrichment_status) are populated by downstream
        // daemons or held at zero by default. Mirrors EstateVerbs.swift.
        let provenance_bitmap = bit_field::write_field(
            frame.provenance_sensitivity.raw_value(),
            bit_field::write_field(
                frame.provenance_channel.raw_value(),
                bit_field::write_field(frame.source_type.raw_value(), 0, 0, 6),
                6,
                6,
            ),
            30,
            6,
        );

        // Derive the default wing from the manifest owner identifier.
        // The owner field is set at Estate::create time; an empty owner
        // falls back to "wing_default" so capture never blocks on an
        // uninitialized manifest.
        let owner = self
            .store
            .read_manifest()
            .map(|m| m.owner_identifier)
            .unwrap_or_default();
        let wing = if owner.is_empty() {
            "wing_default".to_string()
        } else {
            format!("wing_{}", owner)
        };

        // Stamp a lineage id: use the caller's if provided, otherwise fresh.
        let lineage_id = frame.lineage_id.unwrap_or_else(Uuid::new_v4);

        let drawer_id = Uuid::new_v4().to_string();
        let mut drawer = Drawer::new(
            drawer_id,
            frame.content,
            wing,
            frame.room,
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
    /// matches the cascade and files via the bare-insert `add_tunnel`.
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

        // Encode origin_class into bits 6–8 of the tunnel operational bitmap.
        // The decoder (`Tunnel::origin_class()` in `tunnel_operational.rs`) uses
        // `bit_field::extract_field(operational_bitmap, 6, 3)`, so this write
        // is the exact inverse. Default `UserExplicit` (raw 0) produces 0,
        // preserving byte-identical all-zero defaults for existing callers
        // (spec § 5.6 / cookbook §2.4).
        let op_bitmap = bit_field::write_field(frame.origin_class.raw_value(), 0, 6, 3);
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
        tunnel.source_drawer_id = frame.source_drawer_id;
        tunnel.target_drawer_id = frame.target_drawer_id;
        tunnel.operational_bitmap = op_bitmap;
        self.store.add_tunnel(&tunnel)?;
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
    /// This method is **non-throwing** (matching Swift semantics): evaluate
    /// errors collapse to an empty row set. The empty stream is the
    /// documented signal that no rows matched; callers that need to
    /// distinguish the two go through the substrate directly.
    ///
    /// One `RecallTraceItem` is inserted per returned row (used = false).
    /// This is the "later two-source reward" hook from the NEURONKIT_SPEC
    /// § 3.1: the reward path later sets `used = true` for rows the caller
    /// acted on, enabling Bradley-Terry to distinguish acted-on rows from
    /// ignored ones. Trace insertion failures are silenced so a storage
    /// fault does not break the caller's result.
    ///
    /// `now` is stamped once at the verb boundary per the
    /// deterministic-clock rule (CLAUDE.md). The trace rows record
    /// `recalled_at` so the reward sweep can group rows by recall session.
    pub fn recall(&self, frame: RecallFrame, now: i64) -> RecallStream {
        // Fetch all drawers and filter to non-tombstoned (live corpus).
        // The unpruned path is used because Estate.store carries no
        // containerFP field (adding one would modify the landed estate.rs
        // body, which is out of scope here).
        let live: Vec<Drawer> = self
            .store
            .all_drawers()
            .unwrap_or_default()
            .into_iter()
            .filter(|d| d.tombstoned_at.is_none())
            .collect();

        // Run the four-tier bitmap evaluator pipeline. Errors collapse to
        // an empty result — recall is non-throwing per spec § 7.8.1.
        let filtered: Vec<Drawer> =
            BitmapEvaluator::evaluate(&frame, &live, self.store.as_ref()).unwrap_or_default();

        // Stamp one RecallTraceItem per returned row.
        // `recalled_at` is stored as TEXT ISO8601 per the fleet date rule.
        let recalled_at = epoch_to_iso8601(now);
        for drawer in &filtered {
            let trace = RecallTraceItem::new(
                Uuid::new_v4().to_string(),
                drawer.id.clone(),
                recalled_at.clone(),
                None, // ordered-by-capture-time recalls carry no score
                0,    // operational_bitmap = 0 (used = false)
            );
            // Silence errors — a storage fault must not break the recall result.
            let _ = self.store.insert_recall_trace(&trace);
        }

        let page_size = frame.limit.unwrap_or(RecallStream::DEFAULT_PAGE_SIZE);
        RecallStream::new(filtered, page_size, frame.hydration_level)
    }

    // -----------------------------------------------------------------------
    // tunnels_from_wing
    // -----------------------------------------------------------------------

    /// Read the tunnels originating in `wing` — the estate-level surface over
    /// `DrawerStore::tunnels_from_wing`. The drawer-to-drawer tunnels are the
    /// edges of the estate's association graph; a reasoning lens (e.g.
    /// keystone centrality) consumes them through the kit. Read-only.
    pub fn tunnels_from_wing(&self, wing: &str) -> Result<Vec<Tunnel>, LocusKitError> {
        self.store.tunnels_from_wing(wing)
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

    /// All kg-facts in the estate where state cluster < 7, ordered by
    /// `filed_at` ascending. Estate-level pass-through over
    /// `DrawerStore::all_kg_facts`.
    pub fn all_kg_facts(&self) -> Result<Vec<crate::kg_fact::KGFact>, LocusKitError> {
        self.store.all_kg_facts()
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

    /// All tunnels in the estate across all wings. Estate-level pass-through
    /// over `DrawerStore::all_tunnels`. Used by GLK to expose the full
    /// association graph the dreaming reader needs (B-1 compliance).
    pub fn all_tunnels(&self) -> Result<Vec<crate::tunnel::Tunnel>, LocusKitError> {
        self.store.all_tunnels()
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
        )
    }

    // -----------------------------------------------------------------------
    // expunge
    // -----------------------------------------------------------------------

    /// Expunge a row (hard remove). Per cookbook §10.5: tombstones
    /// the row, zeroes its content blob, sets the
    /// `dreaming_recalc_required` worklist marker (adjective bit 26)
    /// synchronously, leaves aggregates untouched (§9.5.1: already
    /// de-identified statistical roll-ups), and emits a sealed audit
    /// event so the fact-of-expunge is preserved (v0.35 I-6).
    ///
    /// Cookbook preconditions: "None beyond row existing." The
    /// `confirmation: bool` parameter is a caller-supplied safety
    /// check; expunge is destructive (the verbatim content is gone
    /// after this call returns) so the API requires an explicit
    /// `true` to proceed. Estate-level toggles (F17 second pass
    /// item 2) are not in cookbook today and not enforced here.
    ///
    /// The cross-kit RAG vector delete (§10.5 second postcondition)
    /// is GLK's orchestration responsibility (F17 second pass item 4)
    /// and not invoked here; LocusKit's expunge is the storage-layer
    /// half.
    pub fn expunge(
        &self,
        row_id: &str,
        reason: &str,
        confirmation: bool,
    ) -> Result<(), LocusKitError> {
        if !confirmation {
            return Err(LocusKitError::InvalidContent(
                "expunge requires confirmation: true (destructive op)".to_string(),
            ));
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
        let reason_opt = if reason.is_empty() {
            Some("expunged via Estate.expunge")
        } else {
            Some(reason)
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.store
            .expunge_gated(row_id, &changed_by, reason_opt, now)
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

    /// Current time as epoch milliseconds. Used anywhere a store method takes
    /// `now: i64`. The HLC generator (`hlc.rs`) expects milliseconds; using
    /// seconds produces physical_time ~1000× too small (timestamps in 1970).
    /// Mirrors the pre-existing `expunge` and `reanchor` arms, which both
    /// compute `as_millis()`.
    fn now_millis() -> i64 {
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
    /// CorrectTrust) recompose `adjective_bitmap` and persist via
    /// `DrawerStore::mutate_adjective`. Guard conditions: Resolve requires
    /// current state == Contested; Accept requires trust >= Canonical (S-1);
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
                let now = Self::now_millis();

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
                // pending → reject → rejected per automaton §9.2.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_millis();
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
                let now = Self::now_millis();
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
                let now = Self::now_millis();
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
                let now = Self::now_millis();
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
                let now = Self::now_millis();
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
                // Guard: revive is only valid from Cluster B (historical) states
                // per ARCH SPEC §6.2. Cluster A and Cluster C are not eligible.
                let state = State::from_raw(bit_field::extract_field(drawer.adjective_bitmap, 0, 6));
                let is_knew_past = matches!(
                    state,
                    State::Superseded | State::Decayed | State::Withdrawn | State::Expired
                );
                if !is_knew_past {
                    return Err(LocusKitError::InvalidContent(format!(
                        "revive: only valid from Cluster B states (Decayed, Withdrawn, Expired, Superseded); current: {state:?}"
                    )));
                }
                // The canonical automaton (cookbook §9.2) supports only
                // Decayed → Observe → Active. Withdrawn, Expired, and Superseded
                // → Active are not in the automaton table; those attempts surface
                // as a gate discipline violation. See LOCUSKIT_SPEC_v0.8.md §revive;
                // a follow-up mission must extend the automaton to support
                // withdrawn/expired/superseded → active.
                let changed_by = self.changed_by_or_estate();
                let now = Self::now_millis();
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
                let now = Self::now_millis();
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
                let now = Self::now_millis();
                self.store.mutate_adjective(
                    row_id,
                    new_adjective,
                    &changed_by,
                    Some(_payload.unwrap_or("trust corrected via Estate.mutate")),
                    now,
                )
            }
        }
    }

    /// Reanchor a drawer to a different room and/or lattice position.
    ///
    /// Moves the row's placement: `to_room` changes the `room` column;
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
        to_lattice: Option<crate::estate_types::LatticeAnchor>,
    ) -> Result<(), LocusKitError> {
        if to_room.is_none() && to_lattice.is_none() {
            return Err(LocusKitError::InvalidContent(
                "reanchor requires toRoom or toLattice".to_string(),
            ));
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.store.reanchor_gated(
            row_id,
            to_room,
            to_lattice,
            &changed_by,
            Some("reanchored via Estate.reanchor"),
            now,
        )
    }

    // MARK: - propose

    /// Create a proposal targeting a row in the estate. Mirrors `Estate.propose` in Swift.
    ///
    /// Validates that the target drawer exists, assembles `operational_bitmap`
    /// from the `ProposeFrame.kind` (bits 0–5) and `ProposalTargetObjectType::Drawer`
    /// (bits 6–11, raw 0), sets `adjective_bitmap` state to `State::Pending` (raw 1)
    /// at bits 0–5, derives `candidate_state` and `lattice_anchor` from the target
    /// drawer, then calls `DrawerStore::add_proposal`. Per cookbook §10.7.
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

        // Operational bitmap: ProposalKind at bits 0–5, ProposalTargetObjectType
        // (.drawer = 0) at bits 6–11. Remaining axes default to 0 (confirmation
        // .human, generated-by .dreamingDaemon, confidence .null).
        // bit_field::write_field(value, into_bitmap, shift, width).
        let kind_in_op = bit_field::write_field(frame.kind as i64, 0i64, 0, 6);
        let op_bitmap = bit_field::write_field(
            0i64, // ProposalTargetObjectType::Drawer raw value = 0
            kind_in_op,
            6,
            6,
        );

        // Adjective bitmap: state .pending at bits 0–5, raw value 1.
        // bit_field::write_field(value, into_bitmap, shift, width).
        let adj_bitmap = bit_field::write_field(
            crate::adjectives::State::Pending as i64,
            0i64,
            0,
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

        // Association label derives from endpoint A's room and endpoint B's room.
        let label = format!("{}→{}", drawer_a.room, drawer_b.room);

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
            source_wing: drawer_a.wing.clone(),
            source_room: drawer_a.room.clone(),
            source_drawer_id: Some(drawer_a.id.clone()),
            target_wing: drawer_b.wing.clone(),
            target_room: drawer_b.room.clone(),
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

    /// Bring an external reference into the estate by handle. Mirrors `Estate.learn` in Swift.
    ///
    /// Constructs a `LearnedReference` with `source_catalog_id` set to the frame's
    /// handle (v1 placeholder — `SourceCatalogEntry` is spec-only, not yet implemented),
    /// sentinel `lattice_anchor` ("0" UDC code per Known Ambiguity), and
    /// `added_by = "learn"`. Per cookbook §10.9 / spec § 7.8.2.
    ///
    /// - `frame.handle` must be non-empty; returns `LocusKitError::InvalidContent` if empty.
    /// - `now` is epoch seconds.
    pub fn learn(
        &self,
        frame: LearnFrame,
        now: i64,
    ) -> Result<crate::learned_reference::LearnedReference, LocusKitError> {
        if frame.handle.is_empty() {
            return Err(LocusKitError::InvalidContent(
                "learn handle must not be empty".to_string(),
            ));
        }

        // Trust::Canonical encodes as raw value 3 (adjectives.rs Trust::Canonical = 3).
        // Cookbook §2.3: trust axis at bits 18–23 of adjective_bitmap.
        // bit_field::write_field(value, into_bitmap, shift, width).
        let adj_bitmap = bit_field::write_field(
            crate::adjectives::Trust::Canonical as i64,
            0i64,
            18,
            6,
        );

        // Sentinel lattice anchor ("0" UDC code) — SourceCatalogEntry is spec-only;
        // the enrichment daemon will resolve the real anchor when it runs.
        let ref_row = crate::learned_reference::LearnedReference {
            id: Uuid::new_v4().to_string(),
            source_catalog_id: frame.handle.clone(), // v1 placeholder — no SourceCatalogEntry yet
            handle: frame.handle,
            lattice_anchor: crate::estate_types::LatticeAnchor {
                udc_code: "0".to_string(),
                udc_facets: None,
                wikidata_qid: None,
                wikidata_qids_secondary: None,
            },
            adjective_bitmap: adj_bitmap,
            operational_bitmap: 0,
            provenance_bitmap: 0,
            added_by: "learn".to_string(),
            filed_at: now,
            tombstoned_at: None,
            removed_by_batch: None,
        };
        self.store.add_learned_reference(&ref_row)?;
        Ok(ref_row)
    }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Format an epoch-seconds timestamp as an ISO8601 string for storage in
/// TEXT columns (fleet date-storage rule: TEXT ISO8601, never REAL).
/// Used by `recall` to stamp `recalled_at` on `RecallTraceItem` rows.
///
/// Produces the format `YYYY-MM-DDTHH:MM:SSZ`. This matches the
/// `format_iso8601` helper in `drawer_store_inmemory.rs` so timestamps
/// written by either site sort and compare correctly.
fn epoch_to_iso8601(epoch_seconds: i64) -> String {
    // Simple Gregorian calendar conversion without external crates.
    // Accurate for dates in the range 2001–2100 (the LocusKit operational
    // window); leap-second handling matches the `drawer_store_inmemory`
    // implementation — both ignore leap seconds.
    let (year, month, day, hour, minute, second) = epoch_to_components(epoch_seconds);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, minute, second
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
        let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
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
        estate.capture(frame, 1_700_000_001).unwrap()
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
    fn capture_stores_content_and_room() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "my content", "study");
        assert_eq!(drawer.content, "my content");
        assert_eq!(drawer.room, "study");
    }

    #[test]
    fn capture_wing_derived_from_owner() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "x", "r");
        // Owner is "owner" → wing_owner.
        assert_eq!(drawer.wing, "wing_owner");
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

        let frame = RecallFrame::new(vec![
            Filter::InRoom("hall".to_string()),
            Filter::CurrentlyBelieve,
            Filter::Unconfirmed,
        ]);
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
        assert_eq!(after.room, "study");
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
        // Reject is implemented but automaton only permits it from Pending.
        // Active → reject is an illegal transition; the gate throws InvalidContent.
        let estate = make_estate();
        let drawer = basic_capture(&estate, "x", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Reject, None)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
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

    #[test]
    fn mutate_revive_from_active_throws_cluster_b_guard() {
        let estate = make_estate();
        let drawer = basic_capture(&estate, "cluster-a target", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Revive, None)
            .unwrap_err();
        if let LocusKitError::InvalidContent(msg) = &err {
            assert!(
                msg.contains("revive") || msg.contains("Cluster B") || msg.contains("cluster"),
                "error should identify the revive Cluster B guard: {msg}"
            );
        } else {
            panic!("expected InvalidContent, got {err:?}");
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
    fn reanchor_empty_args_returns_invalid_content() {
        // Belt-and-suspenders guard: both to_room and to_lattice nil.
        let estate = make_estate();
        let err = estate.reanchor("id", None, None).unwrap_err();
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
            )
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn reanchor_to_new_room_updates_room() {
        let estate = make_estate();
        let d = basic_capture(&estate, "content", "original-room");
        estate.reanchor(&d.id, Some("new-room"), None).unwrap();
        let updated = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(updated.room, "new-room");
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
            .reanchor(&d.id, None, Some(LatticeAnchor::udc("003.000")))
            .unwrap();
        let updated = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(updated.udc_code, "003.000");
        // Bitmaps unchanged.
        assert_eq!(updated.adjective_bitmap, d.adjective_bitmap);
        assert_eq!(updated.operational_bitmap, d.operational_bitmap);
        assert_eq!(updated.provenance, d.provenance);
    }

    #[test]
    fn learn_with_empty_handle_returns_invalid_content() {
        let estate = make_estate();
        // learn is now live; an empty handle is invalid.
        let err = estate
            .learn(LearnFrame::new(""), 1_700_000_000)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    #[test]
    fn learn_with_valid_handle_returns_learned_reference() {
        let estate = make_estate();
        let result = estate.learn(LearnFrame::new("test-handle"), 1_700_000_000);
        let ref_row = result.expect("learn should succeed with a valid handle");
        assert_eq!(ref_row.handle, "test-handle");
        assert_eq!(ref_row.source_catalog_id, "test-handle");
        assert_eq!(ref_row.lattice_anchor.udc_code, "0"); // sentinel anchor
        assert_eq!(ref_row.added_by, "learn");
        // Trust::Canonical (raw 3) at bits 18–23 of adjective_bitmap.
        assert_ne!(ref_row.adjective_bitmap, 0);
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
        let err = estate.expunge(&d.id, "", false).unwrap_err();
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
        estate.expunge(&d.id, "operator request", true).unwrap();
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
            .expunge("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "", true)
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
}
