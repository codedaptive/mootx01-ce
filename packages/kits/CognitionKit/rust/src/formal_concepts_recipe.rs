//! FormalConcepts — the conscious "what clusters are hidden in my estate"
//! recipe (Analytics). Rust version of the Swift `FormalConcepts` in
//! `CognitionKit/Sources/CognitionKit/FormalConcepts.swift`.
//! Paired with the Swift version (`Sources/CognitionKit/FormalConcepts.swift`).
//!
//! Recalls a set of drawers, builds a `FormalContext` where each drawer
//! is one row and its categorical facets are its attributes, and surfaces
//! SubstrateML's `BoundedConceptMiner`.
//!
//! Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//!   - Estate read: one `coord.recall` call.
//!   - Context build: one row per recalled drawer. The drawer's discovery
//!     spine + filing tiebreakers become `FormalAttribute` with namespace
//!     "locus", key = axis name, value = the canonical lowercase camelCase
//!     Swift case name (§ 4.2 vocabulary, identical across both versions).
//!   - Concept mining: one `BoundedConceptMiner::mine` call — the engine
//!     owns all closure/dedup/ordering logic.
//!
//! Discovery spine (FORMAL_CONCEPTS_DISCOVERY_SPINE_001): the context is
//! built so concepts emerge from about-ness and provenance, not from the
//! authored taxonomy. The spine attributes are trust (provenance), the
//! lattice anchors udc/qid (about-ness), and sensitivity (access posture).
//! The filing facets (kind/channel/room) are retained as secondary
//! tiebreakers that can refine a concept but no longer define it.
//!
//! Drawer → FormalContext mapping (mirrors Swift):
//!   Each drawer is one row; its attributes are:
//!     FormalAttribute { namespace:"locus", key:"trust",       value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"sensitivity", value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"kind",        value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"channel",     value:{caseName} }
//!     FormalAttribute { namespace:"locus", key:"room",        value:{roomString} }
//!     FormalAttribute { namespace:"locus", key:"udc",         value:{udcCode} }   // only when non-empty
//!     FormalAttribute { namespace:"locus", key:"qid",         value:{wikidataQid} } // only when non-nil/non-empty
//!   The caseName is the lowercase camelCase Swift name, NOT the Rust
//!   Debug/Display form.
//!
//! Anchor-omission (load-bearing): an absent anchor is OMITTED, never emitted
//! as an empty attribute. `udc_code == ""` contributes no `udc`; a `None`
//! `wikidata_qid` contributes no `qid`. Emitting `udc=` / `qid=` for
//! unanchored drawers would fuse every unanchored drawer into one spurious
//! shared concept — the opposite of discovery.
//!
//! Output relabeling: engine row indices are mapped back to drawer IDs.
//! Intent attributes are projected to "{namespace}.{key}={value}" strings
//! (e.g. "locus.kind=prose"), matching the Swift output format.
//!
//! Read-only: no write verb. Capability gate: `FormalConceptAnalysis`.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::{AdjectiveSensitivity, Trust};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
use locus_kit::filter::RecallFrame;
use substrate_ml::formal_concept_analysis::{BoundedConceptMiner, FormalAttribute, FormalContext};

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
    let rows: Vec<Vec<FormalAttribute>> =
        drawers.iter().map(formal_attributes_for_drawer).collect();
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

/// Build the `FormalAttribute` set for a single recalled drawer — the
/// discovery spine (trust + lattice + sensitivity) plus the filing facets
/// as tiebreakers.
///
/// Namespace "locus" is the substrate vocabulary namespace (§ 4.2).
/// The value strings are canonical lowercase camelCase Swift names —
/// NOT Rust PascalCase Debug names — so both versions produce identical
/// attribute vocabularies. The lattice anchors (udc/qid) are omitted when
/// absent (see the module header's anchor-omission note).
fn formal_attributes_for_drawer(drawer: &Drawer) -> Vec<FormalAttribute> {
    let mut attributes = vec![
        // Spine — provenance: how the substrate qualifies the row's reliability.
        FormalAttribute::new("locus", "trust", trust_value(drawer.trust())),
        // Spine — access posture.
        FormalAttribute::new(
            "locus",
            "sensitivity",
            sensitivity_value(drawer.adjective_sensitivity()),
        ),
        // Tiebreakers — filing facets (retained, no longer the spine).
        FormalAttribute::new("locus", "kind", content_kind_value(drawer.content_kind())),
        FormalAttribute::new(
            "locus",
            "channel",
            capture_channel_value(drawer.capture_channel()),
        ),
        FormalAttribute::new("locus", "room", &drawer.room),
    ];
    // Spine — about-ness: the lattice anchors locating the drawer in
    // knowledge space. Omit-on-absent is load-bearing: an unanchored drawer
    // contributes NO udc/qid attribute, so unanchored drawers are never
    // fused by a spurious shared empty anchor. The empty string ("") is the
    // no-anchor sentinel for `udc_code`; `None` is the no-anchor sentinel
    // for `wikidata_qid` (an empty qid string is treated as absent too).
    if !drawer.udc_code.is_empty() {
        attributes.push(FormalAttribute::new("locus", "udc", &drawer.udc_code));
    }
    if let Some(qid) = &drawer.wikidata_qid {
        if !qid.is_empty() {
            attributes.push(FormalAttribute::new("locus", "qid", qid));
        }
    }
    attributes
}

