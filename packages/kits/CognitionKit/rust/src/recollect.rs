// recollect.rs — Rust mirror of CognitionKit/Recollect.swift.
//
// Expand a "_distilled" factoid to its source memories by following
// outgoing "_distilled_from" tunnels. Models the human experience of
// pausing and recalling deep long-term memory from a distilled factoid.
//
// GLK call sequence (parity with Swift Recollect.run, secfix/punt-g2):
//   1. coord.get_drawers_matching_frame([factoidID], full frame)
//      → bounded by-ids hydration; find factoid in admissible set.
//   2. DistilledHeader::parse → validate DIST header.
//   3. EstateCoordinator::recall_tunnels(wing) → filter _distilled_from tunnels.
//   4. coord.get_drawers_matching_frame(sourceIDs, full frame)
//      → second bounded by-ids hydration for source drawers.
//
// secfix/recollect: both hydration calls route through BitmapEvaluator::
// insert_defaults which prepends SensitivityAtMost(Elevated), Trustworthy,
// and CurrentlyBelieve when the caller supplies an empty filter chain.
// Restricted and secret factoids are absent from the admissible set →
// factoidNotFound, preventing disclosure of elevated factoid bodies at the
// MCP boundary. Restricted/secret source drawers are silently omitted from
// the step-4 result (same ceiling applies).
//
// Layer discipline B-1/B-2: pure sequencing. Read-only (B-6, I-6).
// Deterministic: _now accepted in signature for API stability; the by-ids
// hydration path derives no clock-dependent state from it.

use genius_locus_kit::brain::distillation_cycle::DISTILLED_FROM_LABEL;
use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::handle::EstateHandle;
use locus_kit::filter::{HydrationLevel, RecallFrame};
use substrate_ml::distillation_pipeline::DistilledHeader;

// Test-only capture helper — consolidates the boilerplate for CaptureFrame::new
// so test bodies stay readable.
#[cfg(test)]
fn test_capture_frame(
    content: &str,
    room: &str,
) -> locus_kit::frames::CaptureFrame {
    locus_kit::frames::CaptureFrame::new(
        content,
        locus_kit::drawer_operational::CaptureChannel::Typed,
        room,
        locus_kit::estate_types::LatticeAnchor::udc("0"),
        "test",
        "test-v1",
    )
}

// MARK: - ExpandedSource

/// One source memory expanded from a distilled factoid.
///
/// Mirrors `ExpandedSource` in the Swift port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpandedSource {
    /// Source drawer UUID.
    pub id: String,
    /// Room the source was filed in.
    pub room: String,
    /// Full text content of the source memory.
    pub content: String,
}

// MARK: - RecollectError

/// Errors raised by `run_recollect`.
///
/// Mirrors `RecollectError` in the Swift port. Maps to `VerbDispatchError`
/// via `RecollectError` rather than being a sub-variant of VerbDispatchError
/// so recipe callers can match on the three structural invariant failures without
/// sifting through all VerbDispatch arms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecollectError {
    /// The factoid drawer ID was absent from the estate.
    FactoidNotFound { id: String },
    /// The drawer exists but carries no DIST header — not a distilled factoid.
    NotADistilledDrawer { id: String },
    /// The factoid exists but has no outgoing `_distilled_from` tunnels.
    NoSourceTunnels { id: String },
    /// Underlying VerbDispatchError from coordinator read (stale handle etc).
    VerbDispatch(String),
}

impl std::fmt::Display for RecollectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecollectError::FactoidNotFound { id } =>
                write!(f, "factoid not found: {id}"),
            RecollectError::NotADistilledDrawer { id } =>
                write!(f, "drawer is not a distilled factoid: {id}"),
            RecollectError::NoSourceTunnels { id } =>
                write!(f, "no _distilled_from tunnels for factoid: {id}"),
            RecollectError::VerbDispatch(msg) =>
                write!(f, "verb dispatch error: {msg}"),
        }
    }
}

