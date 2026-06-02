//! Bitmap query engine. Ports `BitmapEvaluator.swift`.
//!
//! Compiles a [`crate::filter::RecallFrame`]'s filter chain into the
//! bitmap operator primitives (see [`crate::bitmap_ops`]) and evaluates
//! it against drawer rows. Per spec § 7.9.
//!
//! The evaluator runs a four-stage pipeline against the row set the
//! caller hands it (today that is `DrawerStore::all_drawers`; the
//! Estate verb surface in LP-1F selects the slice):
//!
//! 1. **Default insertion** (§ 7.9.5) — prepend the four implicit
//!    filters (`SensitivityAtMost(Normal)`, `Trustworthy`,
//!    `UserConfirmed`, `CurrentlyBelieve`) for any concern the caller
//!    did not constrain. Tombstone exclusion is always enforced and
//!    is independent of the chain (`state == 9` rejected at the
//!    bitmap tier).
//! 2. **Bitmap-tier evaluation** (§ 7.9.2 / § 7.9.3) — each `Filter`
//!    case compiles to a predicate over `(adjective_bitmap,
//!    operational_bitmap, provenance)` and is applied via the
//!    primitives in `bitmap_ops`. Historical reconstruction
//!    folds the row's audit log via
//!    `AuditLogFold::project_state_at` (cookbook § 5.3) when
//!    `frame.as_of` is `Some`; state is keyed on HLC.
//! 3. **Structured tier** (§ 7.9.4 step 3) — `InRoom`, `InWing`,
//!    `LineageID`, `CreatedAfter`, `CreatedBefore`, `LatticeAnchor`,
//!    `LatticeUnder`, `WikidataConcept`.
//! 4. **Content tier** (§ 7.9.4 step 4) — `ContentMatches` via a
//!    case-insensitive substring fold; `NearVector` surfaces a typed
//!    error until VectorKit ships.
//!
//! Container pruning (§ 7.9.4 step 1) is exposed via
//! [`BitmapEvaluator::container_survives`]. It tests the chain's
//! set-bit filters against a container's OR fingerprint (spec § 11.5),
//! so a container whose fingerprint lacks a required bit is dropped
//! before its rows are fetched. The test is sound (never drops a
//! container holding a match) and conservative (prunes only on
//! set-bit filters such as `HasFeatureFlag`; threshold filters cannot
//! prune through an OR and fall through to the per-row scan).
//!
//! ## Swift-to-Rust shape changes
//!
//! - `async throws -> [Drawer]` → `Result<Vec<Drawer>, LocusKitError>`.
//!   The Rust trait surface is sync; the bitmap evaluator follows.
//! - `Date asOf` → `Option<i64>` epoch-seconds. The audit timestamps
//!   already use epoch seconds across the LocusKit Rust port.
//! - Swift `localizedCaseInsensitiveContains` →
//!   `to_lowercase().contains(...)`. For ASCII corpora (the LP-0
//!   vectors) the two are byte-identical; for non-ASCII content the
//!   Rust port uses unicode lowercase folding rather than the
//!   user-locale-sensitive Foundation collation. The contract — case
//!   insensitivity — is preserved.
//! - `nonzeroBitCount` → routes through `substrate_lib` per anchor
//!   mandate M1 (e.g. `kernel`-layer popcount on Fingerprint256-packed
//!   columns). `bitmap_ops` no longer ships a `hamming_distance`
//!   function.

use crate::adjectives::AdjectiveExportability;
use crate::bitmap_ops::{and_mask, shift_extract, threshold_compare, ThresholdOp};
use crate::container_fingerprint_store::ContainerFingerprint;
use crate::drawer::Drawer;
use crate::drawer_store::DrawerStore;
use crate::error::LocusKitError;
use crate::filter::{Filter, Ordering, RecallFrame, StateCluster};
use crate::provenance::Confirmation;

// MARK: - Layout constants (derived from §§ 5.5–5.6 and Q1_DECISION_PROVENANCE_BITMAP.md)
//
// Mirrors the accessor decoders on `Drawer` exactly. These constants
// are deliberately module-private — the evaluator's translation
// table, not part of the public surface. A schema bump
// (`bitmap_layout_version`) moves them in lock-step with the per-axis
// accessors.

// Adjective bitmap (Drawer::adjective_bitmap, cookbook §2.3).
// F11 cascade (2026-05-27): 4-bit → 6-bit fields per I-15.
const ADJ_STATE_MASK: i64 = 0x3F; // bits 0–5
const ADJ_STATE_SHIFT: i32 = 0;
const ADJ_SENS_MASK: i64 = 0x3F << 6; // 0xFC0,    bits 6–11
const ADJ_SENS_SHIFT: i32 = 6;
const ADJ_EXPORT_MASK: i64 = 0x3F << 12; // 0x3F000,  bits 12–17
const ADJ_EXPORT_SHIFT: i32 = 12;
const ADJ_TRUST_MASK: i64 = 0x3F << 18; // 0xFC0000, bits 18–23
const ADJ_TRUST_SHIFT: i32 = 18;

// State cluster predicate per cookbook §2.3:
//   cluster(state) = (state >> 4) & 0x3
//   0 = Cluster A (active / pending / contested / accepted)
//   1 = Cluster B (superseded / decayed / withdrawn / expired)
//   2 = Cluster C (rejected / tombstoned)
const STATE_CLUSTER_SHIFT: i32 = 4;
const STATE_CLUSTER_MASK: i64 = 0x3;
const STATE_CLUSTER_A: i64 = 0;
const STATE_CLUSTER_B: i64 = 1;
const STATE_CLUSTER_C: i64 = 2;
const STATE_TOMBSTONE: i64 = 33; // State::Tombstoned per cookbook §2.3

// Trust threshold (§ 6.4): `trust < 4` is trustworthy.
// Cookbook §2.3 trust raws 0–6 are contiguous; threshold unchanged.
const TRUST_THRESHOLD: i64 = 4;

