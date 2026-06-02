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
//!   estate.rs body (out of scope per BRR). The unpruned path —
//!   `store.all_drawers()` filtered to non-tombstoned — is used instead,
//!   which is sound (correct, just slower for large corpora at which point
//!   the SQLite backend and fingerprint pruning land together).

use crate::adjectives::State;
use crate::bitmap_evaluator::BitmapEvaluator;
use crate::drawer::Drawer;
use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::frames::TunnelCaptureFrame;
use crate::frames::{CaptureFrame, LearnFrame, MutationKind};
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
    /// Operational bitmap:
    ///   - bits 0–3: `capture_channel` (contiguous raw 0..4)
    ///   - bits 4–7: `content_kind`    (contiguous raw 0..5)
    ///
    /// Adjective bitmap:
    ///   - bits 0–3: state — default 0 (`Active`)
    ///   - bits 4–7: adjective_sensitivity (scale-gapped raw 0/4/8/12,
    ///     shifted left 4 to land in bits 4–7)
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

        // Operational bitmap assembly:
        //   bits 0–3  capture_channel (contiguous raw 0..4)
        //   bits 4–7  content_kind    (contiguous raw 0..5)
        // Per DrawerOperational.swift / spec § 5.6.
        let op_bitmap = bit_field::write_field(
            frame.kind.raw_value(),
            bit_field::write_field(frame.channel.raw_value(), 0, 0, 6),
            6,
            6,
        );

        // Adjective bitmap assembly:
        //   bits 0–3  state             (default 0 = Active)
        //   bits 4–7  adjective_sensitivity (scale-gapped raw 0/4/8/12)
        //
        // The sensitivity raw values are scale-gapped (0/16/32/48), so shifting
        // left 4 lands them exactly in bits 4–7.
        // Per Adjectives.swift / spec § 5.5.
        // F18: cookbook §2.3 sensitivity at bits 6-11.
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

        // Bitmaps left at `Tunnel::new`'s all-zero defaults, byte-identical
        // to the cascade's `Tunnel::new(...)` construction.
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
        // body, which is out of scope per the BRR for LP-1F).
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
    // mutate
    // -----------------------------------------------------------------------

    /// Mutate a row along one of its mutation axes.
    ///
    /// `MutationKind::Confirm` moves the confirmation axis (provenance bits
    /// 18–23, cookbook §2.5) to `UserConfirmed`: read the drawer, recompose
    /// the provenance bitmap with the confirmation field set via
    /// `bit_field::write_field` (every other provenance axis — source_type,
    /// channel, capture_channel, confidence, sensitivity-at-capture,
    /// enrichment_status — is preserved untouched), and persist through
    /// `DrawerStore::mutate_provenance`, which routes the gated column write
    /// and appends one sealed `AuditEvent` atomically. Mirror of Swift
    /// `Estate.mutate` for `.confirm`.
    ///
    /// The state-axis kinds (Reject / Contest / Resolve / Supersede /
    /// Revive) move the row's *state*, not its confirmation, so they belong
    /// on the `mutate_state` automaton path; that path is not yet wired
    /// here, so they return `InvalidContent`, which GLK's `remap` turns into
    /// `NotSupportedByEstate`.
    ///
    /// `now` is taken from the wall clock here — the mirror of Swift
    /// `Estate.mutate`, which defaults its store call's `now` to `Date()`.
    /// The confirmation transition itself is deterministic (a pure function
    /// of the prior bitmap); only the audit row's timestamp is clock-derived.
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

                // Store `now` is epoch-seconds (Swift `Date` → i64 seconds).
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);

                self.store.mutate_provenance(
                    row_id,
                    new_provenance,
                    &changed_by,
                    Some("confirmed via Estate.mutate"),
                    now,
                )
            }
            // State-axis mutations are not yet wired; the "not yet
            // implemented" marker is the sentinel GLK's `remap` keys on to
            // produce NotSupportedByEstate (rather than UnderlyingEstateFailure).
            _ => Err(LocusKitError::InvalidContent(
                "mutate: state-axis kinds not yet implemented (only Confirm)".to_string(),
            )),
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

    /// Register a learned reference. Body pending — implementation lands
    /// in the standing-signals mission.
    pub fn learn(&self, _frame: LearnFrame) -> Result<(), LocusKitError> {
        Err(LocusKitError::InvalidContent(
            "learn not yet implemented".to_string(),
        ))
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
    fn mutate_state_axis_kind_is_not_yet_implemented() {
        // Reject is a state-axis transition; that path is not wired here, so
        // it returns InvalidContent (GLK remaps to NotSupportedByEstate).
        let estate = make_estate();
        let drawer = basic_capture(&estate, "x", "r");
        let err = estate
            .mutate(&drawer.id, MutationKind::Reject, None)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
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
    fn learn_stub_returns_invalid_content() {
        let estate = make_estate();
        let err = estate.learn(LearnFrame::new("source-x")).unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
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
