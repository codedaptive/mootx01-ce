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
// Engine resolution is `adornment_lib::invoke_adornment_command`: the
// resident gold-miner engine installed at serve start wins; otherwise the
// MOOT_MINT_CMD subprocess seam; otherwise None per prompt — and
// map-reduce then covers the pair with the deterministic mechanical
// fallback.
//
// Provenance guard (codex finding 17, GENIUSLOCUSKIT_SPEC 2.7.0 § 16.1):
// the process has ONE engine, but the debt batch carries one pair per
// ACTIVE minter, and registration never retoggles activation — after an
// upgrade or a `MOOT_MINT_MODEL` switch the stale identity stays active
// beside the selected one. Minting every pair through the one engine and
// persisting under `pair.minter.id` stamped the engine's text with a
// minter it never was. The pass therefore persists a pair only when the
// pair's minter id EQUALS the resolved engine's identity; every other pair
// is counted skipped and stays in debt. When no engine is installed the
// subprocess seam carries no identity and the pass runs unguarded — the
// harness owns the active set exactly. Same rule as the Swift pass
// (`AdornmentPass.run`), where the harness `CommandEngine` is the
// identity-less case.
//
// Determinism: this pass calls no clock. Timestamps on adornment rows are
// the store's concern; the caller owns cadence.

use adornment_lib::{
    ADORNMENT_CHUNK_THRESHOLD, ADORNMENT_MAX_LENGTH, StoredAdornment,
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
    /// Pairs skipped because the drawer's content was empty, or because
    /// the pair's minter id is not the identity of the installed engine
    /// (provenance guard). Skipped pairs stay in debt.
    pub skipped_pairs: usize,
}

/// Default batch size per pass invocation — counts (drawer, minter) PAIRS,
/// not drawers. Mirrors Swift `AdornmentPass.defaultBatchSize`.
pub const DEFAULT_BATCH_SIZE: usize = 50;

/// Hard ceiling on `batch_size` for one pass invocation, in (drawer,
/// minter) pairs. Mirrors Swift `ADORNMENT_PASS_MAX_BATCH_SIZE`.
///
/// One pass runs synchronously inside one MCP call and materializes every
/// fetched drawer's content before minting, so the batch bounds both that
/// call's wall-clock and its memory. The ceiling holds for every caller —
/// `run_adornment_pass` clamps regardless of who requested the batch, so
/// a caller-supplied count can never turn one call into an estate-wide
/// scan. Larger fleets are paged by repeated calls (the benchmark mint
/// driver loops the dark tool to debt exhaustion).
pub const ADORNMENT_PASS_MAX_BATCH_SIZE: usize = 5000;

/// Clamp a requested batch size to `ADORNMENT_PASS_MAX_BATCH_SIZE`.
///
/// Clamps rather than rejects: the mint driver passes large counts and
/// expects the pass to page, not fail. Same literal behavior as Swift
/// `AdornmentPass.clampedBatchSize`.
pub fn clamped_batch_size(requested: usize) -> usize {
    requested.min(ADORNMENT_PASS_MAX_BATCH_SIZE)
}

/// Run one adornment pass against the estate.
///
/// `batch_size` is clamped to `ADORNMENT_PASS_MAX_BATCH_SIZE` here, at the
/// entry point, so no caller can exceed the ceiling.
///
/// `max_adornment_length` is `None` for the product ceiling
/// (`ADORNMENT_MAX_LENGTH`); a harness audition may pass an override —
/// the ceiling is resolved at this single point, mirroring the Swift
/// `GeniusLocusKit.runAdornmentPass` entry.
///
/// Provenance guard: the installed engine's identity
/// (`gold_miner::engine_identity`, `None` when no engine is installed) is
/// resolved once per pass; a pair whose minter id differs from it is
/// counted skipped and never minted or persisted. With no engine the pass
/// runs unguarded (the MOOT_MINT_CMD subprocess seam has no identity).
pub fn run_adornment_pass(
    store: &dyn locus_kit::drawer_store::DrawerStore,
    batch_size: usize,
    max_adornment_length: Option<usize>,
) -> Result<AdornmentPassResult, String> {
    run_adornment_pass_with(
        store,
        batch_size,
        max_adornment_length,
        adornment_lib::gold_miner::engine_identity(),
        // Full engine chain, twin of the Swift pass: the resident
        // gold-miner engine wins when installed; otherwise the
        // MOOT_MINT_CMD subprocess seam (the harness audition
        // vehicle) mints; None only when both are absent or fail.
        // invoke_adornment_command owns the trim and the ceiling.
        // Calling gold_miner::mint_one directly here skipped the
        // subprocess seam entirely — a serve with MOOT_MINT_CMD set
        // and no resident engine minted mechanical fallback for
        // every pair (2026-08-30, rust wing auditions).
        |prompt, length| adornment_lib::invoke_adornment_command(prompt, length),
    )
}