// Provenance bitmap (Drawer::provenance, cookbook §2.5 v0.6)
// F13 cascade (2026-05-27): bumped to 6-bit floor per cookbook §2.5 layout.
const PROV_SOURCE_MASK: i64 = 0x3F; // bits 0–5
const PROV_SOURCE_SHIFT: i32 = 0;
const PROV_CHANNEL_MASK: i64 = 0xFC0; // bits 6–11
const PROV_CHANNEL_SHIFT: i32 = 6;
const PROV_CONFIRM_MASK: i64 = 0xFC0000; // bits 18–23
const PROV_CONFIRM_SHIFT: i32 = 18;
const PROV_CONFIDENCE_MASK: i64 = 0x3F000000; // bits 24–29
const PROV_CONFIDENCE_SHIFT: i32 = 24;
// Confirmation threshold for `UserConfirmed` (cookbook §9.4):
// confirmation >= UserConfirmed (raw 1 per cookbook §2.5). Filters out
// Unconfirmed=0 only; passes User/Automated/Peer/Actuator confirmed.
const PROV_USER_CONFIRMED: i64 = 1;

// Operational bitmap (Drawer::operational_bitmap, cookbook §2.4 v0.6)
// F12 cascade (2026-05-27): bumped to 6-bit fields per cookbook §2.4.
const OP_CHANNEL_MASK: i64 = 0x3F; // bits 0–5
const OP_CHANNEL_SHIFT: i32 = 0;
const OP_CONTENT_KIND_MASK: i64 = 0xFC0; // bits 6–11
const OP_CONTENT_KIND_SHIFT: i32 = 6;

// ---------------------------------------------------------------------------
// BitmapEvaluator
// ---------------------------------------------------------------------------

/// Compiles a `RecallFrame.filter_chain` into the bitmap operator
/// primitives and evaluates it against drawer rows. Per spec § 7.9.
///
/// The struct is a unit type — every method is associated. This
/// mirrors the Swift `internal struct BitmapEvaluator` with static
/// methods.
pub struct BitmapEvaluator;

impl BitmapEvaluator {
    // -----------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------

    /// Evaluate `frame` against `drawers`.
    ///
    /// `drawers` is the pre-fetched non-tombstoned row set —
    /// fingerprint pruning (§ 7.9.4 step 1) lives on
    /// [`BitmapEvaluator::container_survives`] and runs in the recall
    /// path ahead of this call. The evaluator handles tombstone
    /// exclusion at the bitmap tier in case the caller's pre-filter
    /// ever loosens.
    ///
    /// `store` is used for `audit_events_for_row` lookups during
    /// historical reconstruction via `AuditLogFold::project_state_at`;
    /// ignored when `frame.as_of` is `None`. The `DrawerStore`
    /// reference is borrowed because the evaluator never retains
    /// state across calls.
    ///
    /// Returns `LocusKitError::InvalidContent` when the chain contains
    /// `NearVector` (vector tier requires VectorKit). Propagates
    /// substrate errors from `DrawerStore::audit_events_for_row`
    /// during historical reconstruction.
    pub fn evaluate(
        frame: &RecallFrame,
        drawers: &[Drawer],
        store: &dyn DrawerStore,
    ) -> Result<Vec<Drawer>, LocusKitError> {
        let chain = Self::insert_defaults(&frame.filter_chain);

        // 1. Per-row bitmap evaluation, with historical reconstruction
        //    when `as_of` is set. Reconstruction touches the
        //    substrate; keeping it inside the loop means rows that
        //    fail an earlier bitmap predicate after reconstruction
        //    still pay only their own audit-row scan, not the entire
        //    corpus's.
        let mut candidates: Vec<Drawer> = Vec::with_capacity(drawers.len());
        for drawer in drawers {
            let projected_for_as_of = if let Some(as_of) = frame.as_of {
                // Fold the row's audit log up to `as_of` (HLC) — one
                // projection returns all three column snapshots.
                // (DECISION_CLOCK_TRIANGLE: state evolves in HLC order;
                // wall-clock is not a fold axis.)
                Self::reconstruct_at(&drawer.id, as_of, store)?
            } else {
                None
            };
            let (adj, op, prov) = if frame.as_of.is_some() {
                match projected_for_as_of {
                    Some(p) => (
                        p.adjective_bitmap,
                        p.operational_bitmap,
                        p.provenance_bitmap,
                    ),
                    // No events at or before as_of — the row had no state
                    // yet; skip it from the historical view.
                    None => continue,
                }
            } else {
                (
                    drawer.adjective_bitmap,
                    drawer.operational_bitmap,
                    drawer.provenance,
                )
            };
            if Self::evaluate_bitmap_tier(&chain, adj, op, prov) {
                candidates.push(drawer.clone());
            }
        }

        // 2. Structured-tier filters (room / wing / time / lattice).
        candidates.retain(|d| Self::evaluate_structured_tier(&chain, d));

        // 3. Content-tier filters (substring; NearVector surfaces a
        //    typed error rather than silently returning zero rows).
        let mut result = Vec::with_capacity(candidates.len());
        for d in candidates {
            if Self::evaluate_content_tier(&chain, &d)? {
                result.push(d);
            }
        }

        // 4. Ordering.
        Ok(Self::sort(result, frame.ordering))
    }

    // -----------------------------------------------------------------
    // Default insertion (§ 7.9.5)
    // -----------------------------------------------------------------

    /// Prepend the four default filters for any concern the caller did
    /// not constrain. Insertion is order-stable but the precise
    /// position is not observable — `evaluate_bitmap_tier` ANDs the
    /// entire chain.
    ///
    /// Each default has a classifier that recognises any `Filter` case
    /// covering that concern; this includes the named-defaults
    /// (`CurrentlyBelieve`, `Trustworthy`, `UserConfirmed`) and the
    /// general cases that constrain the same axis (`State`,
    /// `TrustAtMost`, `Sensitivity`, etc.), so a caller saying "give
    /// me only `Contested` state" suppresses the `CurrentlyBelieve`
    /// default rather than ANDing both.
    fn insert_defaults(chain: &[Filter]) -> Vec<Filter> {
        let mut result: Vec<Filter> = chain.to_vec();
        if !chain.iter().any(Self::is_bitmap_state_filter) {
            result.insert(0, Filter::CurrentlyBelieve);
        }
        if !chain.iter().any(Self::is_bitmap_trust_filter) {
            result.insert(0, Filter::Trustworthy);
        }
        if !chain.iter().any(Self::is_bitmap_prov_filter) {
            result.insert(0, Filter::UserConfirmed);
        }
        if !chain.iter().any(Self::is_bitmap_sensitivity_filter) {
            // Sensitivity default — caller maximum is `Normal` until
            // ARIA_MCP supplies real access claims (§ 9.2). Conditional
            // on absence so an explicit `SensitivityAtMost(Elevated)`
            // is not AND-ed against a baseline `Normal`, which would
            // collapse the explicit ceiling to the implicit one.
            result.insert(
                0,
                Filter::SensitivityAtMost(crate::adjectives::AdjectiveSensitivity::Normal),
            );
        }
        result
    }