impl From<VerbDispatchError> for RecollectError {
    fn from(e: VerbDispatchError) -> Self {
        RecollectError::VerbDispatch(format!("{e:?}"))
    }
}

// MARK: - Input / Output

/// UUID of the `_distilled` drawer to fan out from.
///
/// Mirrors `Recollect.Input` in the Swift port.
#[derive(Debug, Clone)]
pub struct RecollectInput {
    /// The `_distilled` drawer UUID to fan out from.
    pub factoid_drawer_id: String,
}

impl RecollectInput {
    pub fn new(factoid_drawer_id: impl Into<String>) -> Self {
        RecollectInput { factoid_drawer_id: factoid_drawer_id.into() }
    }
}

/// Factoid metadata and its source memories, ordered oldest → newest.
///
/// Mirrors `Recollect.Output` in the Swift port.
#[derive(Debug, Clone, PartialEq)]
pub struct RecollectOutput {
    /// The factoid drawer UUID.
    pub factoid_id: String,
    /// Factoid prose (DIST header stripped).
    pub prose: String,
    /// Confidence score conf(F*) ∈ [0, 1], from DIST header.
    pub confidence: f32,
    /// Source count M from DIST header. May exceed `sources.len()` if some
    /// sources were subsequently withdrawn from the estate.
    pub source_count: usize,
    /// DeltaType raw string when the factoid was promoted from a non-static
    /// sequence (e.g. "CONVERGENT"); None for STATIC factoids.
    pub delta_type: Option<String>,
    /// Source memories ordered oldest → newest (by tunnel filed_at).
    pub sources: Vec<ExpandedSource>,
}

// MARK: - Recipe body

