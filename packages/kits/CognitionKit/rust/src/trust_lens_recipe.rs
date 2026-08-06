//! TrustLens — provenance-weighted grounding (Lens 6, Grounding & Trust).
//! Recall a set of drawers, rank them by how authoritative their provenance
//! is (source-type trust: Canonical/User above Derived/etc., confidence as
//! tiebreak), and synthesize the trust-ordered set so the most trustworthy
//! memories ground the context first. The estate reasons about which of its
//! own memories to lean on.
//!
//! Paired with the Swift version (`Sources/CognitionKit/TrustLens.swift`).
//! PURE CognitionKit sequencing: recall via GLK + the drawer provenance
//! accessors (existing) + NeuronKit `synthesize` (existing). Zero new
//! substrate, zero new NeuronKit surface. Read-only.
//!
//! Trust signal: `source_type` is used (it is settable at capture and varies),
//! not `confirmation`. The confirm/mutate verb is now live in LocusKit/GLK
//! Rust, but this recipe intentionally ignores confirmation today — ranking
//! uses only `source_type` and confidence. When confirmation is wired here,
//! a user-confirmed boost will fold into `trust_rank` the same way.
//!
//! v1.1.0 extension: if a `MatrixCalibrationCurve` is supplied, the ranked
//! confidences are calibrated via `neuron_kit::calibrate` and attached as
//! `calibrated_confidences`. Passing `None` restores v1.0.0 behaviour.
//! `Confidence.raw_value()` / 56 maps the 5-point ordinal to [0, 1] (matches
//! Swift `Float($0.confidence.rawValue) / 56.0`; max raw = 56).

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::{EstateCoordinator, MatrixCalibrationCurve};
use locus_kit::filter::RecallFrame;
use locus_kit::provenance::SourceType;
use neuron_kit::{calibrate, synthesize, CalibratedValue, ContextDocument, DrawerRow, DrawerRowMeta, RecallPage};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

/// Provenance-weighted grounding output: the synthesized context, the drawer
/// ids in trust order (most authoritative first), and how many are high-trust.
#[derive(Debug, Clone, PartialEq)]
pub struct TrustGroundedOutput {
    pub context: ContextDocument,
    /// Recalled drawer ids, most-trusted first.
    pub ranked_ids: Vec<String>,
    /// Count of high-trust rows (Canonical or User source type).
    pub high_trust_count: usize,
    /// v1.1.0: calibrated confidences in ranked order, one per recalled
    /// drawer. Present only when a `MatrixCalibrationCurve` was supplied.
    pub calibrated_confidences: Option<Vec<CalibratedValue>>,
}

/// Authority score for a source type (higher = more trustworthy). Canonical
/// and User outrank derived/inferred provenance — "canonical + user above
/// derived/proposed" from the lens brainstorm. A v1 ordering; the precise
/// weights are a deliberate, documented choice, not a substrate constant.
fn trust_rank(st: SourceType) -> i32 {
    match st {
        SourceType::Canonical => 5,
        SourceType::User => 4,
        SourceType::Imported => 3,
        SourceType::Observed => 2,
        SourceType::Derived => 1,
        _ => 0,
    }
}

/// `true` for the high-trust tier (Canonical or User).
fn is_high_trust(st: SourceType) -> bool {
    trust_rank(st) >= 4
}

