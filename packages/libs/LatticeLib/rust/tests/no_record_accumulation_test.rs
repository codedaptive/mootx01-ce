// no_record_accumulation_test.rs — Pool-accumulation non-recording gate
// for the secfix/fdc-pool fix.
//
// This file is intentionally a SINGLE-TEST binary so SHARED_NOVEL_CACHE
// starts at 0 and no other tests run concurrently in this process. That
// isolation lets us assert that encode_anchor_no_record does NOT increment
// the count, without racing against parallel recording tests.
//
// MUST remain a single-test file. Do NOT add other tests here.
//
// The invariant: Fdc::encode_anchor_no_record(user_content) must not change
// SHARED_NOVEL_CACHE.count(), because `build_encoder_bag_no_record` calls
// `WordClassTableCache::word_class_no_record` which skips the
// `SHARED_NOVEL_CACHE.record` call for novel tokens.
//
// This is the core security property of the fix: user-memory content
// classified at the GLK capture seam (intake.rs `capture_with_mode`) never
// accumulates novel tokens into the pool pipeline, and therefore never
// flushes plaintext tokens to LATTICE_POOL_DIR, even for rejected or
// empty-room captures where classification runs before the write.

use lattice_lib::{Fdc, SHARED_NOVEL_CACHE};

/// Non-recording gate (secfix/fdc-pool): encode_anchor_no_record must NOT
/// accumulate novel tokens into SHARED_NOVEL_CACHE.
///
/// Text contains tokens that will be novel (not in any shipped word-class
/// table), ensuring the HMM is exercised and its non-recording variant must
/// skip the cache.record call. In this single-test binary, SHARED_NOVEL_CACHE
/// starts at 0 (or is initialized to 0 by the bundle init inside
/// encode_anchor_no_record). The count MUST be 0 after the call.
#[test]
fn encode_anchor_no_record_does_not_accumulate_in_shared_cache() {
    if !Fdc::is_available() {
        return;
    }

    // Text with novel tokens: "zorbfdc9x8q7" and "plonkrivate" are not in
    // any shipped word-class table, so the HMM classifies them. The
    // non-recording path must not register those classifications.
    let user_content = "user private secret memo zorbfdc9x8q7 concerning plonkrivate history";

    // count() before first encoding call. In this single-test binary, the
    // cache may not yet be initialized (OnceLock not yet set); treat that
    // as count 0.
    let before = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);

    _ = Fdc::encode_anchor_no_record(user_content);

    // Cache is now initialized (bundle init fires inside encode_anchor_no_record).
    let after = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);

    assert_eq!(
        after, before,
        "encode_anchor_no_record must not increment SHARED_NOVEL_CACHE (secfix/fdc-pool); \
         before={before} after={after}. If after>before, word_class_no_record is still \
         calling SHARED_NOVEL_CACHE.record — check WordClassTableCache::word_class_no_record \
         in word_class_table.rs."
    );
}
