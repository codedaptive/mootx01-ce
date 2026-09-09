use std::sync::Arc;

use fact_extraction_kit::contract::{
    FactAssertionKind, FactCandidate, FactExtractionError, FactExtractionRequest,
    FactExtractionResponse, FactExtractor, FactExtractorKind, FactExtractorModelSpec,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::kg_fact::KGFactOrigin;

const NOW: i64 = 1_700_000_000;
const SOURCE: &str = "Jack's birthday is June 20th.";

struct FakeExtractor {
    spec: FactExtractorModelSpec,
    empty: bool,
    grounded: bool,
}

impl FactExtractor for FakeExtractor {
    fn spec(&self) -> &FactExtractorModelSpec {
        &self.spec
    }

    fn extract(
        &self,
        request: &FactExtractionRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        Ok(FactExtractionResponse {
            source_digest: request.source_digest.clone(),
            provider_id: self.spec.provider_id.clone(),
            model_id: self.spec.model_id.clone(),
            model_version: self.spec.model_version.clone(),
            schema_version: self.spec.schema_version.clone(),
            candidates: if self.empty {
                vec![]
            } else {
                vec![FactCandidate {
                    subject: "Jack".into(),
                    predicate: "birthday".into(),
                    object: if self.grounded {
                        "June 20th"
                    } else {
                        "July 4th"
                    }
                    .into(),
                    evidence_quote: if self.grounded {
                        SOURCE
                    } else {
                        "Jack's birthday is July 4th."
                    }
                    .into(),
                    confidence: 0.97,
                    assertion_kind: FactAssertionKind::Asserted,
                    search_aliases: vec!["when is Jack's birthday".into()],
                }]
            },
        })
    }
}

fn spec() -> FactExtractorModelSpec {
    FactExtractorModelSpec {
        provider_id: "test-provider".into(),
        model_id: "nuextract-test".into(),
        model_version: "q8".into(),
        schema_version: "kgfact-extraction-v1".into(),
        extractor_kind: FactExtractorKind::SpecializedModel,
        maximum_input_characters: 16_384,
        maximum_facts_per_source: 8,
    }
}

fn open() -> (
    EstateCoordinator,
    genius_locus_kit::EstateHandle,
    Arc<InMemoryDrawerStore>,
) {
    let mut coordinator = EstateCoordinator::new();
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("store"));
    let handle = coordinator
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("fact-duty"),
            0,
            100,
        )
        .expect("open");
    (coordinator, handle, store)
}

fn capture(
    coordinator: &EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    body: &str,
) -> String {
    coordinator
        .capture(
            handle,
            CaptureFrame::new(
                body,
                CaptureChannel::Typed,
                "facts",
                LatticeAnchor::udc("000"),
                "test",
                "test-v1",
            ),
            NOW,
        )
        .expect("capture")
        .id
}

#[test]
fn grounded_fact_files_with_provenance_and_settles_debt() {
    let (mut coordinator, handle, store) = open();
    let drawer_id = capture(&coordinator, &handle, SOURCE);
    coordinator
        .activate_fact_extractor(
            Arc::new(FakeExtractor {
                spec: spec(),
                empty: false,
                grounded: true,
            }),
            "nuextract-b1-q8-v1",
            &handle,
        )
        .expect("activate");
    let report = coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .expect("batch");
    assert_eq!(report.completed_sources, 1);
    assert_eq!(report.facts_filed, 1);
    assert_eq!(report.failed_sources, 0);

    let facts = store.all_kg_facts().expect("facts");
    let fact = &facts[0];
    assert_eq!(fact.source_drawer_id, drawer_id);
    assert_eq!(fact.evidence_quote, SOURCE);
    assert_eq!(fact.evidence_start, 0);
    assert_eq!(fact.evidence_end, SOURCE.chars().count() as i64);
    assert_eq!(fact.extractor_model_id, "nuextract-test");
    assert_eq!(fact.search_projection_version, "kgfact-search-v1");
    assert!(fact.search_projection.contains("when is Jack's birthday"));
    assert!(store
        .get_drawer(&drawer_id)
        .unwrap()
        .unwrap()
        .are_facts_extracted());

    let replay = coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .expect("replay");
    assert_eq!(replay.completed_sources, 0);
    assert_eq!(replay.facts_filed, 0);
}