    fn is_bitmap_state_filter(f: &Filter) -> bool {
        match f {
            Filter::CurrentlyBelieve
            | Filter::UsedToBelieve
            | Filter::KnewOnceAndErased
            | Filter::State(_)
            | Filter::StateInCluster(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_bitmap_state_filter),
            Filter::Not(inner) => Self::is_bitmap_state_filter(inner),
            _ => false,
        }
    }

    fn is_bitmap_trust_filter(f: &Filter) -> bool {
        match f {
            Filter::Trustworthy
            | Filter::RequiresConfirmation
            | Filter::Trust(_)
            | Filter::TrustAtMost(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_bitmap_trust_filter),
            Filter::Not(inner) => Self::is_bitmap_trust_filter(inner),
            _ => false,
        }
    }

    fn is_bitmap_prov_filter(f: &Filter) -> bool {
        match f {
            Filter::UserConfirmed
            | Filter::ModelConfirmedOnly
            | Filter::Unconfirmed
            | Filter::SourceType(_)
            | Filter::Channel(_)
            | Filter::ConfidenceAtLeast(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_bitmap_prov_filter),
            Filter::Not(inner) => Self::is_bitmap_prov_filter(inner),
            _ => false,
        }
    }

    fn is_bitmap_sensitivity_filter(f: &Filter) -> bool {
        match f {
            Filter::Sensitivity(_) | Filter::SensitivityAtMost(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_bitmap_sensitivity_filter),
            Filter::Not(inner) => Self::is_bitmap_sensitivity_filter(inner),
            _ => false,
        }
    }

    // -----------------------------------------------------------------
    // Container pruning (§ 7.9.4 step 1)
    // -----------------------------------------------------------------

    /// Whether the chain carries any filter that container pruning can
    /// act on. When false, no container can be excluded, so the recall
    /// path scans the corpus directly and pays no per-container fetch
    /// overhead for the common threshold-only chain.
    pub fn chain_has_prunable_filter(chain: &[Filter]) -> bool {
        chain.iter().any(Self::filter_is_prunable)
    }

    fn filter_is_prunable(filter: &Filter) -> bool {
        match filter {
            Filter::HasFeatureFlag(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::filter_is_prunable),
            Filter::Not(f) => Self::filter_is_prunable(f),
            _ => false,
        }
    }

    /// Whether a container might hold a row that satisfies the chain,
    /// given its OR fingerprint. Returns `false` only when the chain
    /// provably cannot be satisfied by any row in the container. Sound,
    /// because the OR covers every active row, so a set bit absent
    /// from the OR is absent from every row.
    pub fn container_survives(chain: &[Filter], fingerprint: ContainerFingerprint) -> bool {
        !chain
            .iter()
            .any(|f| Self::container_provably_excludes(f, fingerprint))
    }

    /// Whether the fingerprint proves no row can satisfy this filter.
    /// Only set-bit filters yield a proof: a required bit absent from
    /// the OR is absent from every row. Threshold and value filters
    /// cannot be decided from an OR, so they never exclude a container.
    fn container_provably_excludes(filter: &Filter, fp: ContainerFingerprint) -> bool {
        match filter {
            Filter::HasFeatureFlag(flag) => {
                // Matches when (op & flag) != 0, so no row can match
                // when the operational OR shares no bit with the flag set.
                (fp.operational & *flag) == 0
            }
            // Conjunction: excluded if any conjunct is unsatisfiable.
            Filter::All(fs) => fs.iter().any(|f| Self::container_provably_excludes(f, fp)),
            // Disjunction: excluded only if every disjunct is unsatisfiable.
            Filter::Any(fs) => {
                !fs.is_empty() && fs.iter().all(|f| Self::container_provably_excludes(f, fp))
            }
            // `Not`, threshold, value, and structured filters give no
            // sound exclusion from an OR fingerprint.
            _ => false,
        }
    }

    // -----------------------------------------------------------------
    // Bitmap-tier evaluation (§ 7.9.2 / § 7.9.3)
    // -----------------------------------------------------------------

    /// Tombstone exclusion is enforced here, independent of the chain:
    /// a row with `state == 9` (`State::Tombstoned`) never surfaces,
    /// even if the caller's chain would otherwise admit it. Per spec
    /// § 7.9.4.
    fn evaluate_bitmap_tier(chain: &[Filter], adj: i64, op: i64, prov: i64) -> bool {
        let state_val = shift_extract(adj, ADJ_STATE_SHIFT, ADJ_STATE_MASK);
        if state_val == STATE_TOMBSTONE {
            return false;
        }
        chain.iter().all(|f| Self::evaluate_one(f, adj, op, prov))
    }

