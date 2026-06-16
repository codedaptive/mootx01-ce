// FactTimelineLifecycleTagTests.swift
//
// Conformance + parity suite for the G5 `moot_fact_timeline` lifecycle tag.
//
// The tag's active/retired partition MUST derive from the canonical
// `RowStateAutomaton` cluster (`cluster(s) = (s>>4)&0x3`, exposed as
// `RowState.cluster`), never a hand-rolled raw-value boundary. The earlier
// `(adjectiveBitmap & 0x3F) < 7` magic boundary was correct only for today's
// ten states by coincidence; any state added in the undefined gap 4–15 would
// have been mis-tagged "active". These tests pin the derivation to the
// automaton for EVERY defined state across the full 6-bit state field.

import Testing
import Foundation
import SubstrateTypes
@testable import AriaMCP

@Suite("fact_timeline lifecycle tag — RowStateAutomaton conformance")
struct FactTimelineLifecycleTagTests {

    /// Pack a RowState raw into bits 0–5 of an adjective bitmap, the way a
    /// persisted row carries its lifecycle state.
    private func adjective(state: RowState) -> Int64 {
        Int64(state.rawValue) & 0x3F
    }

    /// CONFORMANCE: for EVERY defined state, the lifecycle tag must agree with
    /// the automaton's cluster — Cluster A → "active", clusters B and C →
    /// "retired(<cluster>)". This holds the tag to the same partition the rest
    /// of the substrate uses, so adding any future state cannot misclassify it.
    @Test("lifecycle tag matches RowState.cluster for every defined state")
    func tagMatchesAutomatonClusterForEveryState() {
        for s in RowState.allCases {
            let tag = ToolDispatcher.lifecycleTag(forAdjectiveBitmap: adjective(state: s))
            let expected: String
            switch s.cluster {
            case .a: expected = "active"
            case .b: expected = "retired(B)"
            case .c: expected = "retired(C)"
            }
            #expect(tag == expected, "\(s) tag must follow its automaton cluster")
        }
    }

    /// Every defined raw across the full 6-bit state field classifies via the
    /// automaton; undefined gap raws (4–15, 20–31, 34–63) render
    /// "unknown(raw)" rather than being silently mis-tagged "active" — exactly
    /// the failure the old `< 7` boundary would hit for a state added in 4–15.
    @Test("gap state raws render unknown, never active")
    func gapStateRawsRenderUnknownNotActive() {
        for raw in UInt8(0)...UInt8(63) {
            let tag = ToolDispatcher.lifecycleTag(forAdjectiveBitmap: Int64(raw) & 0x3F)
            if let s = RowState(rawValue: raw) {
                let expected: String
                switch s.cluster {
                case .a: expected = "active"
                case .b: expected = "retired(B)"
                case .c: expected = "retired(C)"
                }
                #expect(tag == expected)
            } else {
                #expect(tag == "unknown(\(raw))",
                        "gap raw \(raw) must render unknown, never active")
            }
        }
    }

    /// PARITY: the Swift tag for each defined state must equal the exact string
    /// the Rust port emits (interface_tools.rs `lifecycle_tag_for_adjective_bitmap`
    /// + its `lifecycle_tag_tests`). The expectations below are the byte-identical
    /// tags both ports are conformance-pinned to; if either port drifts, one of
    /// the two suites fails.
    @Test("Swift tags are byte-identical to the Rust port's tags")
    func tagsAreParityWithRustPort() {
        let expectedByState: [(RowState, String)] = [
            (.active,     "active"),
            (.pending,    "active"),
            (.contested,  "active"),
            (.accepted,   "active"),
            (.superseded, "retired(B)"),
            (.decayed,    "retired(B)"),
            (.withdrawn,  "retired(B)"),
            (.expired,    "retired(B)"),
            (.rejected,   "retired(C)"),
            (.tombstoned, "retired(C)"),
        ]
        for (s, expected) in expectedByState {
            let tag = ToolDispatcher.lifecycleTag(forAdjectiveBitmap: adjective(state: s))
            #expect(tag == expected, "\(s) Swift/Rust parity tag")
        }
    }

    /// Higher adjective bits (trust / sensitivity / exportability) must not
    /// leak into the lifecycle tag — only bits 0–5 select the state.
    @Test("lifecycle tag ignores non-state bits")
    func tagIgnoresNonStateBits() {
        let active = adjective(state: .active)
            | (3 << 18) | (16 << 6) | (32 << 12)
        #expect(ToolDispatcher.lifecycleTag(forAdjectiveBitmap: active) == "active")
        let superseded = adjective(state: .superseded) | (3 << 18)
        #expect(ToolDispatcher.lifecycleTag(forAdjectiveBitmap: superseded) == "retired(B)")
    }
}