#[test]
fn empty_response_is_a_valid_zero_fact_completion() {
    let (mut coordinator, handle, store) = open();
    let drawer_id = capture(&coordinator, &handle, "A friendly hello.");
    coordinator
        .activate_fact_extractor(
            Arc::new(FakeExtractor {
                spec: spec(),
                empty: true,
                grounded: true,
            }),
            "nuextract-b1-q8-v1",
            &handle,
        )
        .expect("activate");
    let report = coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .expect("batch");
    assert_eq!(report.completed_sources, 1);
    assert_eq!(report.facts_filed, 0);
    assert!(store.all_kg_facts().unwrap().is_empty());
    assert!(store
        .get_drawer(&drawer_id)
        .unwrap()
        .unwrap()
        .are_facts_extracted());
}

#[test]
fn wholly_ungrounded_output_stays_debt() {
    let (mut coordinator, handle, store) = open();
    let drawer_id = capture(&coordinator, &handle, SOURCE);
    coordinator
        .activate_fact_extractor(
            Arc::new(FakeExtractor {
                spec: spec(),
                empty: false,
                grounded: false,
            }),
            "nuextract-b1-q8-v1",
            &handle,
        )
        .unwrap();
    let result = coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .unwrap();
    assert_eq!(result.failed_sources, 1);
    assert_eq!(result.facts_filed, 0);
    assert!(!store
        .get_drawer(&drawer_id)
        .unwrap()
        .unwrap()
        .are_facts_extracted());
    assert!(store.all_kg_facts().unwrap().is_empty());
}

#[test]
fn recipe_replacement_retires_machine_fact_but_preserves_manual_fact() {
    let (mut coordinator, handle, store) = open();
    let drawer_id = capture(&coordinator, &handle, SOURCE);
    coordinator
        .activate_fact_extractor(
            Arc::new(FakeExtractor {
                spec: spec(),
                empty: false,
                grounded: true,
            }),
            "nuextract-b1-q8-v1",
            &handle,
        )
        .unwrap();
    coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .unwrap();
    let old_machine_id = store.all_kg_facts().unwrap()[0].id.clone();
    let manual = coordinator
        .add_kg_fact_with_id_and_origin(
            &handle,
            "manual-jack-birthday-note",
            "Jack",
            "birthday-note",
            "confirmed by Bob",
            &drawer_id,
            &KGFactOrigin {
                added_by: "human".into(),
                ..KGFactOrigin::default()
            },
            NOW,
        )
        .unwrap();

    let mut replacement_spec = spec();
    replacement_spec.model_id = "nuextract-replacement".into();
    replacement_spec.schema_version = "kgfact-extraction-v2".into();
    assert_eq!(
        coordinator
            .activate_fact_extractor(
                Arc::new(FakeExtractor {
                    spec: replacement_spec,
                    empty: false,
                    grounded: true,
                }),
                "nuextract-replacement-v2",
                &handle,
            )
            .unwrap(),
        1
    );
    let report = coordinator
        .run_fact_extraction_batch(&handle, 16, NOW)
        .unwrap();
    assert_eq!(report.completed_sources, 1);
    assert_eq!(report.facts_filed, 1);

    let active = store.all_kg_facts().unwrap();
    assert!(active.iter().any(|fact| fact.id == manual.id));
    assert!(!active.iter().any(|fact| fact.id == old_machine_id));
    assert!(active
        .iter()
        .any(|fact| fact.extractor_model_id == "nuextract-replacement"));
    let history = store.all_kg_facts_including_retired().unwrap();
    assert_eq!(history.len(), 3);
    assert!(history.iter().any(|fact| fact.id == old_machine_id));
}
