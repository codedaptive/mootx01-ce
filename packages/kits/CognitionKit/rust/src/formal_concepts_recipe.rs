//! FormalConcepts — the conscious "what clusters are hidden in my estate"
//! recipe (Analytics). Rust version of the Swift `FormalConcepts` in
//! `CognitionKit/Sources/CognitionKit/FormalConcepts.swift`.
//!
//! Recalls a set of drawers, builds a `FormalContext` where each drawer
//! is one row and its categorical facets are its attributes, and surfaces
//! NeuronKit's `BoundedConceptMiner`.
//!
//! Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//!   - Estate read: one `coord.recall` call.
//!   - Context build: one row per recalled drawer. The drawer's four
//!     categorical facets become `FormalAttribute` with namespace "locus",
//!     key = axis name, value = the canonical lowercase camelCase Swift case
//!     name (§ 4.2 vocabulary, identical across both versions).
//!   - Concept mining: one `BoundedConceptMiner::mine` call — the engine
//!     owns all closure/dedup/ordering logic.
//!
//! Drawer → FormalContext mapping (mirrors Swift):
//!   Each drawer is one row; its attributes are:
//!     FormalAttribute { namespace:"locus", key:"kind",        value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"channel",     value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"sensitivity", value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"room",        value:{roomString} }
//!   The caseName is the lowercase camelCase Swift name, NOT the Rust
//!   Debug/Display form.
//!
//! Output relabeling: engine row indices are mapped back to drawer IDs.
//! Intent attributes are projected to "{namespace}.{key}={value}" strings
//! (e.g. "locus.kind=prose"), matching the Swift output format.
//!
//! Read-only: no write verb. Capability gate: `FormalConceptAnalysis`.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
use locus_kit::filter::RecallFrame;
use neuron_kit::{BoundedConceptMiner, FormalAttribute, FormalContext};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

// MARK: - Result types

/// One mining result concept with drawer IDs substituted for raw row indices,
/// and the intent as human-readable attribute strings.
/// Mirrors Swift `FormalConceptResult`.
#[derive(Debug, Clone, PartialEq)]
pub struct FormalConceptResult {
    /// Intent attributes as "{namespace}.{key}={value}" strings
    /// (e.g. "locus.kind=prose"), sorted ascending.
    pub intent: Vec<String>,
    /// Drawer IDs of the concept's extent, in row-index order.
    pub extent_drawer_ids: Vec<String>,
    /// Number of drawers in the extent.
    pub support: usize,
}

/// Output of the FormalConcepts recipe.
#[derive(Debug, Clone, PartialEq)]
pub struct FormalConceptsOutput {
    /// Mined concepts with drawer-ID extents, sorted by support descending
    /// (then intent size ascending, then lexicographic intent).
    pub concepts: Vec<FormalConceptResult>,
    /// Number of drawers the context was built from.
    pub drawer_count: usize,
}

// MARK: - Recipe entry point

/// Run the FormalConcepts recipe: recall drawers via `frame`, build a
/// `FormalContext`, and mine bounded formal concepts.
///
/// Mirrors Swift `FormalConcepts.run(input:estate:kit:)`.
pub fn run_formal_concepts(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    miner: BoundedConceptMiner,
    now: i64,
) -> Result<FormalConceptsOutput, RecipeRunError> {
    // B-5: verify capability before any estate touch.
    verify_capabilities(
        &[NeuronKitCapability::FormalConceptAnalysis],
        &shipped_capabilities(),
    )
    .map_err(|e| SubstrateError::new("capability_gate", format!("{e:?}")))?;

    // 1. Recall drawers.
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let drawer_count = drawers.len();

    if drawer_count == 0 {
        return Ok(FormalConceptsOutput {
            concepts: vec![],
            drawer_count: 0,
        });
    }

    // 2. Build FormalContext: one row per drawer.
    let rows: Vec<Vec<FormalAttribute>> = drawers
        .iter()
        .map(|d| formal_attributes_for_drawer(d))
        .collect();
    let context = FormalContext::new(&rows);

    // 3. Mine bounded concepts.
    let raw_concepts = miner.mine(&context);

    // 4. Relabel: row index → drawer ID; attribute → "{ns}.{key}={value}".
    let concepts: Vec<FormalConceptResult> = raw_concepts
        .into_iter()
        .map(|concept| {
            let intent: Vec<String> = concept
                .intent
                .iter()
                .map(|attr| format!("{}.{}={}", attr.namespace, attr.key, attr.value))
                .collect();
            let extent_drawer_ids: Vec<String> = concept
                .extent
                .iter()
                .filter_map(|&row_id| {
                    let idx = row_id as usize;
                    drawers.get(idx).map(|d| d.id.clone())
                })
                .collect();
            FormalConceptResult {
                intent,
                extent_drawer_ids,
                support: concept.support,
            }
        })
        .collect();

    Ok(FormalConceptsOutput {
        concepts,
        drawer_count,
    })
}

// MARK: - Attribute helpers

