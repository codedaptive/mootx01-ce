// hybrid_recall_chest_diversity.rs
//
// ADR-027 D3: with a container beside each drawer, two drawers in one
// container score 1.0 in the MMR similarity, so the rerank reaches for a
// drawer from another container before a container-mate. Without
// containers the shingle term alone decides and input order stands. Twin of
// the Swift `HybridRecallChestDiversityTests`.

use neuron_kit::hybrid_recall::{rerank, rerank_with_containers, DrawerRow, RecallFrameTuning};

fn pool() -> Vec<DrawerRow> {
    vec![
        DrawerRow { id: "a".into(), content: "apple banana cherry".into() },
        DrawerRow { id: "b".into(), content: "dog elephant fox".into() },
        DrawerRow { id: "c".into(), content: "kiwi lemon mango".into() },
    ]
}

fn tuning() -> RecallFrameTuning {
    RecallFrameTuning { mmr_lambda: 0.5, ..RecallFrameTuning::default_tuning() }
}

#[test]
fn on_holds_back_the_container_mate() {
    let containers = vec![Some("chest-1".to_string()), Some("chest-1".to_string()), Some("chest-2".to_string())];
    let out = rerank_with_containers(&pool(), &containers, &tuning(), &[]);
    let ids: Vec<&str> = out.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids, ["a", "c", "b"]);
}

#[test]
fn off_keeps_input_order() {
    let out = rerank(&pool(), &tuning(), &[]);
    let ids: Vec<&str> = out.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids, ["a", "b", "c"]);
}