/// The pass body behind `run_adornment_pass`, with the two process-global
/// seams — the engine identity and the per-prompt mint — passed in so
/// tests drive the guard and the generator without touching the
/// process-wide gold-miner slot. `engine_identity` is the identity the
/// provenance guard compares every pair's minter id against; `None`
/// disables the guard. `mint` receives (prompt, max_length).
fn run_adornment_pass_with(
    store: &dyn locus_kit::drawer_store::DrawerStore,
    batch_size: usize,
    max_adornment_length: Option<usize>,
    engine_identity: Option<String>,
    mint: impl Fn(&str, usize) -> Option<String>,
) -> Result<AdornmentPassResult, String> {
    let length = max_adornment_length.unwrap_or(ADORNMENT_MAX_LENGTH);
    let pairs = store
        .adornment_debt_batch(clamped_batch_size(batch_size), None)
        .map_err(|e| format!("adornment_debt_batch: {e:?}"))?;

    let mut adorned = 0usize;
    let mut failed = 0usize;
    let mut skipped = 0usize;
    // Minter ids already reported by the provenance guard this pass: the
    // warning fires once per distinct stale minter, not once per pair.
    let mut reported_mismatch: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();

    for pair in pairs {
        let drawer = &pair.drawer;
        let minter = &pair.minter;

        // Provenance guard: the engine's text is persisted only under the
        // engine's own minter identity. A stale active minter (an earlier
        // recipe version, a switched model) keeps its debt untouched —
        // deactivating it is the operator's ruling, never the pass's.
        if let Some(identity) = engine_identity.as_deref() {
            if minter.id != identity {
                skipped += 1;
                if reported_mismatch.insert(minter.id.clone()) {
                    eprintln!(
                        "adornment_pass: skipping active minter {} — the installed engine is {identity}; deactivate the stale minter to clear its debt",
                        minter.id
                    );
                }
                continue;
            }
        }

        // Content guard: an empty-content drawer cannot produce a
        // meaningful adornment. Defensive — the debt predicate already
        // excludes empty-content rows.
        if drawer.content.is_empty() {
            skipped += 1;
            continue;
        }

        // Event date threads through so relative references are calculable
        // (operator ruling 2026-08-25). Drawer event_time is epoch millis.
        let event_date = iso8601_from_millis(drawer.event_time);
        let text = mint_adornment_map_reduce(
            &drawer.content,
            Some(&event_date),
            length,
            ADORNMENT_CHUNK_THRESHOLD,
            // Width note (Swift-pass parity): the Swift pass fans pairs
            // out to the engine's declared mint width
            // (GoldMinerEngine.maxConcurrentMints — Apple's inference
            // service pipelines concurrent requests). Every Rust engine
            // is width-1 (one resident GGUF context, one subprocess
            // pipe), so this serial loop IS the width-bounded behavior;
            // a width seam lands here with the first >1 Rust engine.
            //
            // Multi-model note (GENIUSLOCUSKIT_SPEC 2.4.0 / 2.7.0): the
            // Swift pass routes each pair's generation by minter id
            // through a developer-only, compile-gated engine registry
            // (MOOTX01_MULTI_MODEL). The Rust port has one engine seam
            // (the adornment command), so every minter resolves to it —
            // which is exactly why the provenance guard above admits
            // only the pair whose minter id IS the installed engine's
            // identity. A per-minter registry lands here with the first
            // second Rust engine; the guard then compares against the
            // engine resolved for the pair.
            |prompt| mint(prompt, length),
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
    /// (never-nil-for-non-blank, operator ruling 2026-08-27), so the pass
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

    /// Minter descriptor for the provenance-guard tests: two versions of
    /// one recipe, both active — the shape an estate carries after the
    /// p1 → p2 default upgrade, because registration never retoggles an
    /// existing row's activation.
    fn active_minter(id: &str, version: &str) -> AdornmentMinterDescriptor {
        AdornmentMinterDescriptor {
            id: id.to_string(),
            name: id.to_string(),
            family: "quantized".to_string(),
            model_id: "qwen2-0.5b-q4km".to_string(),
            model_version: version.to_string(),
            prompt_digest: format!("digest-{version}"),
            parameters: std::collections::BTreeMap::new(),
            is_active: true,
        }
    }

    /// Provenance guard (codex finding 17): two active minters — the
    /// installed engine's identity and a stale one — over one drawer. The
    /// pass adorns exactly the engine's pair, skips the stale pair, and
    /// the stored row carries the engine's minter id only. Literal twin
    /// of the Swift `AdornmentPassMinterGroupingTests` guard test:
    /// (adorned, failed, skipped) == (1, 0, 1).
    #[test]
    fn pass_persists_only_under_the_engine_identity() {
        let store = store_with_one_drawer();
        store
            .register_adornment_minter(&active_minter("qwen2-0.5b-q4km-p1-s1", "p1-s1"))
            .expect("register p1");
        store
            .register_adornment_minter(&active_minter("qwen2-0.5b-q4km-p2-s1", "p2-s1"))
            .expect("register p2");

        let result = run_adornment_pass_with(
            &store,
            DEFAULT_BATCH_SIZE,
            None,
            Some("qwen2-0.5b-q4km-p2-s1".to_string()),
            |_prompt, _length| Some("engine claim".to_string()),
        )
        .expect("pass");
        assert_eq!(
            (result.adorned_pairs, result.failed_pairs, result.skipped_pairs),
            (1, 0, 1)
        );

        let rows = store.adornments(DRAWER_ID).expect("adornments");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].minter_id, "qwen2-0.5b-q4km-p2-s1");
        assert_eq!(rows[0].text, "engine claim");

        // The stale pair stays in debt: a second pass skips it again and
        // adorns nothing new. Clearing it is the operator's deactivation.
        let again = run_adornment_pass_with(
            &store,
            DEFAULT_BATCH_SIZE,
            None,
            Some("qwen2-0.5b-q4km-p2-s1".to_string()),
            |_prompt, _length| Some("engine claim".to_string()),
        )
        .expect("pass 2");
        assert_eq!(
            (again.adorned_pairs, again.failed_pairs, again.skipped_pairs),
            (0, 0, 1)
        );
    }

    /// No installed engine = no identity = no guard: the subprocess seam
    /// (or the mechanical fallback) mints every active minter's pair, so
    /// the harness owns the active set exactly. Twin of the Swift
    /// `CommandEngine` (identity-less) rule.
    #[test]
    fn pass_without_engine_identity_mints_every_active_minter() {
        let store = store_with_one_drawer();
        store
            .register_adornment_minter(&active_minter("qwen2-0.5b-q4km-p1-s1", "p1-s1"))
            .expect("register p1");
        store
            .register_adornment_minter(&active_minter("qwen2-0.5b-q4km-p2-s1", "p2-s1"))
            .expect("register p2");

        let result = run_adornment_pass_with(
            &store,
            DEFAULT_BATCH_SIZE,
            None,
            None,
            |_prompt, _length| Some("seam claim".to_string()),
        )
        .expect("pass");
        assert_eq!(
            (result.adorned_pairs, result.failed_pairs, result.skipped_pairs),
            (2, 0, 0)
        );
        let mut minters: Vec<String> = store
            .adornments(DRAWER_ID)
            .expect("adornments")
            .into_iter()
            .map(|r| r.minter_id)
            .collect();
        minters.sort();
        assert_eq!(minters, vec!["qwen2-0.5b-q4km-p1-s1", "qwen2-0.5b-q4km-p2-s1"]);
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

    /// Literal pin of the batch ceiling, shared with the Swift port: a
    /// requested 999_999 clamps to ADORNMENT_PASS_MAX_BATCH_SIZE (5000);
    /// the default and any in-range request pass through unchanged.
    #[test]
    fn clamped_batch_size_pins_ceiling() {
        assert_eq!(ADORNMENT_PASS_MAX_BATCH_SIZE, 5000);
        assert_eq!(clamped_batch_size(999_999), 5000);
        assert_eq!(clamped_batch_size(DEFAULT_BATCH_SIZE), 50);
        assert_eq!(clamped_batch_size(5000), 5000);
        assert_eq!(clamped_batch_size(0), 0);
    }

    /// Store that records the limit the pass asked for, so the test
    /// witnesses the ceiling at the storage seam — not just the helper.
    struct LimitRecordingStore {
        seen_limit: std::sync::atomic::AtomicUsize,
    }

    impl locus_kit::drawer_store::DrawerStore for LimitRecordingStore {
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
            self.seen_limit.store(limit, std::sync::atomic::Ordering::SeqCst);
            Ok(Vec::new())
        }
        fn put_adornment(
            &self,
            _adornment: &adornment_lib::StoredAdornment,
        ) -> Result<usize, locus_kit::error::LocusKitError> {
            Err(locus_kit::error::LocusKitError::DatabaseUnavailable(
                "stub".to_string(),
            ))
        }
    }

    /// The entry point enforces the ceiling for every caller: a 999_999
    /// request reaches the store as exactly ADORNMENT_PASS_MAX_BATCH_SIZE.
    #[test]
    fn run_adornment_pass_clamps_batch_at_the_store_seam() {
        let store = LimitRecordingStore {
            seen_limit: std::sync::atomic::AtomicUsize::new(0),
        };
        let r = run_adornment_pass(&store, 999_999, None).expect("pass");
        assert_eq!((r.adorned_pairs, r.failed_pairs, r.skipped_pairs), (0, 0, 0));
        assert_eq!(
            store.seen_limit.load(std::sync::atomic::Ordering::SeqCst),
            ADORNMENT_PASS_MAX_BATCH_SIZE
        );
    }
}