/// Build the `FormalAttribute` set for a single recalled drawer.
///
/// Namespace "locus" is the substrate vocabulary namespace (§ 4.2).
/// The value strings are canonical lowercase camelCase Swift names —
/// NOT Rust PascalCase Debug names — so both versions produce identical
/// attribute vocabularies.
fn formal_attributes_for_drawer(drawer: &Drawer) -> Vec<FormalAttribute> {
    vec![
        FormalAttribute::new("locus", "kind", content_kind_value(drawer.content_kind())),
        FormalAttribute::new(
            "locus",
            "channel",
            capture_channel_value(drawer.capture_channel()),
        ),
        FormalAttribute::new(
            "locus",
            "sensitivity",
            sensitivity_value(drawer.adjective_sensitivity()),
        ),
        FormalAttribute::new("locus", "room", &drawer.room),
    ]
}

fn content_kind_value(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::Prose => "prose",
        ContentKind::Code => "code",
        ContentKind::Transcript => "transcript",
        ContentKind::List => "list",
        ContentKind::StructuredJson => "structuredJSON",
        ContentKind::ImageCaption => "imageCaption",
        ContentKind::FingerprintOnly => "fingerprintOnly",
    }
}

fn capture_channel_value(channel: CaptureChannel) -> &'static str {
    match channel {
        CaptureChannel::Typed => "typed",
        CaptureChannel::Voiced => "voiced",
        CaptureChannel::Ocr => "ocr",
        CaptureChannel::ImportedFile => "importedFile",
        CaptureChannel::Sensor => "sensor",
        CaptureChannel::Actuator => "actuator",
    }
}

fn sensitivity_value(sensitivity: AdjectiveSensitivity) -> &'static str {
    match sensitivity {
        AdjectiveSensitivity::Normal => "normal",
        AdjectiveSensitivity::Elevated => "elevated",
        AdjectiveSensitivity::Restricted => "restricted",
        AdjectiveSensitivity::Secret => "secret",
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        (coord, h)
    }

    fn capture_drawer(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        kind: ContentKind,
        channel: CaptureChannel,
    ) {
        let mut frame = CaptureFrame::new(
            "content",
            channel,
            room,
            LatticeAnchor::udc("0"),
            "test",
            "test-v1",
        );
        frame.kind = kind;
        coord.capture(h, frame, NOW).unwrap();
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn default_miner() -> BoundedConceptMiner {
        BoundedConceptMiner::new(1, 8, 10)
    }

    // CK-FA-1: empty estate — no drawers, no concepts.
    #[test]
    fn empty_estate_yields_no_concepts() {
        let (coord, h) = coord_with_estate();
        let out = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        assert!(out.concepts.is_empty());
        assert_eq!(out.drawer_count, 0);
    }

    // CK-FA-2: two disjoint cohorts produce at least two concepts.
    #[test]
    fn two_cohorts_yield_concepts() {
        let (coord, h) = coord_with_estate();
        for _ in 0..3 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
        }
        for _ in 0..2 {
            capture_drawer(&coord, &h, "work", ContentKind::Code, CaptureChannel::Voiced);
        }
        let out = run_formal_concepts(
            &coord,
            &h,
            unconfirmed(),
            BoundedConceptMiner::new(2, 8, 10),
            NOW,
        )
        .unwrap();
        assert_eq!(out.drawer_count, 5);
        // At least one cohort-specific concept.
        assert!(out.concepts.len() >= 2);
        // Sorted by support descending.
        for i in 1..out.concepts.len() {
            assert!(out.concepts[i - 1].support >= out.concepts[i].support);
        }
    }

    // CK-FA-3: canonical attribute values use Swift names.
    #[test]
    fn attribute_values_use_swift_canonical_names() {
        let (coord, h) = coord_with_estate();
        capture_drawer(&coord, &h, "lab", ContentKind::StructuredJson, CaptureChannel::ImportedFile);
        let out = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        // At least one concept (the single-drawer-singleton at min_support=1).
        assert!(!out.concepts.is_empty());
        for concept in &out.concepts {
            for intent_str in &concept.intent {
                // Swift names: "structuredJSON" not "StructuredJson", "importedFile" not "ImportedFile".
                if intent_str.contains("kind=") {
                    assert!(!intent_str.contains("StructuredJson"), "must use Swift name: {intent_str}");
                }
                if intent_str.contains("channel=") {
                    assert!(!intent_str.contains("ImportedFile"), "must use Swift name: {intent_str}");
                    // Positive check.
                    assert!(intent_str.contains("importedFile"), "must use Swift name: {intent_str}");
                }
            }
        }
    }

    // CK-FA-4: extent drawer IDs are populated.
    #[test]
    fn concept_extent_has_drawer_ids() {
        let (coord, h) = coord_with_estate();
        for _ in 0..2 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
        }
        let out = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        assert!(!out.concepts.is_empty());
        for concept in &out.concepts {
            assert!(!concept.extent_drawer_ids.is_empty());
        }
    }

    // CK-FA-5: determinism — same estate, same output twice.
    #[test]
    fn concepts_are_deterministic() {
        let (coord, h) = coord_with_estate();
        for _ in 0..3 {
            capture_drawer(&coord, &h, "study", ContentKind::Prose, CaptureChannel::Typed);
            capture_drawer(&coord, &h, "work", ContentKind::Code, CaptureChannel::Voiced);
        }
        let first = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        let second = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        assert_eq!(first.concepts.len(), second.concepts.len());
        for (a, b) in first.concepts.iter().zip(second.concepts.iter()) {
            assert_eq!(a.intent, b.intent);
            assert_eq!(a.support, b.support);
        }
    }
}