/// Fan-out from a distilled factoid to its source memories.
///
/// Rust parity of `Recollect.run(input:estate:kit:)` in the Swift port.
///
/// Three error gates enforce structural invariants before content is returned:
///   - `FactoidNotFound`      — the id is not in this estate.
///   - `NotADistilledDrawer`  — the drawer exists but lacks a DIST header.
///   - `NoSourceTunnels`      — the factoid has no `_distilled_from` tunnels.
///
/// Withdrawn sources are absent from the drawer list and are silently skipped,
/// so `output.source_count` (from the DIST header) may exceed `output.sources.len()`
/// after withdrawals — mirroring Swift comment: "sourceCount records M at
/// distillation time and remains accurate even when sources.count shrinks."
///
/// Read-only (B-6, I-6). No side effects.
pub fn run_recollect(
    input: &RecollectInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    // _now is accepted for API compatibility with callers that supply a wall-clock
    // timestamp. The by-ids hydration path uses no current-clock token; any
    // historical reconstruction is driven by the frame's optional HLC field.
    _now: i64,
) -> Result<RecollectOutput, RecollectError> {
    // 1. Hydrate the factoid drawer through the bounded by-ids path.
    //
    //    Parity with Swift Recollect.run step 1:
    //      `kit.hydrate(estate, ids: [factoidID],
    //                   matchingFrame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 1))`
    //
    //    An empty filter chain causes BitmapEvaluator::insert_defaults to prepend
    //    SensitivityAtMost(Elevated), Trustworthy, and CurrentlyBelieve — the same
    //    defaults the full estate recall path enforces. A restricted or secret factoid
    //    is absent from the admissible result → FactoidNotFound, preventing disclosure
    //    of elevated factoid bodies at the MCP boundary. secfix/recollect.
    //
    //    HydrationLevel::Full is required so drawer.content is populated for DIST
    //    header parsing. Structured hydration leaves content empty →
    //    DistilledHeader::parse returns None → spurious NotADistilledDrawer.
    //
    //    No .limit is set: get_drawers_matching_frame is inherently bounded to
    //    the ids slice. Passing usize::MAX as limit (the prior approach) caused
    //    SQLite to receive LIMIT 18446744073709551615, which it rejects with
    //    "datatype mismatch (20)" — surfaced as an empty degraded stream and a
    //    spurious FactoidNotFound on non-trivial estates. secfix/recollect.
    let mut factoid_frame = RecallFrame::new(vec![]);
    factoid_frame.hydration_level = HydrationLevel::Full;
    let factoid_results = coord
        .get_drawers_matching_frame(handle, &[input.factoid_drawer_id.clone()], &factoid_frame)
        .map_err(RecollectError::from)?;
    let factoid = factoid_results
        .iter()
        .find(|d| d.id == input.factoid_drawer_id)
        .ok_or_else(|| RecollectError::FactoidNotFound {
            id: input.factoid_drawer_id.clone(),
        })?;

    // 2. Validate DIST header.
    let header = DistilledHeader::parse(&factoid.content)
        .ok_or_else(|| RecollectError::NotADistilledDrawer {
            id: input.factoid_drawer_id.clone(),
        })?;

    // 3. Resolve the wing for this factoid from the node tree, then recall tunnels.
    //    Swift uses LocusKit.defaultWingName ("Agentic Memory") as the fixed wing.
    //    Rust resolves the factoid's actual wing via resolve_drawer_node_names so
    //    the recipe works even when a non-default wing is used — more robust than
    //    hardcoding the constant.
    let node_names = coord.resolve_drawer_node_names(
        handle,
        &[factoid.parent_node_id.clone()],
    );
    let factoid_wing = node_names
        .get(&factoid.parent_node_id)
        .map(|(w, _)| w.as_str())
        // Fall back to the canonical default wing if node lookup fails (new estate,
        // no node topology registered). Matches Swift's defaultWingName usage.
        .unwrap_or(locus_kit::default_wings::DEFAULT_WING_NAME);

    let tunnels = coord
        .recall_tunnels(handle, factoid_wing)
        .map_err(RecollectError::from)?;

    // Filter to _distilled_from tunnels where this factoid is the source.
    // Sort oldest → newest (tunnel.filed_at is epoch seconds) so narrative
    // reads chronologically — parity with Swift `.sorted { $0.filedAt < $1.filedAt }`.
    let mut source_tunnels: Vec<&locus_kit::tunnel::Tunnel> = tunnels
        .iter()
        .filter(|t| {
            t.label == DISTILLED_FROM_LABEL
                && t.source_drawer_id.as_deref() == Some(&input.factoid_drawer_id)
        })
        .collect();
    source_tunnels.sort_by_key(|t| t.filed_at);

    if source_tunnels.is_empty() {
        return Err(RecollectError::NoSourceTunnels {
            id: input.factoid_drawer_id.clone(),
        });
    }

    // 4. Hydrate source drawers through a second bounded by-ids call.
    //
    //    Parity with Swift Recollect.run step 4:
    //      `kit.hydrate(estate, ids: sourceIDs,
    //                   matchingFrame: RecallFrame(filterChain: [], hydrationLevel: .full,
    //                                              limit: sourceIDs.count))`
    //
    //    An empty filter chain causes insert_defaults to apply the same sensitivity
    //    ceiling (SensitivityAtMost(Elevated)). Restricted/secret source drawers are
    //    absent from the admissible result and silently skipped — consistent with the
    //    "sources.count shrinks due to filtering" contract: the factoid was produced
    //    from a high-sensitivity source that has since aged or been reclassified, and
    //    the source preview is not admissible without an elevation grant.
    //
    //    No .limit is set: the call is bounded by source_ids.len(), matching Swift's
    //    `limit: sourceIDs.count` (both are per-id, not full-estate, scans).
    //    B-1 compliant.
    let source_ids: Vec<String> = source_tunnels
        .iter()
        .filter_map(|t| t.target_drawer_id.clone())
        .collect();
    let mut source_frame = RecallFrame::new(vec![]);
    source_frame.hydration_level = HydrationLevel::Full;
    let source_drawers = coord
        .get_drawers_matching_frame(handle, &source_ids, &source_frame)
        .map_err(RecollectError::from)?;
    let source_by_id: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> =
        source_drawers
            .iter()
            .map(|d| (d.id.as_str(), d))
            .collect();

    // Build sources in tunnel order (oldest → newest).
    // Withdrawn sources are silently skipped (present in tunnels, absent from
    // source_by_id) — parity with Swift's `compactMap` on sourceBodyMap.
    let sources: Vec<ExpandedSource> = source_tunnels
        .iter()
        .filter_map(|t| {
            let target_id = t.target_drawer_id.as_deref()?;
            let drawer = source_by_id.get(target_id)?;
            Some(ExpandedSource {
                id: drawer.id.clone(),
                room: t.target_room.clone(),
                content: drawer.content.clone(),
            })
        })
        .collect();

    Ok(RecollectOutput {
        factoid_id: input.factoid_drawer_id.clone(),
        prose: header.prose,
        confidence: header.confidence,
        source_count: header.source_count,
        delta_type: header.delta_type.map(|dt| dt.as_str().to_owned()),
        sources,
    })
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // CK-EM-1 (Rust): factoid not in estate → FactoidNotFound.
    #[test]
    fn ck_em1_factoid_not_found() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};
        use uuid::Uuid;

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let missing_id = Uuid::new_v4().to_string();
        let input = RecollectInput::new(&missing_id);
        let result = run_recollect(&input, &coord, &handle, NOW);
        match result {
            Err(RecollectError::FactoidNotFound { id }) => {
                assert_eq!(id, missing_id, "error must name the missing id");
            }
            other => panic!("expected FactoidNotFound, got {:?}", other),
        }
    }

    // CK-EM-2 (Rust): drawer without DIST header → NotADistilledDrawer.
    #[test]
    fn ck_em2_not_a_distilled_drawer() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture an ordinary (non-distilled) drawer.
        let frame = test_capture_frame("This is not a distilled factoid.", "notes");
        let row = coord.capture(&handle, frame, NOW).expect("capture");

        let input = RecollectInput::new(row.id.to_string());
        let result = run_recollect(&input, &coord, &handle, NOW);
        match result {
            Err(RecollectError::NotADistilledDrawer { id }) => {
                assert_eq!(id, row.id.to_string());
            }
            other => panic!("expected NotADistilledDrawer, got {:?}", other),
        }
    }

    // CK-EM-3 (Rust): distilled factoid with no tunnels → NoSourceTunnels.
    #[test]
    fn ck_em3_no_source_tunnels() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture a drawer with a valid DIST header but no _distilled_from tunnels.
        let dist_content = "[DIST|conf=0.80|src=3|snr=2.5] Test factoid prose.";
        let frame = test_capture_frame(dist_content, "_distilled");
        let row = coord.capture(&handle, frame, NOW).expect("capture");

        let input = RecollectInput::new(row.id.to_string());
        let result = run_recollect(&input, &coord, &handle, NOW);
        match result {
            Err(RecollectError::NoSourceTunnels { id }) => {
                assert_eq!(id, row.id.to_string());
            }
            other => panic!("expected NoSourceTunnels, got {:?}", other),
        }
    }

    // CK-EM-4 (Rust): RecollectError display covers all variants.
    #[test]
    fn ck_em4_error_display() {
        let id = "abc-123".to_string();
        assert!(RecollectError::FactoidNotFound { id: id.clone() }.to_string().contains(&id));
        assert!(RecollectError::NotADistilledDrawer { id: id.clone() }.to_string().contains(&id));
        assert!(RecollectError::NoSourceTunnels { id: id.clone() }.to_string().contains(&id));
        assert!(!RecollectError::VerbDispatch("oops".to_string()).to_string().is_empty());
    }

    // CK-EM-5 (Rust): ExpandedSource fields round-trip.
    #[test]
    fn ck_em5_expanded_source_fields() {
        let src = ExpandedSource {
            id: "id-1".to_string(),
            room: "notes".to_string(),
            content: "Some content.".to_string(),
        };
        assert_eq!(src.id, "id-1");
        assert_eq!(src.room, "notes");
        assert_eq!(src.content, "Some content.");
    }
}
