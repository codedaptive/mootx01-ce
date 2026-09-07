// union_best_budget_stages.rs
//
// The two unionBest work bounds from the 2026-09-07 security scan, the Rust
// twin of Tests/GeniusLocusKitTests/UnionBestBudgetStagesTests.swift:
//
//   1. Step 9.5 shingle view budget (finding aaae7a3c2): every body is
//      shingled over the same prefix, `UNION_BEST_MMR_BODY_CAP_SCALARS` or
//      the even share of `UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS`, whichever
//      is shorter. A `moot_memory_search` at its 500 hard ceiling over a
//      wide fused pool stays inside both.
//   2. Step 5.8 sub-span window budget (finding 49b0b7cd7): a pool whose
//      windows exceed the CorpusKit `SubSpanBudget` records the stage
//      `subSpan.budget` and the hits the budget left unscored carry the
//      explainer token `subSpan:budget`.
//
// Tests:
//   1. shingle_view_stays_inside_the_budget_at_the_public_limit_ceiling —
//      600 entropy bodies of 5,000 scalars (a limit-500 pool): every body has a set,
//      no set exceeds the even share of the budget, and the view reports
//      that the budget shortened the prefix.
//   2. shingle_view_within_budget_is_complete — small bodies: every body has
//      a set, no truncation, a missing or empty body has none.
//   2b. cap_alone_is_not_a_truncation — 200 bodies over the cap fit the
//      budget at the full cap: sets of cap - 2 shingles, no truncation; 300
//      such bodies share the budget below the cap: truncation reported.
//   3. recall_records_the_sub_span_budget_stage — 20 ingested records of
//      16,000 scalars (about 1,700 sub-span windows), full hydration, limit
//      20: the stage `subSpan.budget` is recorded and the unscored hits carry
//      `subSpan:budget`.
//   4. wide_pool_records_the_mmr_budget_stage — 300 captured drawers over the
//      body cap with tiny shingle sets (the locus lane supplies 256 of them,
//      its frontier ceiling, at limit 300), full hydration: 256 × cap exceeds
//      the budget, so the stage `unionBest.mmrBudget` is recorded.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    union_best_mmr_shingles, GLKRecallMode, GLKRecallRequest, GLKRecallScoring,
    RecallFallbackPolicy, RecallOrigin, UNION_BEST_MMR_BODY_CAP_SCALARS,
    UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;
const QUERY: &str = "quarterly budget review meeting notes finance team";

/// A body of about `scalars` scalars that opens with the query terms and
/// continues with filler drawn from a sixteen-word vocabulary. The window
/// count grows with the token count, so the sub-span budget sees a long
/// record, while the BM25 posting lists stay small (the Swift twin's
/// in-memory row store scans its rows on every upsert).
fn long_body(index: usize, scalars: usize) -> String {
    const FILLER: [&str; 16] = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    ];
    let mut body = format!("{QUERY} item {index}");
    let mut word = 0usize;
    while body.chars().count() < scalars {
        body.push(' ');
        body.push_str(FILLER[word % FILLER.len()]);
        word += 1;
    }
    body
}

/// A body of `scalars` scalars drawn from a 62-symbol alphabet by a linear
/// congruential generator seeded by `index`: nearly every 3-gram is distinct,
/// so the size of its shingle set reads back the prefix that was shingled
/// (a 16-word filler body saturates at about 150 distinct 3-grams).
fn entropy_body(index: usize, scalars: usize) -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15 ^ (index as u64 + 1);
    (0..scalars)
        .map(|_| {
            state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            ALPHABET[((state >> 33) % ALPHABET.len() as u64) as usize] as char
        })
        .collect()
}

#[test]
fn shingle_view_stays_inside_the_budget_at_the_public_limit_ceiling() {
    let bodies: Vec<String> = (0..600).map(|i| entropy_body(i, 5_000)).collect();
    let refs: Vec<Option<&str>> = bodies.iter().map(|b| Some(b.as_str())).collect();

    let (sets, truncated) = union_best_mmr_shingles(&refs);
    assert!(truncated, "600 over-cap bodies share the budget below the cap");
    let with_sets = sets.iter().filter(|s| s.is_some()).count();
    assert_eq!(with_sets, 600, "every body gets a set: the budget shortens, it never excludes");
    // The even share: 1,000,000 / 600 = 1,666 scalars each, at most 1,664
    // 3-grams per set, so the aggregate shingled scalars stay inside the budget.
    let share = UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS / 600;
    assert!(share < UNION_BEST_MMR_BODY_CAP_SCALARS, "the share is below the cap for this pool");
    let max_set = sets.iter().flatten().map(|s| s.len()).max().unwrap_or(0);
    assert!(max_set <= share - 2, "a 3-gram set over an even-share prefix holds at most share - 2 shingles; got {max_set}");
    assert!(600 * share <= UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS, "shingled scalars exceed the budget");
    // The sets are one measure: every body was shingled over the whole share
    // (nearly every 3-gram of an entropy body is distinct), so no slot is a
    // free rider.
    let min_set = sets.iter().flatten().map(|s| s.len()).min().unwrap_or(0);
    assert!(min_set > share * 9 / 10, "every set covers its prefix; smallest {min_set} for share {share}");
}

#[test]
fn shingle_view_within_budget_is_complete() {
    let bodies = ["alpha beta gamma", "", "delta epsilon"];
    let refs: Vec<Option<&str>> = vec![Some(bodies[0]), Some(bodies[1]), Some(bodies[2]), None];
    let (sets, truncated) = union_best_mmr_shingles(&refs);
    assert!(!truncated);
    assert!(sets[0].is_some());
    assert!(sets[1].is_none(), "an empty body builds no set");
    assert!(sets[2].is_some());
    assert!(sets[3].is_none(), "a slot without a body builds no set");
}