fn trust_value(trust: Trust) -> &'static str {
    match trust {
        Trust::Verbatim => "verbatim",
        Trust::Observed => "observed",
        Trust::Imported => "imported",
        Trust::Canonical => "canonical",
        Trust::Derived => "derived",
        Trust::Proposed => "proposed",
        Trust::Ambient => "ambient",
    }
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

    const NOW: i64 = 1_700_000_000;

    fn coord_with_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
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
            capture_drawer(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
        }
        for _ in 0..2 {
            capture_drawer(
                &coord,
                &h,
                "work",
                ContentKind::Code,
                CaptureChannel::Voiced,
            );
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
        capture_drawer(
            &coord,
            &h,
            "lab",
            ContentKind::StructuredJson,
            CaptureChannel::ImportedFile,
        );
        let out = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        // At least one concept (the single-drawer-singleton at min_support=1).
        assert!(!out.concepts.is_empty());
        for concept in &out.concepts {
            for intent_str in &concept.intent {
                // Swift names: "structuredJSON" not "StructuredJson", "importedFile" not "ImportedFile".
                if intent_str.contains("kind=") {
                    assert!(
                        !intent_str.contains("StructuredJson"),
                        "must use Swift name: {intent_str}"
                    );
                }
                if intent_str.contains("channel=") {
                    assert!(
                        !intent_str.contains("ImportedFile"),
                        "must use Swift name: {intent_str}"
                    );
                    // Positive check.
                    assert!(
                        intent_str.contains("importedFile"),
                        "must use Swift name: {intent_str}"
                    );
                }
            }
        }
    }

    // CK-FA-4: extent drawer IDs are populated.
    #[test]
    fn concept_extent_has_drawer_ids() {
        let (coord, h) = coord_with_estate();
        for _ in 0..2 {
            capture_drawer(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
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
            capture_drawer(
                &coord,
                &h,
                "study",
                ContentKind::Prose,
                CaptureChannel::Typed,
            );
            capture_drawer(
                &coord,
                &h,
                "work",
                ContentKind::Code,
                CaptureChannel::Voiced,
            );
        }
        let first = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        let second = run_formal_concepts(&coord, &h, unconfirmed(), default_miner(), NOW).unwrap();
        assert_eq!(first.concepts.len(), second.concepts.len());
        for (a, b) in first.concepts.iter().zip(second.concepts.iter()) {
            assert_eq!(a.intent, b.intent);
            assert_eq!(a.support, b.support);
        }
    }

    // ---- Discovery-spine legs (FORMAL_CONCEPTS_DISCOVERY_SPINE_001) ----

    /// Capture with explicit filing facets, sensitivity, and lattice anchor;
    /// returns the minted drawer id. Trust stays at the capture-time default
    /// `Verbatim` (the in-memory estate does not yet wire `CorrectTrust`).
    fn capture_rich(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        kind: ContentKind,
        channel: CaptureChannel,
        sensitivity: AdjectiveSensitivity,
        anchor: LatticeAnchor,
    ) -> String {
        let mut frame = CaptureFrame::new("content", channel, room, anchor, "test", "test-v1");
        frame.kind = kind;
        frame.sensitivity = sensitivity;
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn unconfirmed_at_most(ceiling: AdjectiveSensitivity) -> RecallFrame {
        let mut f = RecallFrame::new(vec![
            Filter::Unconfirmed,
            Filter::SensitivityAtMost(ceiling),
        ]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-FA-6: DISCOVERY — two drawers filed differently (room/kind/channel)
    // but sharing the spine (trust + udc + qid) fuse into one concept.
    #[test]
    fn discovery_groups_by_trust_and_lattice() {
        let (coord, h) = coord_with_estate();
        let id1 = capture_rich(
            &coord,
            &h,
            "study",
            ContentKind::Prose,
            CaptureChannel::Typed,
            AdjectiveSensitivity::Normal,
            LatticeAnchor::new("530", None, Some("Q11397".into()), None),
        );
        let id2 = capture_rich(
            &coord,
            &h,
            "work",
            ContentKind::Code,
            CaptureChannel::Voiced,
            AdjectiveSensitivity::Normal,
            LatticeAnchor::new("530", None, Some("Q11397".into()), None),
        );
        let out = run_formal_concepts(
            &coord,
            &h,
            unconfirmed(),
            BoundedConceptMiner::new(2, 8, 16),
            NOW,
        )
        .unwrap();

        let concept = out
            .concepts
            .iter()
            .find(|c| {
                c.extent_drawer_ids.len() == 2
                    && c.extent_drawer_ids.contains(&id1)
                    && c.extent_drawer_ids.contains(&id2)
            })
            .expect("a concept spanning both drawers must exist");
        assert_eq!(concept.support, 2);
        assert!(concept.intent.iter().any(|s| s == "locus.trust=verbatim"));
        assert!(concept.intent.iter().any(|s| s == "locus.udc=530"));
        assert!(concept.intent.iter().any(|s| s == "locus.qid=Q11397"));
        // Grouping is by the spine, not filing: facets the two disagree on
        // cannot appear in the shared intent.
        assert!(!concept.intent.iter().any(|s| s == "locus.room=study"));
        assert!(!concept.intent.iter().any(|s| s == "locus.room=work"));
        assert!(!concept.intent.iter().any(|s| s == "locus.kind=prose"));
        assert!(!concept.intent.iter().any(|s| s == "locus.kind=code"));
    }

    // CK-FA-7: ANCHOR OMISSION + trust vocabulary (direct builder unit test).
    // Capture forbids an empty udc_code (spec I-5), so the unanchored-udc case
    // is exercised by building the row directly. An absent anchor is omitted,
    // never emitted as an empty attribute; a non-default trust maps canonically.
    #[test]
    fn absent_anchors_omit_udc_qid_and_trust_maps_canonically() {
        // Unanchored: empty udc, no qid, default (verbatim) trust.
        let unanchored = Drawer::new("d1", "x", "w", "void", "t", NOW, "v1");
        let bare = formal_attributes_for_drawer(&unanchored);
        assert!(
            !bare.iter().any(|a| a.key == "udc"),
            "empty udc_code emits no udc attribute"
        );
        assert!(
            !bare.iter().any(|a| a.key == "qid"),
            "None wikidata_qid emits no qid attribute"
        );
        assert!(bare
            .iter()
            .any(|a| a.key == "trust" && a.value == "verbatim"));

        // Anchored + non-default trust (canonical = raw 3 at adjective bits 18–23).
        let mut anchored = Drawer::new("d2", "y", "w", "lab", "t", NOW, "v1");
        anchored.adjective_bitmap = Trust::Canonical.raw_value() << 18;
        anchored.udc_code = "530".to_string();
        anchored.wikidata_qid = Some("Q11397".to_string());
        let full = formal_attributes_for_drawer(&anchored);
        assert!(full.iter().any(|a| a.key == "udc" && a.value == "530"));
        assert!(full.iter().any(|a| a.key == "qid" && a.value == "Q11397"));
        assert!(full
            .iter()
            .any(|a| a.key == "trust" && a.value == "canonical"));
    }

    // CK-FA-8: CLEARANCE — recall is the gate; different sensitivity ceilings
    // produce different concept sets (a secret-only concept is unreachable for
    // the lower-clearance caller).
    #[test]
    fn clearance_scopes_concepts() {
        let (coord, h) = coord_with_estate();
        for _ in 0..2 {
            capture_rich(
                &coord,
                &h,
                "open",
                ContentKind::Prose,
                CaptureChannel::Typed,
                AdjectiveSensitivity::Normal,
                LatticeAnchor::udc("0"),
            );
        }
        for _ in 0..2 {
            capture_rich(
                &coord,
                &h,
                "vault",
                ContentKind::Prose,
                CaptureChannel::Typed,
                AdjectiveSensitivity::Secret,
                LatticeAnchor::udc("0"),
            );
        }

        let low = run_formal_concepts(
            &coord,
            &h,
            unconfirmed_at_most(AdjectiveSensitivity::Normal),
            BoundedConceptMiner::new(1, 8, 16),
            NOW,
        )
        .unwrap();
        let high = run_formal_concepts(
            &coord,
            &h,
            unconfirmed_at_most(AdjectiveSensitivity::Secret),
            BoundedConceptMiner::new(1, 8, 16),
            NOW,
        )
        .unwrap();

        let has_secret = |o: &FormalConceptsOutput| {
            o.concepts
                .iter()
                .any(|c| c.intent.iter().any(|s| s == "locus.sensitivity=secret"))
        };
        assert!(!has_secret(&low));
        assert!(has_secret(&high));
        assert!(low.drawer_count < high.drawer_count);
    }

    // CK-FA-9: REGRESSION — the filing facets are retained as attributes.
    #[test]
    fn filing_facets_retained() {
        let (coord, h) = coord_with_estate();
        capture_rich(
            &coord,
            &h,
            "study",
            ContentKind::Code,
            CaptureChannel::Voiced,
            AdjectiveSensitivity::Normal,
            LatticeAnchor::udc("600"),
        );
        let out = run_formal_concepts(
            &coord,
            &h,
            unconfirmed(),
            BoundedConceptMiner::new(1, 8, 16),
            NOW,
        )
        .unwrap();
        let all: Vec<&String> = out.concepts.iter().flat_map(|c| c.intent.iter()).collect();
        assert!(all.iter().any(|s| *s == "locus.kind=code"));
        assert!(all.iter().any(|s| *s == "locus.channel=voiced"));
        assert!(all.iter().any(|s| *s == "locus.room=study"));
    }
}
