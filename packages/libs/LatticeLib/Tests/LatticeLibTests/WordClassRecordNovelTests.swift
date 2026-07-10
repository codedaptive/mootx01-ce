// WordClassRecordNovelTests.swift
//
// Tests for the `wordClass(_:tagger:recordNovel:)` overload added to
// LatticeLib to support the distillation extractor privacy fix.
//
// The fix suppresses novel-token accumulation in `sharedNovelCache` when
// `recordNovel: false` is passed. This prevents private estate content
// processed by the HMM distillation extractor from leaking plaintext tokens
// into the pool pipeline (cookbook §2.2 / parity fix for Swift-only gap).
//
// Two invariants under test:
//   1. Tag identity: `recordNovel: false` returns the same WordClass as
//      `recordNovel: true` — only the pool side effect differs.
//   2. Non-recording: `tagNovelToken(_:tagger:recordNovel: false)` does NOT
//      call sharedNovelCache.record. This is verified via a custom isolated
//      NovelTokenCache constructed with a capture submitter. Note that
//      `tagNovelToken` only ever calls `sharedNovelCache.record` — not an
//      injected cache — so the non-recording path can only be verified
//      via the internal dispatch (no-call to `sharedNovelCache.record`)
//      or via delta tests. To avoid flakiness from parallel test suite
//      execution (other tests also write to the process-wide singleton),
//      the pool-side-effect tests use a serial suite and snapshot a range.

import Foundation
import Testing
@testable import LatticeLib

// MARK: - Tag identity tests (parallelism-safe: read-only assertions)

@Suite("wordClass(_:tagger:recordNovel:) — tag identity")
struct WordClassRecordNovelTagIdentityTests {

    /// The word class returned by the non-recording path must be byte-identical
    /// to the recording path for the same input token and tagger choice.
    /// This is the cross-port byte-identity contract: only the side effect
    /// (pool accumulation) is suppressed, never the tag result.
    @Test("novel token: recordNovel:false returns same WordClass as recordNovel:true (HMM)")
    func tagIdentityHMM_novel() {
        // "zorbliquate" is not in any shipped word-class table artifact — novel.
        let novel = "zorbliquate"
        let recording    = LatticeLib.wordClass(novel, tagger: .hmm, recordNovel: true)
        let nonRecording = LatticeLib.wordClass(novel, tagger: .hmm, recordNovel: false)
        #expect(
            recording == nonRecording,
            "recordNovel:false must return identical WordClass; got \(recording) vs \(nonRecording)"
        )
    }

    /// Table-resident tokens bypass the tagger entirely, so `recordNovel` is a
    /// no-op for them — they are never recorded in either mode.
    @Test("table-resident token: recordNovel:false returns same WordClass as recordNovel:true")
    func tagIdentityTableResident() {
        // "dinner" and "run" are canonical table residents (noun / verb).
        #expect(
            LatticeLib.wordClass("dinner", tagger: .hmm, recordNovel: false) ==
            LatticeLib.wordClass("dinner", tagger: .hmm, recordNovel: true)
        )
        #expect(
            LatticeLib.wordClass("run", tagger: .hmm, recordNovel: false) ==
            LatticeLib.wordClass("run", tagger: .hmm, recordNovel: true)
        )
    }

    /// Empty token: always .other regardless of recordNovel.
    @Test("empty token returns .other for both recordNovel values")
    func emptyTokenAlwaysOther() {
        #expect(LatticeLib.wordClass("", tagger: .hmm, recordNovel: false) == .other)
        #expect(LatticeLib.wordClass("", tagger: .hmm, recordNovel: true)  == .other)
    }
}

// MARK: - Pool side-effect tests
//
// These tests verify that `recordNovel: false` bypasses sharedNovelCache.record.
// Because `sharedNovelCache` is a process-wide singleton written by parallel
// tests, we use .serialized on the suite to prevent data races between test
// assertions in THIS suite. Other suites may still record concurrently, so we
// use a delta approach: measure the cache delta within a bounded sequential
// block and assert on relative change, not absolute count.

@Suite("wordClass(_:tagger:recordNovel:) — pool side-effect", .serialized)
struct WordClassRecordNovelPoolTests {

    /// Core invariant: within a sequential block, calling `wordClass` with
    /// `recordNovel: false` on a unique novel token must NOT increase
    /// `sharedNovelCache.count`, while calling `recordNovel: true` on a
    /// different unique novel token immediately after MUST increase it (or
    /// trigger a drain, which proves recording occurred).
    ///
    /// Using unique per-test tokens via a UUID suffix prevents interference
    /// from other tests that may have already recorded the same token.
    @Test("nonRecording does not record the token; recording does")
    func sequentialRecord() {
        // Unique suffix prevents re-use across test runs in the same process.
        let uid = UUID().uuidString.prefix(8)
        let nonRecordingToken = "nrtest_\(uid)_a"
        let recordingToken    = "nrtest_\(uid)_b"

        // Race-immune witness (WORDCLASS-CACHE-RACE): `sharedNovelCache` is a
        // process-global other parallel suites record into and drain
        // concurrently, so a before/after global-count delta is racy. Assert
        // on whether each SPECIFIC token was recorded. `wordClass` lowercases
        // before `record`, so watch/check the lowercased form.
        let nrKey = nonRecordingToken.lowercased()
        let rKey  = recordingToken.lowercased()
        LatticeLib.sharedNovelCache.watch(token: nrKey)
        LatticeLib.sharedNovelCache.watch(token: rKey)

        // Non-recording call must NOT record this token.
        _ = LatticeLib.wordClass(nonRecordingToken, tagger: .hmm, recordNovel: false)
        #expect(
            !LatticeLib.sharedNovelCache.wasRecorded(token: nrKey),
            "recordNovel:false must not record into sharedNovelCache"
        )

        // Recording call must record this token.
        _ = LatticeLib.wordClass(recordingToken, tagger: .hmm, recordNovel: true)
        #expect(
            LatticeLib.sharedNovelCache.wasRecorded(token: rKey),
            "recordNovel:true must record into sharedNovelCache"
        )
    }

    /// Internal dispatch path: `tagNovelToken(_:tagger:recordNovel:false)` must
    /// not change `sharedNovelCache.count`. Tests the internal method directly
    /// via @testable import so we're not relying on public API dispatch.
    @Test("tagNovelToken internal: recordNovel:false does not record the token")
    func tagNovelTokenInternalNonRecording() {
        let uid = UUID().uuidString.prefix(8)
        let token = "nrint_\(uid)"

        // Race-immune: assert this specific token was not recorded, not a
        // global-count delta (WORDCLASS-CACHE-RACE). record() receives the
        // lowercased form.
        let key = token.lowercased()
        LatticeLib.sharedNovelCache.watch(token: key)
        _ = LatticeLib.tagNovelToken(token, tagger: .hmm, recordNovel: false)
        #expect(
            !LatticeLib.sharedNovelCache.wasRecorded(token: key),
            "tagNovelToken(recordNovel:false) must not record into sharedNovelCache"
        )
    }
}
