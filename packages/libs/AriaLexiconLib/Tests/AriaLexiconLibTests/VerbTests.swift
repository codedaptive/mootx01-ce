// VerbTests.swift
//
// Per-type peer suite for `Verb` and its `Flow`. Mirrors the Rust
// `verb_count_is_nine` and `verb_flows_partition` #[test] functions (spec
// invariant I-7: the verb count is fixed at nine) and adds the type-local
// surface: declaration-order identity of the nine verbs, the full per-case
// flow mapping, the flow partition counts, the `Flow` category set, and
// rawValue identity.

import Testing
@testable import AriaLexiconLib

@Suite("Verb")
struct VerbTests {

    @Test("The verb count is fixed at nine (I-7)")
    func verbCountIsNine() {
        #expect(Verb.allCases.count == 9)
    }

    @Test("The nine verbs are in canonical declaration order")
    func verbDeclarationOrder() {
        #expect(Verb.allCases == [
            .capture, .reanchor, .mutate, .withdraw, .expunge,
            .recall, .propose, .associate, .learn,
        ])
    }

    @Test("Verb flows partition the nine verbs as the spec defines")
    func verbFlowsPartition() {
        let caller = Verb.allCases.filter { $0.flow == .callerDriven }
        let substrate = Verb.allCases.filter { $0.flow == .substrateDriven }
        let grounding = Verb.allCases.filter { $0.flow == .groundingDriven }
        #expect(Set(caller) == [.capture, .reanchor, .mutate, .withdraw, .expunge, .recall])
        #expect(Set(substrate) == [.propose, .associate])
        #expect(Set(grounding) == [.learn])
        #expect(caller.count + substrate.count + grounding.count == 9)
    }

    @Test("The three flows partition the nine verbs 6/2/1")
    func flowPartitionCounts() {
        let byFlow = Dictionary(grouping: Verb.allCases, by: { $0.flow })
        #expect(byFlow[.callerDriven]?.count == 6)
        #expect(byFlow[.substrateDriven]?.count == 2)
        #expect(byFlow[.groundingDriven]?.count == 1)
        let total = Flow.allCases.reduce(0) { $0 + (byFlow[$1]?.count ?? 0) }
        #expect(total == Verb.allCases.count)
    }

    @Test("There are three flows")
    func flowCount() {
        #expect(Flow.allCases.count == 3)
    }

    @Test("Verb raw values are stable and round-trip")
    func rawValueIdentity() {
        #expect(Verb.capture.rawValue == "capture")
        #expect(Verb.reanchor.rawValue == "reanchor")
        #expect(Verb.associate.rawValue == "associate")
        for verb in Verb.allCases {
            #expect(Verb(rawValue: verb.rawValue) == verb)
        }
    }
}
