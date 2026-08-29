// brain/adornment_pass.rs — Rust mirror of `AdornmentPass.swift`.
//
// Dream-time adornment-minting pass (GENIUSLOCUSKIT_SPEC 2.0.0 § 16.1).
// A single pass fetches up to `batch_size` (live Drawer, active minter)
// pairs without an `adornments` row, mints each through the resident
// gold-miner engine via `adornment_lib::mint_adornment_map_reduce` (which
// guarantees the mechanical fallback — a non-blank drawer always mints),
// and writes `StoredAdornment(drawer_id, minter_id, text)` through the
// store's `put_adornment`.
//
// Failure isolation mirrors the Swift pass exactly: a failed pair leaves
// only THAT pair missing; the minter is never disabled; a repeated pass
// retries. The (drawer_id, minter_id) composite key structurally prevents
// one minter's row from overwriting another's.
//
// Engine resolution is the resident gold miner (`gold_miner::mint_one`):
// the engine installed at serve start (the candle quantized default when
// its GGUF is present), else None per prompt — and map-reduce then covers
// the pair with the deterministic mechanical fallback.
//
// Determinism: this pass calls no clock. Timestamps on adornment rows are
// the store's concern; the caller owns cadence.

use adornment_lib::{
    ADORNMENT_CHUNK_THRESHOLD, ADORNMENT_MAX_LENGTH, StoredAdornment, gold_miner,
    mint_adornment_map_reduce,
};
use locus_kit::tunnel_review_ledger::iso8601_from_millis;

/// Outcome of one `run_adornment_pass` invocation, counting
/// (drawer, minter) pairs. Mirrors Swift `AdornmentPassResult`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdornmentPassResult {
    /// Pairs for which a `StoredAdornment` row was successfully written.
    pub adorned_pairs: usize,
    /// Pairs where minting failed or the write tore; retried on the next
    /// pass. The minter is never disabled on failure.
    pub failed_pairs: usize,
    /// Pairs skipped because the drawer's content was empty.
    pub skipped_pairs: usize,
}

/// Batch ceiling per pass invocation — counts (drawer, minter) PAIRS,
/// not drawers. Mirrors Swift `AdornmentPass.defaultBatchSize`.
pub const DEFAULT_BATCH_SIZE: usize = 50;

/// Run one adornment pass against the estate.
///
/// `max_adornment_length` is `None` for the product ceiling
/// (`ADORNMENT_MAX_LENGTH`); a harness audition may pass an override —
/// the ceiling is resolved at this single point, mirroring the Swift
/// `GeniusLocusKit.runAdornmentPass` entry.
pub fn run_adornment_pass(
    store: &dyn locus_kit::drawer_store::DrawerStore,
    batch_size: usize,
    max_adornment_length: Option<usize>,
) -> Result<AdornmentPassResult, String> {
    let length = max_adornment_length.unwrap_or(ADORNMENT_MAX_LENGTH);
    let pairs = store
        .adornment_debt_batch(batch_size, None)
        .map_err(|e| format!("adornment_debt_batch: {e:?}"))?;

    let mut adorned = 0usize;
    let mut failed = 0usize;
    let mut skipped = 0usize;

    for pair in pairs {
        let drawer = &pair.drawer;
        let minter = &pair.minter;

        // Content guard: an empty-content drawer cannot produce a
        // meaningful adornment. Defensive — the debt predicate already
        // excludes empty-content rows.
        if drawer.content.is_empty() {
            skipped += 1;
            continue;
        }

        // Event date threads through so relative references are calculable
        // (Bob ruling 2026-08-25). Drawer event_time is epoch millis.
        let event_date = iso8601_from_millis(drawer.event_time);
        let text = mint_adornment_map_reduce(
            &drawer.content,
            Some(&event_date),
            length,
            ADORNMENT_CHUNK_THRESHOLD,
            |prompt| {
                gold_miner::mint_one(prompt).and_then(|raw| {
                    // Mechanical truncation at the resolved ceiling:
                    // engines return raw text; the seam owns the ceiling.
                    let candidate = raw.trim();
                    if candidate.is_empty() {
                        None
                    } else {
                        Some(candidate.chars().take(length).collect())
                    }
                })
            },
        );

        let Some(text) = text else {
            // map_reduce returns None only when the content itself
            // normalizes to empty — count failed and retry next pass.
            failed += 1;
            continue;
        };

        match store.put_adornment(&StoredAdornment {
            drawer_id: drawer.id.clone(),
            minter_id: minter.id.clone(),
            text,
        }) {
            Ok(1) => adorned += 1,
            // Torn write: the drawer was expunged between the debt fetch
            // and the write. Not a hard error — the pair vanishes from
            // debt on the next scan.
            Ok(_) => failed += 1,
            // Per-pair failure isolation: a persistence error on one pair
            // never disables the minter or aborts the pass.
            Err(_) => failed += 1,
        }
    }

    Ok(AdornmentPassResult { adorned_pairs: adorned, failed_pairs: failed, skipped_pairs: skipped })
}