    /// Compile a single Filter case to a bitmap-tier predicate. Cases
    /// outside the bitmap tier (structured / content / NearVector)
    /// pass at this stage; they are evaluated in their respective
    /// tiers.
    fn evaluate_one(filter: &Filter, adj: i64, op: i64, prov: i64) -> bool {
        match filter {
            // State axis (adjective bits 0–5). Cluster predicate per
            // cookbook §2.3: `(state >> 4) & 0x3` → {0=A, 1=B, 2=C}.
            Filter::CurrentlyBelieve => {
                shift_extract(adj, STATE_CLUSTER_SHIFT, STATE_CLUSTER_MASK) == STATE_CLUSTER_A
            }
            Filter::UsedToBelieve => {
                shift_extract(adj, STATE_CLUSTER_SHIFT, STATE_CLUSTER_MASK) == STATE_CLUSTER_B
            }
            Filter::KnewOnceAndErased => {
                shift_extract(adj, STATE_CLUSTER_SHIFT, STATE_CLUSTER_MASK) == STATE_CLUSTER_C
            }
            Filter::State(s) => and_mask(adj, ADJ_STATE_MASK, s.raw_value()),
            Filter::StateInCluster(c) => {
                let v = shift_extract(adj, STATE_CLUSTER_SHIFT, STATE_CLUSTER_MASK);
                match c {
                    StateCluster::KnowNow => v == STATE_CLUSTER_A,
                    StateCluster::KnewPast => v == STATE_CLUSTER_B,
                    StateCluster::Terminal => v == STATE_CLUSTER_C,
                }
            }

            // Trust axis (adjective bits 12–15)
            Filter::Trustworthy => threshold_compare(
                adj,
                ADJ_TRUST_MASK,
                ADJ_TRUST_SHIFT,
                ThresholdOp::LessThan,
                TRUST_THRESHOLD,
            ),
            Filter::RequiresConfirmation => threshold_compare(
                adj,
                ADJ_TRUST_MASK,
                ADJ_TRUST_SHIFT,
                ThresholdOp::GreaterThanOrEqual,
                TRUST_THRESHOLD,
            ),
            Filter::Trust(t) => and_mask(adj, ADJ_TRUST_MASK, t.raw_value() << ADJ_TRUST_SHIFT),
            Filter::TrustAtMost(t) => threshold_compare(
                adj,
                ADJ_TRUST_MASK,
                ADJ_TRUST_SHIFT,
                ThresholdOp::LessThanOrEqual,
                t.raw_value(),
            ),

            // Adjective sensitivity axis (adjective bits 4–7). Distinct
            // from the provenance sensitivity axis (bits 16–17 of
            // `provenance`); Filter cases route to the adjective axis
            // per spec § 7.9.2 because that is the access-gate-relevant
            // tier.
            Filter::Sensitivity(s) => and_mask(adj, ADJ_SENS_MASK, s.raw_value() << ADJ_SENS_SHIFT),
            Filter::SensitivityAtMost(s) => threshold_compare(
                adj,
                ADJ_SENS_MASK,
                ADJ_SENS_SHIFT,
                ThresholdOp::LessThanOrEqual,
                s.raw_value(),
            ),

            // Exportability axis (adjective bits 8–11)
            Filter::Exportable => and_mask(
                adj,
                ADJ_EXPORT_MASK,
                AdjectiveExportability::Public.raw_value() << ADJ_EXPORT_SHIFT,
            ),
            Filter::Contained => and_mask(
                adj,
                ADJ_EXPORT_MASK,
                AdjectiveExportability::Private.raw_value() << ADJ_EXPORT_SHIFT,
            ),

            // Provenance — confirmation axis (bits 4–6)
            Filter::UserConfirmed => threshold_compare(
                prov,
                PROV_CONFIRM_MASK,
                PROV_CONFIRM_SHIFT,
                ThresholdOp::GreaterThanOrEqual,
                PROV_USER_CONFIRMED,
            ),
            Filter::ModelConfirmedOnly => and_mask(
                prov,
                PROV_CONFIRM_MASK,
                Confirmation::AutomatedConfirmed.raw_value() << PROV_CONFIRM_SHIFT,
            ),
            Filter::Unconfirmed => and_mask(prov, PROV_CONFIRM_MASK, 0),

            // Provenance — other axes
            Filter::SourceType(s) => {
                and_mask(prov, PROV_SOURCE_MASK, s.raw_value() << PROV_SOURCE_SHIFT)
            }
            Filter::ConfidenceAtLeast(c) => threshold_compare(
                prov,
                PROV_CONFIDENCE_MASK,
                PROV_CONFIDENCE_SHIFT,
                ThresholdOp::GreaterThanOrEqual,
                c.raw_value(),
            ),
            Filter::Channel(ch) => and_mask(
                prov,
                PROV_CHANNEL_MASK,
                ch.raw_value() << PROV_CHANNEL_SHIFT,
            ),

            // Operational axes
            Filter::CaptureChannel(c) => {
                and_mask(op, OP_CHANNEL_MASK, c.raw_value() << OP_CHANNEL_SHIFT)
            }
            Filter::ContentKind(k) => and_mask(
                op,
                OP_CONTENT_KIND_MASK,
                k.raw_value() << OP_CONTENT_KIND_SHIFT,
            ),
            Filter::HasFeatureFlag(flag) => {
                // Feature flags are already bit-positioned; a non-zero
                // intersection means at least one requested flag is set.
                // Matches the Swift `(op & f.rawValue) != 0` semantics.
                (op & *flag) != 0
            }

            // Composition — bitmap-tier portion. Structured / content
            // children pass at this tier and are re-evaluated in the
            // structured / content stages where they belong.
            Filter::All(fs) => fs.iter().all(|f| Self::evaluate_one(f, adj, op, prov)),
            Filter::Any(fs) => fs.iter().any(|f| Self::evaluate_one(f, adj, op, prov)),
            Filter::Not(f) => !Self::evaluate_one(f, adj, op, prov),

            // Non-bitmap cases — pass at this tier, evaluated in their
            // own tier below. Includes structured (room / wing / time
            // / lattice) and content (ContentMatches / NearVector).
            _ => true,
        }
    }

    // -----------------------------------------------------------------
    // Structured-tier evaluation (§ 7.9.4 step 3)
    // -----------------------------------------------------------------

    fn evaluate_structured_tier(chain: &[Filter], drawer: &Drawer) -> bool {
        chain.iter().all(|f| Self::evaluate_structured(f, drawer))
    }