/// Recall via `frame`, rank by provenance trust, and synthesize the
/// trust-ordered set. Read-only; a recall failure propagates as
/// `RecipeRunError::Substrate`.
///
/// `calibration_curve`: pass `Some(&curve)` to attach calibrated confidences
/// to the output (v1.1.0). Pass `None` for v1.0.0 behaviour.
pub fn run_trust_grounded_synthesis(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    mut frame: RecallFrame,
    calibration_curve: Option<&MatrixCalibrationCurve>,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<TrustGroundedOutput, RecipeRunError> {
    // B-5: capability gate before any substrate touch.
    verify_capabilities(&[NeuronKitCapability::Synthesize], &shipped_capabilities())?;

    // Force .full hydration: synthesize operates on drawer content bodies.
    // Per LocusKit spec § 7.3, .structured / .bitmap_only recall returns
    // content == "" (no blob reads), which would produce an empty-pattern
    // context document. The override preserves all other frame fields and
    // cannot be left to the caller — mirrors contradiction_recipe.rs:47.
    // Same failure class as the H-BROKEN content-stripping family.
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;

    let mut drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // Trust order: source-type authority desc, confidence desc, id asc
    // (deterministic).
    drawers.sort_by(|a, b| {
        trust_rank(b.source_type())
            .cmp(&trust_rank(a.source_type()))
            .then(b.confidence().raw_value().cmp(&a.confidence().raw_value()))
            .then(a.id.cmp(&b.id))
    });

    let high_trust_count = drawers
        .iter()
        .filter(|d| is_high_trust(d.source_type()))
        .count();
    let ranked_ids: Vec<String> = drawers.iter().map(|d| d.id.clone()).collect();

    let rows: Vec<DrawerRow> = drawers
        .iter()
        .map(|d| DrawerRow {
            id: d.id.clone(),
            content: d.content.clone(),
        })
        .collect();
    let meta: Vec<DrawerRowMeta> = drawers
        .iter()
        .map(|d| {
            let (wing, room) = node_names
                .get(&d.parent_node_id)
                .cloned()
                .unwrap_or_default();
            DrawerRowMeta {
                parent_node_id: d.parent_node_id.clone(),
                wing,
                room,
                is_currently_believed: true,
            }
        })
        .collect();

    let page = RecallPage {
        rows,
        page_index: 0,
        is_last: true,
    };
    let context = synthesize(&page, &meta, 3);

    // v1.1.0: if a calibration curve was supplied, map each drawer's
    // confidence ordinal to [0, 1] (raw_value max = 56) and calibrate.
    let calibrated_confidences = calibration_curve.map(|curve| {
        let claimed: Vec<f32> = drawers
            .iter()
            .map(|d| d.confidence().raw_value() as f32 / 56.0)
            .collect();
        calibrate(curve, &claimed)
    });

    Ok(TrustGroundedOutput {
        context,
        ranked_ids,
        high_trust_count,
        calibrated_confidences,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::sync::Arc;

    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    /// Empty node-name map for tests — no display-name resolution needed.
    fn empty_names() -> std::collections::HashMap<String, (String, String)> {
        std::collections::HashMap::new()
    }

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    /// Capture a drawer with a given source type; return its minted id.
    fn capture(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        content: &str,
        st: SourceType,
    ) -> String {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        frame.source_type = st;
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-TR-1: the lens RUNS and ranks by provenance trust — canonical
    // memories ground the context ahead of derived ones, end-to-end over a
    // real estate. The estate leans on what it most trusts.
    #[test]
    fn ck_tr1_canonical_outranks_derived() {
        let (coord, h) = coord_with_parent();
        let c1 = capture(&coord, &h, "canonical-a", SourceType::Canonical);
        let c2 = capture(&coord, &h, "canonical-b", SourceType::Canonical);
        let _d1 = capture(&coord, &h, "derived-a", SourceType::Derived);
        let _d2 = capture(&coord, &h, "derived-b", SourceType::Derived);

        let out = run_trust_grounded_synthesis(&coord, &h, unconfirmed(), None, NOW, &empty_names()).expect("trust");
        assert_eq!(out.ranked_ids.len(), 4);
        // The two highest-ranked memories are the canonical ones.
        let top2: HashSet<&String> = out.ranked_ids[0..2].iter().collect();
        assert!(
            top2.contains(&c1) && top2.contains(&c2),
            "canonical memories rank first"
        );
        assert_eq!(out.high_trust_count, 2, "two canonical = two high-trust");
        assert!(
            !out.context.summary.is_empty(),
            "a grounded document is produced"
        );
    }

    // CK-TR-2: an empty estate yields an empty ranking and zero high-trust —
    // guarded, no panic.
    #[test]
    fn ck_tr2_empty_estate_guarded() {
        let (coord, h) = coord_with_parent();
        let out = run_trust_grounded_synthesis(&coord, &h, unconfirmed(), None, NOW, &empty_names()).expect("trust");
        assert!(out.ranked_ids.is_empty());
        assert_eq!(out.high_trust_count, 0);
    }

    // CK-TR-4: SQLite-backed estate — proves the .full hydration override is
    // exercised against the real blob-gated storage path.
    //
    // InMemory returns content regardless of hydration_level, masking the bug
    // in H-BROKEN-1/2. SQLite enforces spec § 7.3 strictly: .structured recall
    // returns content == "" for every drawer. Without the .full override in
    // run_trust_grounded_synthesis, synthesize operates on empty content bodies
    // and produces an empty-pattern context — same failure class as
    // run_contradiction (H-BROKEN content-stripping family).
    //
    // Setup: 3-drawer estate — two Canonical drawers with substantive prose,
    // one Derived drawer. Frame is .structured at the call site; the fix
    // upgrades it to .full before recall. Assertions mirror CK-CN-4 in
    // contradiction_recipe.rs.
    #[test]
    fn ck_tr4_sqlite_synthesis_non_empty() {
        use locus_kit::drawer_store::DrawerStore;
        use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
        use std::collections::HashSet;

        let path = std::env::temp_dir().join(format!(
            "cognitionkit-trustlens-test-{}.sqlite",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        let path_str = path.to_string_lossy().to_string();

        // Build a SQLite-backed estate.
        let store: Arc<dyn DrawerStore> = Arc::new(
            SqliteDrawerStore::from_path(&path_str, NOW, None, 5.0)
                .expect("SqliteDrawerStore::from_path"),
        );
        let mut coord = EstateCoordinator::new();
        let h = coord
            .open(store, OwnerCredentials::new("trust-lens-sqlite-test"), 0, 100)
            .unwrap();

        // Two canonical drawers with substantive content bodies.
        let c1 = capture(
            &coord,
            &h,
            "the substrate is local-first; sync is optional via ConvergenceKit",
            SourceType::Canonical,
        );
        let c2 = capture(
            &coord,
            &h,
            "vector storage uses sqlite-vec; embeddings live in VectorKit",
            SourceType::Canonical,
        );
        // One derived drawer — lower trust tier.
        let _d1 = capture(
            &coord,
            &h,
            "observed pattern: recall latency increases with drawer count",
            SourceType::Derived,
        );

        // Call with a .structured frame — the fix upgrades to .full before recall.
        let out =
            run_trust_grounded_synthesis(&coord, &h, unconfirmed(), None, NOW, &empty_names()).expect("trust");

        // a. All three drawers were ranked.
        assert_eq!(out.ranked_ids.len(), 3, "all three SQLite-backed drawers must be ranked");

        // b. Two high-trust drawers (the canonical pair).
        assert_eq!(out.high_trust_count, 2, "two canonical drawers must register as high-trust");

        // c. The two canonical drawers must rank first.
        let top2: HashSet<&String> = out.ranked_ids[0..2].iter().collect();
        assert!(
            top2.contains(&c1) && top2.contains(&c2),
            "canonical drawers must rank ahead of the derived drawer; got {:?}",
            out.ranked_ids
        );

        // d. The context summary is non-empty — the key proof that .full
        //    hydration ran against SQLite (content-bearing drawers were loaded).
        //    Under .structured hydration, content == "" for every drawer and
        //    synthesize produces an empty-pattern summary. This assertion fails
        //    if the .full override is absent.
        assert!(
            !out.context.summary.is_empty(),
            "context summary must be non-empty; empty = .structured hydration bug (H-BROKEN)"
        );

        // Clean up SQLite sidecar files.
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{}-wal", path_str));
        let _ = std::fs::remove_file(format!("{}-shm", path_str));
    }
}