#[test]
fn cap_alone_is_not_a_truncation() {
    // 200 over-cap bodies: 200 × 4,096 = 819,200 fits the budget, so every
    // body is cut by the cap alone (the measure, not a truncation).
    let bodies: Vec<String> = (0..200).map(|i| entropy_body(i, 5_000)).collect();
    let refs: Vec<Option<&str>> = bodies.iter().map(|b| Some(b.as_str())).collect();
    let (sets, truncated) = union_best_mmr_shingles(&refs);
    assert!(!truncated, "the cap alone shortening a body is not a budget truncation");
    let max_set = sets.iter().flatten().map(|s| s.len()).max().unwrap_or(0);
    assert!(max_set <= UNION_BEST_MMR_BODY_CAP_SCALARS - 2, "a full-cap set holds at most cap - 2 shingles; got {max_set}");
    assert!(max_set > UNION_BEST_MMR_BODY_CAP_SCALARS * 9 / 10, "a full-cap prefix was shingled; got {max_set}");

    // 300 over-cap bodies: 300 × 4,096 exceeds the budget, so the share drops
    // to 3,333 scalars and the view reports it.
    let bodies: Vec<String> = (0..300).map(|i| entropy_body(i, 5_000)).collect();
    let refs: Vec<Option<&str>> = bodies.iter().map(|b| Some(b.as_str())).collect();
    let (sets, truncated) = union_best_mmr_shingles(&refs);
    assert!(truncated, "300 over-cap bodies share the budget below the cap");
    let share = UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS / 300;
    let max_set = sets.iter().flatten().map(|s| s.len()).max().unwrap_or(0);
    assert!(max_set <= share - 2, "sets follow the share; got {max_set} for share {share}");
    assert!(max_set > share * 9 / 10, "the share was shingled whole; got {max_set} for share {share}");
}

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// An estate for the end-to-end stage tests: `count` drawers whose bodies
/// `body(i)` gives, the first `ingested` of them also in a standalone corpus
/// registered on the estate.
fn open_estate(
    count: usize,
    ingested: usize,
    body: impl Fn(usize) -> String,
) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord
        .open(store, OwnerCredentials::new("budget-stages"), 0, 100)
        .expect("open estate");
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
            .expect("CorpusContentEngine::standalone_on"),
    );
    for i in 0..count {
        let text = body(i);
        let frame = CaptureFrame::new(
            &text, CaptureChannel::Typed, "budget-stages", LatticeAnchor::udc("000"),
            "budget-stages", "test-model-v1");
        let ts = NOW + i as i64;
        let drawer = coord.capture(&h, frame, ts).expect("capture");
        if i < ingested {
            corpus.ingest(&text, &drawer.id, ts).expect("corpus ingest");
        }
    }
    coord.register_corpus(&h, corpus);
    (coord, h)
}

fn full_request(limit: usize) -> GLKRecallRequest {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    GLKRecallRequest::new(
        frame, GLKRecallMode::UnionBest, GLKRecallScoring::MatrixAware, limit,
        RecallFallbackPolicy::FailClosed, RecallOrigin::Internal,
    ).with_query_text(QUERY)
}

#[test]
fn recall_records_the_sub_span_budget_stage() {
    // 20 records of 16,000 scalars (about 2,000 tokens, about 85 sub-span
    // windows each under the 16 KiB record cap): their 1,700-odd windows
    // exceed the 1,024-window budget. Every drawer is returned at limit 20,
    // so the unscored ones are in the hits.
    let count = 20usize;
    let (coord, h) = open_estate(count, count, |i| long_body(i, 16_000));
    let result = coord.recall_scored(&h, full_request(count), NOW + 1_000).expect("recall_scored");
    assert!(!result.hits.is_empty(), "the bounded recall still answers");
    assert!(result.degraded_stages.iter().any(|s| s == "subSpan.budget"),
        "the sub-span window budget truncated on about 1,700 windows; stages: {:?}", result.degraded_stages);
    let flagged = result.hits.iter().filter(|hit| {
        hit.explanation.iter().any(|line| line.starts_with("score:") && line.contains(" subSpan:budget"))
    }).count();
    assert!(flagged > 0, "every candidate is returned at limit {count}, so the unscored ones carry the explainer token");
    assert!(flagged < result.hits.len(), "the budget scored the first candidates");
}

#[test]
fn wide_pool_records_the_mmr_budget_stage() {
    // 300 bodies over the body cap: the locus lane supplies 256 of them, its
    // frontier ceiling, at limit 300, and 256 × 4,096 exceeds the 1,000,000
    // aggregate budget, so the share drops below the cap. The bodies repeat
    // three characters so their shingle sets are tiny and the step 10
    // intersections cost nothing: the stage depends on the scalars shingled,
    // not on the sets' sizes. No corpus content, so no BM25 supply and no
    // sub-span windows.
    let count = 300usize;
    let (coord, h) = open_estate(count, 0, |i| format!("{}item {i}", "ab ".repeat(1_400)));
    let result = coord.recall_scored(&h, full_request(count), NOW + 1_000).expect("recall_scored");
    assert!(!result.hits.is_empty(), "the bounded recall still answers");
    assert!(result.degraded_stages.iter().any(|s| s == "unionBest.mmrBudget"),
        "the shingle budget shortened the prefix on 256 over-cap bodies; stages: {:?}", result.degraded_stages);
    assert!(!result.degraded_stages.iter().any(|s| s == "subSpan.budget"),
        "no corpus record was long enough to spend the window budget; stages: {:?}", result.degraded_stages);
}