    /// Classifier — does `f` (or any of its children) name a
    /// structured-tier concern? Used by the composition cases below so
    /// a `Not(<bitmap filter>)` does not flip to `false` here at the
    /// structured tier. Composition cases that contain no structured
    /// child pass at this tier — the bitmap tier and content tier
    /// handle the children they care about.
    fn is_structural_filter(f: &Filter) -> bool {
        match f {
            Filter::InRoom(_)
            | Filter::InWing(_)
            | Filter::LineageID(_)
            | Filter::CreatedAfter(_)
            | Filter::CreatedBefore(_)
            | Filter::LatticeAnchor(_)
            | Filter::LatticeUnder(_)
            | Filter::WikidataConcept(_) => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_structural_filter),
            Filter::Not(inner) => Self::is_structural_filter(inner),
            _ => false,
        }
    }

    fn evaluate_structured(filter: &Filter, drawer: &Drawer) -> bool {
        match filter {
            Filter::InRoom(r) => drawer.room == *r,
            Filter::InWing(w) => drawer.wing == *w,
            Filter::LineageID(l) => drawer.lineage_id == *l,
            Filter::CreatedAfter(d) => drawer.filed_at > *d,
            Filter::CreatedBefore(d) => drawer.filed_at < *d,
            Filter::LatticeAnchor(a) => drawer.udc_code == a.udc_code,
            Filter::LatticeUnder(p) => drawer.udc_code.starts_with(p),
            Filter::WikidataConcept(q) => {
                // Match the primary Q-ID or any secondary in the
                // comma-separated `wikidata_qids_secondary` field. The
                // secondary field is a flat comma-joined string with
                // no internal whitespace, so wrapping it with leading
                // and trailing commas lets a substring match against
                // `,Q-padded,` avoid a `Q1` false-match inside `Q11`.
                if drawer.wikidata_qid.as_deref() == Some(q.as_str()) {
                    return true;
                }
                match &drawer.wikidata_qids_secondary {
                    Some(secondary) => {
                        let padded = format!(",{},", secondary);
                        let needle = format!(",{},", q);
                        padded.contains(&needle)
                    }
                    None => false,
                }
            }
            // Composition cases evaluate ONLY their structurally-
            // relevant children. A child like `Trustworthy` is a
            // bitmap-tier concern; at the structured tier it is a
            // no-op rather than a pass that `Not` would flip to a
            // false exclusion.
            Filter::All(fs) => fs
                .iter()
                .filter(|f| Self::is_structural_filter(f))
                .all(|f| Self::evaluate_structured(f, drawer)),
            Filter::Any(fs) => {
                let structural: Vec<&Filter> = fs
                    .iter()
                    .filter(|f| Self::is_structural_filter(f))
                    .collect();
                if structural.is_empty() {
                    return true;
                }
                structural
                    .iter()
                    .any(|f| Self::evaluate_structured(f, drawer))
            }
            Filter::Not(f) => {
                if Self::is_structural_filter(f) {
                    !Self::evaluate_structured(f, drawer)
                } else {
                    true
                }
            }
            // Bitmap and content cases pass at this tier.
            _ => true,
        }
    }

    // -----------------------------------------------------------------
    // Content-tier evaluation (§ 7.9.4 step 4)
    // -----------------------------------------------------------------

    fn evaluate_content_tier(chain: &[Filter], drawer: &Drawer) -> Result<bool, LocusKitError> {
        for filter in chain {
            if !Self::evaluate_content(filter, drawer)? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// Classifier — does `f` (or any of its children) name a
    /// content-tier concern? Same role as `is_structural_filter` at
    /// the content tier; keeps a `Not(<bitmap filter>)` from flipping
    /// to `false` here.
    fn is_content_filter(f: &Filter) -> bool {
        match f {
            Filter::ContentMatches(_) | Filter::NearVector { .. } => true,
            Filter::All(fs) | Filter::Any(fs) => fs.iter().any(Self::is_content_filter),
            Filter::Not(inner) => Self::is_content_filter(inner),
            _ => false,
        }
    }

    fn evaluate_content(filter: &Filter, drawer: &Drawer) -> Result<bool, LocusKitError> {
        match filter {
            Filter::ContentMatches(s) => {
                // Swift uses `localizedCaseInsensitiveContains` which
                // honours the user's locale collation; the Rust port
                // uses the unicode lowercase fold. For ASCII corpora
                // (the LP-0 vectors) the two are byte-identical; for
                // non-ASCII content the shape change is documented at
                // the function-doc level — case insensitivity is
                // preserved.
                let haystack = drawer.content.to_lowercase();
                let needle = s.to_lowercase();
                Ok(haystack.contains(&needle))
            }
            Filter::NearVector { .. } => {
                // The vector index ships with VectorKit. Throwing here
                // surfaces a typed error to the caller rather than
                // silently returning zero rows, so a chain that
                // requires `NearVector` fails loud.
                Err(LocusKitError::InvalidContent(
                    "nearVector requires VectorKit — not yet implemented".to_string(),
                ))
            }
            Filter::All(fs) => {
                for f in fs.iter().filter(|f| Self::is_content_filter(f)) {
                    if !Self::evaluate_content(f, drawer)? {
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            Filter::Any(fs) => {
                let content_children: Vec<&Filter> =
                    fs.iter().filter(|f| Self::is_content_filter(f)).collect();
                if content_children.is_empty() {
                    return Ok(true);
                }
                for f in content_children {
                    if Self::evaluate_content(f, drawer)? {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            Filter::Not(f) => {
                if Self::is_content_filter(f) {
                    Ok(!Self::evaluate_content(f, drawer)?)
                } else {
                    Ok(true)
                }
            }
            // Bitmap and structured cases pass at this tier.
            _ => Ok(true),
        }
    }

    // -----------------------------------------------------------------
    // Historical reconstruction (cookbook § 5.3)
    // -----------------------------------------------------------------

    /// Reconstruct a row's full bitmap state as of `as_of` (HLC) by
    /// folding the row's audit log via
    /// `AuditLogFold::project_state_at`. Returns `None` when the row
    /// has no events at or before `as_of` (it did not exist yet at
    /// that point — the genesis capture event is the earliest fact
    /// in the log).
    fn reconstruct_at(
        row_id: &str,
        as_of: substrate_types::hlc::HLC,
        store: &dyn DrawerStore,
    ) -> Result<Option<substrate_ml::audit_log_fold::ProjectedRowState>, LocusKitError> {
        let uuid = crate::drawer_store_inmemory::require_uuid(row_id, "rowID")?;
        let events = store.audit_events_for_row(row_id)?;
        Ok(
            substrate_ml::audit_log_fold::AuditLogFold::project_state_at(
                substrate_lib::verbs::RowId(uuid.as_u128()),
                substrate_lib::verbs::NounType::Drawer,
                &events,
                as_of,
            ),
        )
    }

    // -----------------------------------------------------------------
    // Ordering
    // -----------------------------------------------------------------

    fn sort(mut drawers: Vec<Drawer>, ordering: Ordering) -> Vec<Drawer> {
        match ordering {
            Ordering::ByCaptureTimeDesc => {
                drawers.sort_by(|a, b| b.filed_at.cmp(&a.filed_at));
            }
            Ordering::ByCaptureTimeAsc => {
                drawers.sort_by(|a, b| a.filed_at.cmp(&b.filed_at));
            }
            Ordering::ByRoomAsc => {
                drawers.sort_by(|a, b| a.room.cmp(&b.room));
            }
            Ordering::ByRelevanceDesc => {
                // Relevance scoring requires the vector index from
                // VectorKit. Returning the input order is the
                // documented stub behaviour until that index ships.
            }
        }
        drawers
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};
    use crate::drawer_operational::DrawerFeatureFlags;
    use crate::drawer_store_inmemory::InMemoryDrawerStore;
    use crate::provenance::{Channel, Confidence, Confirmation, SourceType};
    use persistence_kit::inmemory::InMemoryStorage;
    use std::sync::Arc;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn make_store() -> Arc<InMemoryDrawerStore> {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap())
    }

    fn base_drawer(id: &str) -> Drawer {
        let mut d = Drawer::new(id, "content", "w", "kitchen", "alice", NOW, "test-v1");
        // Default the four-axis defaults so the evaluator's
        // implicit-default filters do not eliminate the sample row:
        //
        // - state = Active (raw 0, in know-now cluster < 3) ✓
        // - sensitivity ≤ Normal (raw 0) ✓
        // - trust = Verbatim (raw 0, < 4) ✓
        // - confirmation = UserConfirmed (raw 2, >= 2) — must be set
        //   explicitly because the default `Unconfirmed = 0` would
        //   fail the implicit `UserConfirmed` filter.
        d.provenance = Confirmation::UserConfirmed.raw_value() << 18;
        d
    }

    fn make_frame(filters: Vec<Filter>) -> RecallFrame {
        RecallFrame::new(filters)
    }

    // -----------------------------------------------------------------
    // Default insertion
    // -----------------------------------------------------------------

    #[test]
    fn defaults_admit_a_sane_baseline_drawer() {
        let store = make_store();
        let d = base_drawer("d1");
        let frame = make_frame(vec![]);
        let result = BitmapEvaluator::evaluate(&frame, &[d.clone()], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn currently_believe_default_excludes_superseded() {
        let store = make_store();
        let mut d = base_drawer("d1");
        d.adjective_bitmap = State::Superseded.raw_value();
        let frame = make_frame(vec![]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn explicit_state_filter_suppresses_currently_believe_default() {
        let store = make_store();
        let mut d = base_drawer("d1");
        d.adjective_bitmap = State::Contested.raw_value();
        // Caller explicitly asks for Contested — the
        // CurrentlyBelieve default must NOT also be ANDed.
        let frame = make_frame(vec![Filter::State(State::Contested)]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn sensitivity_default_is_normal() {
        let store = make_store();
        // Row at Elevated sensitivity — defaults exclude it.
        let mut d = base_drawer("d1");
        d.adjective_bitmap = AdjectiveSensitivity::Elevated.raw_value() << 6;
        let frame = make_frame(vec![]);
        let result = BitmapEvaluator::evaluate(&frame, &[d.clone()], store.as_ref()).unwrap();
        assert!(result.is_empty());
        // Caller widens the ceiling — Elevated row surfaces.
        let frame = make_frame(vec![Filter::SensitivityAtMost(
            AdjectiveSensitivity::Elevated,
        )]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    // -----------------------------------------------------------------
    // Tombstone exclusion
    // -----------------------------------------------------------------

    #[test]
    fn tombstoned_state_is_excluded_independent_of_chain() {
        let store = make_store();
        let mut d = base_drawer("d1");
        d.adjective_bitmap = State::Tombstoned.raw_value();
        // Even if the caller asks for the terminal cluster, the
        // tombstone is dropped at the bitmap tier per § 7.9.4.
        let frame = make_frame(vec![Filter::StateInCluster(StateCluster::Terminal)]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert!(result.is_empty());
    }

    // -----------------------------------------------------------------
    // State clusters
    // -----------------------------------------------------------------

    #[test]
    fn state_in_cluster_know_now() {
        let store = make_store();
        let mut active = base_drawer("a");
        active.adjective_bitmap = State::Active.raw_value();
        let mut past = base_drawer("p");
        past.adjective_bitmap = State::Withdrawn.raw_value();
        let frame = make_frame(vec![Filter::StateInCluster(StateCluster::KnowNow)]);
        let result = BitmapEvaluator::evaluate(&frame, &[active, past], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "a");
    }

    #[test]
    fn state_in_cluster_knew_past() {
        let store = make_store();
        let mut active = base_drawer("a");
        active.adjective_bitmap = State::Active.raw_value();
        let mut withdrawn = base_drawer("w");
        withdrawn.adjective_bitmap = State::Withdrawn.raw_value();
        let frame = make_frame(vec![Filter::StateInCluster(StateCluster::KnewPast)]);
        let result =
            BitmapEvaluator::evaluate(&frame, &[active, withdrawn], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "w");
    }

    // -----------------------------------------------------------------
    // Trust axis
    // -----------------------------------------------------------------

    #[test]
    fn trustworthy_default_excludes_high_trust_rows() {
        let store = make_store();
        let mut low = base_drawer("low");
        // Trust::Observed = 1 (< 4) → trustworthy.
        low.adjective_bitmap = Trust::Observed.raw_value() << 18;
        let mut hi = base_drawer("hi");
        // Trust::Derived = 4 → not trustworthy, default excludes.
        hi.adjective_bitmap = Trust::Derived.raw_value() << 18;
        let frame = make_frame(vec![]);
        let result = BitmapEvaluator::evaluate(&frame, &[low, hi], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "low");
    }

    #[test]
    fn requires_confirmation_filter() {
        let store = make_store();
        let mut hi = base_drawer("hi");
        hi.adjective_bitmap = Trust::Derived.raw_value() << 18;
        // Caller widens — Derived is now allowed.
        let frame = make_frame(vec![Filter::RequiresConfirmation]);
        let result = BitmapEvaluator::evaluate(&frame, &[hi], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    // -----------------------------------------------------------------
    // Provenance axes
    // -----------------------------------------------------------------

    #[test]
    fn user_confirmed_default_excludes_unconfirmed() {
        let store = make_store();
        let mut unconfirmed = base_drawer("u");
        // Override the helper's default — leave confirmation at 0.
        unconfirmed.provenance = 0;
        let frame = make_frame(vec![]);
        let result = BitmapEvaluator::evaluate(&frame, &[unconfirmed], store.as_ref()).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn model_confirmed_only_admits_model_excludes_user() {
        let store = make_store();
        let mut model = base_drawer("m");
        model.provenance = Confirmation::AutomatedConfirmed.raw_value() << 18;
        let user = base_drawer("u"); // base_drawer already sets UserConfirmed
        let frame = make_frame(vec![Filter::ModelConfirmedOnly]);
        let result = BitmapEvaluator::evaluate(&frame, &[model, user], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "m");
    }

    #[test]
    fn source_type_filter() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.provenance |= SourceType::Canonical.raw_value(); // F13: was SourceType::Instruction in v0.35
        let frame = make_frame(vec![Filter::SourceType(SourceType::Canonical)]); // F13
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn channel_filter_uses_canonical_six_bit_field() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.provenance |= Channel::McpAgent.raw_value() << 6; // F13: cookbook §2.5 bits 6-11
                                                            // Carry-over from BitmapEvaluator.swift:86: the mask/shift is
                                                            // 0xFC00 / 10, not the older 0x7000 / 12. This test asserts
                                                            // the Rust port matches the canonical encoding.
        let frame = make_frame(vec![Filter::Channel(Channel::McpAgent)]); // F13
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn confidence_at_least_filter() {
        let store = make_store();
        let mut hi = base_drawer("hi");
        hi.provenance |= Confidence::High.raw_value() << 24; // cookbook §2.5 bits 24-29
        let mut low = base_drawer("low");
        low.provenance |= Confidence::Low.raw_value() << 24;
        let frame = make_frame(vec![Filter::ConfidenceAtLeast(Confidence::Medium)]);
        let result = BitmapEvaluator::evaluate(&frame, &[hi, low], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "hi");
    }

    // -----------------------------------------------------------------
    // Operational axes
    // -----------------------------------------------------------------

    #[test]
    fn has_feature_flag_uses_or_semantics() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.operational_bitmap = DrawerFeatureFlags::IS_PINNED;
        let frame = make_frame(vec![Filter::HasFeatureFlag(
            DrawerFeatureFlags::IS_PINNED | DrawerFeatureFlags::HAS_VOICE,
        )]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        // At least one bit set → matches.
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn exportable_and_contained_axes() {
        let store = make_store();
        let mut pub_ = base_drawer("pub");
        pub_.adjective_bitmap = AdjectiveExportability::Public.raw_value() << 12;
        let frame = make_frame(vec![Filter::Exportable]);
        let result = BitmapEvaluator::evaluate(&frame, &[pub_.clone()], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        let frame = make_frame(vec![Filter::Contained]);
        let result = BitmapEvaluator::evaluate(&frame, &[pub_], store.as_ref()).unwrap();
        assert!(result.is_empty());
    }

    // -----------------------------------------------------------------
    // Structured tier
    // -----------------------------------------------------------------

    #[test]
    fn in_room_and_in_wing_filters() {
        let store = make_store();
        let mut k = base_drawer("k");
        k.room = "kitchen".to_string();
        let mut s = base_drawer("s");
        s.room = "study".to_string();
        let frame = make_frame(vec![Filter::InRoom("kitchen".to_string())]);
        let result =
            BitmapEvaluator::evaluate(&frame, &[k.clone(), s.clone()], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "k");
    }

    #[test]
    fn lineage_id_filter() {
        let store = make_store();
        let target = Uuid::new_v4();
        let mut a = base_drawer("a");
        a.lineage_id = target;
        let b = base_drawer("b");
        let frame = make_frame(vec![Filter::LineageID(target)]);
        let result = BitmapEvaluator::evaluate(&frame, &[a, b], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "a");
    }

    #[test]
    fn created_after_and_before() {
        let store = make_store();
        let mut early = base_drawer("early");
        early.filed_at = NOW + 1;
        let mut late = base_drawer("late");
        late.filed_at = NOW + 100;
        let frame = make_frame(vec![Filter::CreatedAfter(NOW + 50)]);
        let result =
            BitmapEvaluator::evaluate(&frame, &[early.clone(), late.clone()], store.as_ref())
                .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "late");
        let frame = make_frame(vec![Filter::CreatedBefore(NOW + 50)]);
        let result = BitmapEvaluator::evaluate(&frame, &[early, late], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "early");
    }

    #[test]
    fn lattice_under_prefix_match() {
        let store = make_store();
        let mut child = base_drawer("c");
        child.udc_code = "547.12".to_string();
        let mut sibling = base_drawer("s");
        sibling.udc_code = "612.0".to_string();
        let frame = make_frame(vec![Filter::LatticeUnder("547".to_string())]);
        let result = BitmapEvaluator::evaluate(&frame, &[child, sibling], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "c");
    }

    #[test]
    fn wikidata_concept_matches_primary_and_secondary_no_false_match() {
        let store = make_store();
        let mut primary = base_drawer("p");
        primary.wikidata_qid = Some("Q11351".to_string());
        let mut secondary = base_drawer("s");
        secondary.wikidata_qids_secondary = Some("Q11351,Q42".to_string());
        let mut q1_only = base_drawer("q1");
        // Caller must NOT see `Q1` for a query asking `Q11` — the
        // padded-comma test prevents that false match.
        q1_only.wikidata_qid = Some("Q1".to_string());
        let frame = make_frame(vec![Filter::WikidataConcept("Q11351".to_string())]);
        let result =
            BitmapEvaluator::evaluate(&frame, &[primary, secondary, q1_only], store.as_ref())
                .unwrap();
        assert_eq!(result.len(), 2);
    }

    // -----------------------------------------------------------------
    // Content tier
    // -----------------------------------------------------------------

    #[test]
    fn content_matches_is_case_insensitive() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.content = "Hello World".to_string();
        let frame = make_frame(vec![Filter::ContentMatches("WORLD".to_string())]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn near_vector_surfaces_invalid_content_error() {
        let store = make_store();
        let d = base_drawer("d");
        let frame = make_frame(vec![Filter::NearVector {
            vector: vec![0.0, 1.0],
            count: 5,
        }]);
        let err = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => assert!(msg.contains("VectorKit")),
            other => panic!("expected InvalidContent, got {:?}", other),
        }
    }

    // -----------------------------------------------------------------
    // Composition
    // -----------------------------------------------------------------

    #[test]
    fn all_combinator_requires_every_child() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.room = "kitchen".to_string();
        d.content = "pasta recipe".to_string();
        let frame = make_frame(vec![Filter::All(vec![
            Filter::InRoom("kitchen".to_string()),
            Filter::ContentMatches("pasta".to_string()),
        ])]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn any_combinator_short_circuits_on_first_match() {
        let store = make_store();
        let mut d = base_drawer("d");
        d.room = "study".to_string();
        let frame = make_frame(vec![Filter::Any(vec![
            Filter::InRoom("kitchen".to_string()),
            Filter::InRoom("study".to_string()),
        ])]);
        let result = BitmapEvaluator::evaluate(&frame, &[d], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn not_combinator_inverts_bitmap_child() {
        // `Not` over a bitmap-tier filter inverts at the bitmap tier
        // (matches Swift `BitmapEvaluator.swift`). Two rows: one
        // trustworthy (passes the implicit default), one not (fails
        // it). The chain `Not(Trustworthy)` keeps only the row with
        // high trust — after the evaluator suppresses the implicit
        // `Trustworthy` default (the chain already names a trust
        // filter).
        let store = make_store();
        let mut low = base_drawer("low");
        // Trust::Observed = 1 → trustworthy.
        low.adjective_bitmap = Trust::Observed.raw_value() << 18;
        let mut hi = base_drawer("hi");
        // Trust::Derived = 4 → not trustworthy.
        hi.adjective_bitmap = Trust::Derived.raw_value() << 18;
        let frame = make_frame(vec![Filter::Not(Box::new(Filter::Trustworthy))]);
        let result = BitmapEvaluator::evaluate(&frame, &[low, hi], store.as_ref()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "hi");
    }

    // -----------------------------------------------------------------
    // Container pruning
    // -----------------------------------------------------------------

    #[test]
    fn chain_has_prunable_filter_recognises_has_feature_flag() {
        assert!(BitmapEvaluator::chain_has_prunable_filter(&[
            Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE),
        ]));
        // Threshold filters are NOT prunable.
        assert!(!BitmapEvaluator::chain_has_prunable_filter(&[
            Filter::Trustworthy
        ]));
    }

    #[test]
    fn container_survives_drops_only_provably_excluded() {
        let chain = vec![Filter::HasFeatureFlag(DrawerFeatureFlags::IS_PINNED)];
        let empty_fp = ContainerFingerprint {
            adjective: 0,
            operational: 0,
            provenance: 0,
        };
        // Empty OR cannot satisfy a set-bit filter — drop.
        assert!(!BitmapEvaluator::container_survives(&chain, empty_fp));
        // Non-empty OR with the bit set — keep.
        let fp = ContainerFingerprint {
            adjective: 0,
            operational: DrawerFeatureFlags::IS_PINNED,
            provenance: 0,
        };
        assert!(BitmapEvaluator::container_survives(&chain, fp));
    }

    #[test]
    fn container_survives_passes_threshold_filters_through() {
        // Threshold filters cannot be decided from an OR — they must
        // never exclude a container.
        let chain = vec![Filter::Trustworthy];
        let empty_fp = ContainerFingerprint {
            adjective: 0,
            operational: 0,
            provenance: 0,
        };
        assert!(BitmapEvaluator::container_survives(&chain, empty_fp));
    }

    // -----------------------------------------------------------------
    // Ordering
    // -----------------------------------------------------------------

    #[test]
    fn order_by_capture_time_desc() {
        let store = make_store();
        let mut early = base_drawer("early");
        early.filed_at = NOW + 1;
        let mut late = base_drawer("late");
        late.filed_at = NOW + 100;
        let frame = RecallFrame {
            filter_chain: vec![],
            hydration_level: crate::filter::HydrationLevel::Structured,
            limit: None,
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
        };
        let result =
            BitmapEvaluator::evaluate(&frame, &[early.clone(), late.clone()], store.as_ref())
                .unwrap();
        assert_eq!(result[0].id, "late");
        assert_eq!(result[1].id, "early");
    }

    #[test]
    fn order_by_capture_time_asc() {
        let store = make_store();
        let mut early = base_drawer("early");
        early.filed_at = NOW + 1;
        let mut late = base_drawer("late");
        late.filed_at = NOW + 100;
        let frame = RecallFrame {
            filter_chain: vec![],
            hydration_level: crate::filter::HydrationLevel::Structured,
            limit: None,
            ordering: Ordering::ByCaptureTimeAsc,
            as_of: None,
        };
        let result = BitmapEvaluator::evaluate(&frame, &[late, early], store.as_ref()).unwrap();
        assert_eq!(result[0].id, "early");
        assert_eq!(result[1].id, "late");
    }

    #[test]
    fn order_by_room_asc() {
        let store = make_store();
        let mut k = base_drawer("k");
        k.room = "kitchen".to_string();
        let mut s = base_drawer("s");
        s.room = "den".to_string();
        let frame = RecallFrame {
            filter_chain: vec![],
            hydration_level: crate::filter::HydrationLevel::Structured,
            limit: None,
            ordering: Ordering::ByRoomAsc,
            as_of: None,
        };
        let result = BitmapEvaluator::evaluate(&frame, &[k, s], store.as_ref()).unwrap();
        assert_eq!(result[0].room, "den");
        assert_eq!(result[1].room, "kitchen");
    }

    // -----------------------------------------------------------------
    // Provenance channel mask carry-over — explicit Smythe Advisory 2 guard
    // -----------------------------------------------------------------

    #[test]
    fn provenance_channel_constants_match_canonical_six_bit_field() {
        // Direct assertion: the constants used by `Filter::Channel`
        // are the canonical six-bit field. The Swift port at
        // BitmapEvaluator.swift:86 records the same correction.
        // Cookbook §2.5 v0.6: channel at bits 6-11.
        assert_eq!(PROV_CHANNEL_MASK, 0xFC0);
        assert_eq!(PROV_CHANNEL_SHIFT, 6);
    }
}
