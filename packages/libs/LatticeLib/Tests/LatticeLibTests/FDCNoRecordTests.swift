// FDCNoRecordTests.swift
//
// Tests for the secfix/fdc-pool non-recording encode-anchor path:
//   wordClass(_:recordNovel:)          — no-tagger-choice overload
//   FDC.encodeAnchor(_:recordNovel:)   — end-to-end encode via non-recording bag
//
// Prior fix #96 (ce-hmm-pool-leak) added non-recording variants of
// wordClass(_:tagger:recordNovel:). This fix (secfix/fdc-pool) extends the
// same pattern to the no-tagger-choice default path used by the FDC runtime —
// the path reached when user memory content is classified at the GLK capture
// seam before being filed.
//
// Tests here are PARALLELISM-SAFE: they assert tag identity and result
// identity only, with no assertions on the sharedNovelCache singleton count.
// The pool non-recording guarantee is proven by the Rust single-binary
// test `no_record_accumulation_test.rs` and is mechanically enforced by
// the code structure: wordClass(_:recordNovel:false) never calls
// sharedNovelCache.record (see WordClassTagger.swift tagNovelToken(_:recordNovel:)).
//
// Two invariants:
//   1. Tag identity: wordClass(_:recordNovel:false) == wordClass(_:recordNovel:true)
//      for the same token — only pool accumulation is suppressed, never the tag result.
//   2. Result identity: FDC.encodeAnchor(text, recordNovel:false) == FDC.encodeAnchor(text)
//      — the anchor (code, qid) is byte-identical.

import Foundation
import Testing
@testable import LatticeLib

// MARK: - wordClass(_:recordNovel:) tag-identity tests (parallelism-safe)

@Suite("wordClass(_:recordNovel:) — tag identity (no tagger choice)")
struct WordClassNoTaggerRecordNovelTagIdentityTests {

    /// Novel token: the no-tagger-choice non-recording path returns the same
    /// WordClass as the recording path. Only the pool side effect differs.
    @Test("novel token: recordNovel:false returns same WordClass as recordNovel:true")
    func tagIdentityNovel() {
        // "zorbquinate" is not in any shipped word-class table — novel.
        let novel = "zorbquinate"
        let recording    = LatticeLib.wordClass(novel, recordNovel: true)
        let nonRecording = LatticeLib.wordClass(novel, recordNovel: false)
        #expect(
            recording == nonRecording,
            "recordNovel:false must return identical WordClass; got \(recording) vs \(nonRecording)"
        )
    }

    /// Table-resident tokens bypass the tagger; recordNovel is a no-op for them.
    @Test("table-resident token: recordNovel:false returns same WordClass as recordNovel:true")
    func tagIdentityTableResident() {
        #expect(
            LatticeLib.wordClass("engine", recordNovel: false) ==
            LatticeLib.wordClass("engine", recordNovel: true)
        )
        #expect(
            LatticeLib.wordClass("compute", recordNovel: false) ==
            LatticeLib.wordClass("compute", recordNovel: true)
        )
    }

    /// Empty token returns .other regardless of recordNovel.
    @Test("empty token returns .other for both recordNovel values")
    func emptyTokenAlwaysOther() {
        #expect(LatticeLib.wordClass("", recordNovel: false) == .other)
        #expect(LatticeLib.wordClass("", recordNovel: true)  == .other)
    }
}

// MARK: - FDC.encodeAnchor(_:recordNovel:) result-identity tests (parallelism-safe)

@Suite("FDC.encodeAnchor(_:recordNovel:) — result identity (secfix/fdc-pool)")
struct FDCEncodeAnchorNoRecordResultIdentityTests {

    /// Result identity: the anchor returned by the non-recording variant must
    /// be byte-identical to the standard variant for the same input.
    @Test("result identity: encodeAnchor(recordNovel:false) == encodeAnchor(text)")
    func anchorResultIdentity() {
        guard FDC.isAvailable else { return }

        let text = "modern diesel engine technology"
        let (codeStd, qidStd) = FDC.encodeAnchor(text)
        let (codeNR,  qidNR)  = FDC.encodeAnchor(text, recordNovel: false)

        #expect(codeStd == codeNR, "code must match: \(String(describing: codeStd)) vs \(String(describing: codeNR))")
        #expect(qidStd  == qidNR,  "qid must match: \(String(describing: qidStd)) vs \(String(describing: qidNR))")
    }

    /// Fictional unresolvable text: both paths must agree on code (both None
    /// or both the same code — result must be identical regardless of
    /// recording mode).
    @Test("unresolvable text: both paths agree on code")
    func unresolvableAgreement() {
        guard FDC.isAvailable else { return }

        let text = "zorbquinatefoo borbleplonk frubliqwerty"
        let (codeStd, _) = FDC.encodeAnchor(text)
        let (codeNR,  _) = FDC.encodeAnchor(text, recordNovel: false)

        // Both paths must agree — either both None (UNRESOLVED) or both the same code.
        #expect(
            codeStd == codeNR,
            "both paths must return the same code for the same input; got \(String(describing: codeStd)) vs \(String(describing: codeNR))"
        )
    }

    /// recordNovel:false must return identical result to recordNovel:true on
    /// another novel-heavy text to strengthen the identity contract.
    @Test("novel-heavy text: encodeAnchor(recordNovel:false) == encodeAnchor(recordNovel:true)")
    func novelHeavyIdentity() {
        guard FDC.isAvailable else { return }

        let text = "deep neural network architecture transformer attention mechanism"
        let standard      = FDC.encodeAnchor(text)
        let nonRecording  = FDC.encodeAnchor(text, recordNovel: false)

        #expect(standard.0 == nonRecording.0, "code must match")
        #expect(standard.1 == nonRecording.1, "qid must match")
    }
}
