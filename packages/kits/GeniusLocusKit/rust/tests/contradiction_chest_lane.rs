// contradiction_chest_lane.rs
//
// ADR-027 D2: with `chest_contradiction_candidates` on, the contradiction
// hunt pairs each probe with every live drawer of its container, so pairs
// the lexical lane never surfaces are still screened. Twin of the Swift
// `chestLanePairsContainerMates`.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_preference::{EstatePreferenceKey, EstatePreferenceValue};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(content, CaptureChannel::Typed, "study", LatticeAnchor::udc("0"), "test-agent", "test-embed-v1")
}

#[test]
fn chest_lane_pairs_container_mates() {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).expect("open");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("corpus"),
    );
    coord.register_vector_store(&h, corpus.shared_vector_store());
    coord.register_corpus(&h, Arc::clone(&corpus));

    let a = coord.capture(&h, cap_frame("the api timeout is 30 seconds"), NOW).expect("capture");
    let b = coord.capture(&h, cap_frame("the api timeout is 90 seconds"), NOW).expect("capture");
    let filler = coord.capture(&h, cap_frame("grocery list apples and oranges"), NOW).expect("capture");
    for d in [&a, &b, &filler] {
        corpus.ingest(&d.content, &d.id, NOW * 1000).expect("ingest");
    }

    let off = coord.hunt_contradictions(&h, "test-embed-v1", 64, None, 64, NOW).expect("hunt");
    assert!(off.vector_store_available);
    assert_eq!(off.pairs_screened, 1, "the lexical lane pairs only the two timeout drawers");

    coord
        .provision_preference(&h, EstatePreferenceKey::ChestContradictionCandidates, EstatePreferenceValue::On)
        .expect("provision");
    let on = coord.hunt_contradictions(&h, "test-embed-v1", 64, None, 64, NOW + 1).expect("hunt");
    // Three pairs in the container: the settled timeout pair is deduplicated,
    // the two filler pairs the lexical lane never surfaced are screened.
    assert_eq!(on.deduplicated, 1, "the timeout pair was settled by the first pass");
    assert_eq!(on.pairs_screened, 2, "the container-mate pairs are screened");
    assert!(on.proposed.is_empty());
}