#[cfg(test)]
mod tests {
    use super::*;
    use adornment_lib::AdornmentMinterDescriptor;
    use locus_kit::drawer::Drawer;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;

    const NOW: i64 = 1_700_000_000;
    const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";

    /// Deterministic drawer UUID for the single test row.
    const DRAWER_ID: &str = "11111111-1111-4111-8111-111111111111";

    /// One in-memory store holding one non-blank drawer.
    fn store_with_one_drawer() -> InMemoryDrawerStore {
        let store = InMemoryDrawerStore::new(NOW, None).expect("store init");
        let mut d = Drawer::new(
            DRAWER_ID,
            "Priya flew to Paris on 2023-05-29 for the conference.",
            TEST_PARENT,
            "bilby",
            NOW,
            "test-v1",
        );
        d.udc_code = "001".to_string();
        store.add_drawer(&d, NOW).expect("add_drawer");
        store
    }

    /// End-to-end pass over an in-memory estate with no engine installed:
    /// the mechanical fallback guarantees a non-blank drawer still mints
    /// (never-nil-for-non-blank, Bob ruling 2026-08-27), so the pass
    /// adorns every debt pair deterministically, and a second pass finds
    /// no debt. Twin of the Swift behavior through AdornmentPass.run's
    /// default GoldMiner resolver.
    #[test]
    fn pass_adorns_debt_pairs_via_mechanical_fallback() {
        let store = store_with_one_drawer();
        let minter = AdornmentMinterDescriptor {
            id: "qwen2-0.5b-q4km-p1-s1".to_string(),
            name: "qwen2-0.5b-q4km-p1-s1".to_string(),
            family: "quantized".to_string(),
            model_id: "qwen2-0.5b-q4km".to_string(),
            model_version: "p1-s1".to_string(),
            prompt_digest: "test".to_string(),
            parameters: std::collections::BTreeMap::new(),
            is_active: true,
        };
        store.register_adornment_minter(&minter).expect("register");

        let result =
            run_adornment_pass(&store, DEFAULT_BATCH_SIZE, None).expect("pass");
        assert_eq!(result.adorned_pairs, 1);
        assert_eq!(result.failed_pairs, 0);
        assert_eq!(result.skipped_pairs, 0);

        // The minted row is the mechanical claim line over the content.
        let rows = store.adornments(DRAWER_ID).expect("adornments");
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].text.is_empty());

        // A second pass finds no debt: idempotent by construction.
        let again =
            run_adornment_pass(&store, DEFAULT_BATCH_SIZE, None).expect("pass 2");
        assert_eq!(again.adorned_pairs, 0);
        assert_eq!(again.failed_pairs, 0);
    }

    // ── Stub-store coverage (Adams DEFAULT-MINT-01 W4): torn write, per-pair
    // failure isolation, empty-content skip. The stub overrides only the two
    // verbs the pass uses; everything else keeps the trait defaults.

    struct StubStore {
        pairs: Vec<locus_kit::drawer_store::AdornmentDebt>,
        /// drawer ids whose put_adornment errors (failure isolation).
        error_ids: Vec<String>,
        /// drawer ids whose put_adornment reports a torn write (0 rows).
        torn_ids: Vec<String>,
    }

    impl locus_kit::drawer_store::DrawerStore for StubStore {
        // Required trait items the pass never touches — hard errors so any
        // accidental use fails the test loudly instead of faking state.
        fn read_manifest(
            &self,
        ) -> Result<locus_kit::manifest::ManifestValues, locus_kit::error::LocusKitError>
        {
            Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                "stub".to_string(),
            ))
        }
        fn set_meta(&self, _key: &str, _value: &str) -> Result<(), locus_kit::error::LocusKitError> {
            Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                "stub".to_string(),
            ))
        }
        fn all_drawers(&self) -> Result<Vec<Drawer>, locus_kit::error::LocusKitError> {
            Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                "stub".to_string(),
            ))
        }
        fn room_level_fingerprints(
            &self,
        ) -> Result<
            Vec<locus_kit::container_fingerprint_store::RoomLevelEntry>,
            locus_kit::error::LocusKitError,
        > {
            Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                "stub".to_string(),
            ))
        }

        fn adornment_debt_batch(
            &self,
            limit: usize,
            _after_drawer_id: Option<&str>,
        ) -> Result<Vec<locus_kit::drawer_store::AdornmentDebt>, locus_kit::error::LocusKitError>
        {
            Ok(self.pairs.iter().take(limit).cloned().collect())
        }

        fn put_adornment(
            &self,
            adornment: &adornment_lib::StoredAdornment,
        ) -> Result<usize, locus_kit::error::LocusKitError> {
            if self.error_ids.iter().any(|id| id == &adornment.drawer_id) {
                return Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                    "stub write failure".to_string(),
                ));
            }
            if self.torn_ids.iter().any(|id| id == &adornment.drawer_id) {
                return Ok(0);
            }
            Ok(1)
        }
    }

    fn debt(drawer_id: &str, content: &str) -> locus_kit::drawer_store::AdornmentDebt {
        let mut d = Drawer::new(drawer_id, content, TEST_PARENT, "bilby", NOW, "test-v1");
        d.udc_code = "001".to_string();
        locus_kit::drawer_store::AdornmentDebt {
            drawer: d,
            minter: adornment_lib::AdornmentMinterDescriptor {
                id: "m-1".to_string(),
                name: "m-1".to_string(),
                family: "test".to_string(),
                model_id: "m".to_string(),
                model_version: "p1-s1".to_string(),
                prompt_digest: "d".to_string(),
                parameters: std::collections::BTreeMap::new(),
                is_active: true,
            },
        }
    }

    /// An empty-content drawer is skipped — counted, never minted, never
    /// a failure. Twin of the Swift content guard.
    #[test]
    fn empty_content_pair_is_skipped() {
        let store = StubStore {
            pairs: vec![debt("11111111-1111-4111-8111-000000000001", "")],
            error_ids: vec![],
            torn_ids: vec![],
        };
        let r = run_adornment_pass(&store, DEFAULT_BATCH_SIZE, None).expect("pass");
        assert_eq!((r.adorned_pairs, r.failed_pairs, r.skipped_pairs), (0, 0, 1));
    }

    /// A persistence error on one pair fails ONLY that pair — the pass
    /// continues and adorns the rest (per-pair failure isolation; the
    /// minter is never disabled).
    #[test]
    fn write_error_isolates_to_one_pair() {
        let store = StubStore {
            pairs: vec![
                debt("11111111-1111-4111-8111-000000000001", "first drawer body"),
                debt("11111111-1111-4111-8111-000000000002", "second drawer body"),
            ],
            error_ids: vec!["11111111-1111-4111-8111-000000000001".to_string()],
            torn_ids: vec![],
        };
        let r = run_adornment_pass(&store, DEFAULT_BATCH_SIZE, None).expect("pass");
        assert_eq!((r.adorned_pairs, r.failed_pairs, r.skipped_pairs), (1, 1, 0));
    }

    /// A torn write (0 rows — drawer expunged between the debt fetch and
    /// the write) counts as failed, not adorned, and never aborts the pass.
    #[test]
    fn torn_write_counts_failed_and_continues() {
        let store = StubStore {
            pairs: vec![
                debt("11111111-1111-4111-8111-000000000001", "torn drawer body"),
                debt("11111111-1111-4111-8111-000000000002", "healthy drawer body"),
            ],
            error_ids: vec![],
            torn_ids: vec!["11111111-1111-4111-8111-000000000001".to_string()],
        };
        let r = run_adornment_pass(&store, DEFAULT_BATCH_SIZE, None).expect("pass");
        assert_eq!((r.adorned_pairs, r.failed_pairs, r.skipped_pairs), (1, 1, 0));
    }
}
