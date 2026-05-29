import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

@Suite("Frame init and Filter expression tests")
struct FrameTests {

    @Test("CaptureFrame init sets every supplied field")
    func captureFrameInit_setsAllFields() {
        let lineage = UUID()
        let anchor = LatticeAnchor(udcCode: "547")
        let frame = CaptureFrame(
            content: "hello",
            channel: .voiced,
            room: "r1",
            latticeAnchor: anchor,
            addedBy: "agent-A",
            embeddingModelID: "minilm-v6",
            sensitivity: .elevated,
            kind: .code,
            lineageID: lineage
        )
        #expect(frame.content == "hello")
        #expect(frame.channel == .voiced)
        #expect(frame.room == "r1")
        #expect(frame.latticeAnchor == anchor)
        #expect(frame.addedBy == "agent-A")
        #expect(frame.embeddingModelID == "minilm-v6")
        #expect(frame.sensitivity == .elevated)
        #expect(frame.kind == .code)
        #expect(frame.lineageID == lineage)
    }

    @Test("CaptureFrame defaults: sensitivity .normal, kind .prose, lineageID nil")
    func captureFrameInit_defaults() {
        let frame = CaptureFrame(
            content: "x",
            channel: .typed,
            room: "r1",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "a",
            embeddingModelID: "m"
        )
        #expect(frame.sensitivity == .normal)
        #expect(frame.kind == .prose)
        #expect(frame.lineageID == nil)
    }

    @Test("CaptureFrame default lineageID stays nil when omitted")
    func captureFrameInit_lineageNilByDefault() {
        let frame = CaptureFrame(
            content: "x",
            channel: .typed,
            room: "r1",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "a",
            embeddingModelID: "m"
        )
        #expect(frame.lineageID == nil)
    }

    @Test("RecallFrame init with single filter")
    func recallFrameInit_withSingleFilter() {
        let frame = RecallFrame(filterChain: [.currentlyBelieve])
        #expect(frame.filterChain.count == 1)
    }

    @Test("RecallFrame defaults: hydrationLevel .structured, limit nil, ordering .byCaptureTimeDesc, asOf nil")
    func recallFrameInit_defaults() {
        let frame = RecallFrame(filterChain: [.currentlyBelieve])
        #expect(frame.hydrationLevel == .structured)
        #expect(frame.limit == nil)
        #expect(frame.ordering == .byCaptureTimeDesc)
        #expect(frame.asOf == nil)
    }

    @Test("MutationKind cases are distinct")
    func mutationKindCases_distinct() {
        let confirm = MutationKind.confirm
        let reject = MutationKind.reject
        if case .confirm = reject {
            Issue.record("MutationKind.confirm matched .reject — cases are not distinct")
        }
        if case .reject = confirm {
            Issue.record("MutationKind.reject matched .confirm — cases are not distinct")
        }
    }

    @Test("MutationKind cases with associated values compile")
    func mutationKindCases_withAssociatedValues() {
        // Type-check that the associated-value cases compile.
        let sens: MutationKind = .correctSensitivity(.elevated)
        let trust: MutationKind = .correctTrust(.canonical)
        // Use them so the compiler doesn't elide the let bindings.
        if case .correctSensitivity = sens {} else {
            Issue.record(".correctSensitivity case did not match")
        }
        if case .correctTrust = trust {} else {
            Issue.record(".correctTrust case did not match")
        }
    }

    @Test("Filter expression compiles with expected case shapes")
    func filterExpression_compiles() {
        let chain: [Filter] = [
            .currentlyBelieve,
            .trustworthy,
            .sensitivityAtMost(.normal),
            .inRoom("r1"),
            .all([.usedToBelieve, .not(.trustworthy)])
        ]
        #expect(chain.count == 5)
    }

    @Test("Filter.all is not Filter.any (composition cases are distinct)")
    func filterComposition_allVsAny() {
        let allOf: Filter = .all([.currentlyBelieve, .trustworthy])
        let anyOf: Filter = .any([.currentlyBelieve, .trustworthy])
        switch allOf {
        case .all: break
        default: Issue.record("Filter.all did not match .all")
        }
        switch anyOf {
        case .any: break
        default: Issue.record("Filter.any did not match .any")
        }
        // Sanity: anyOf is not also .all
        if case .all = anyOf {
            Issue.record("Filter.any incorrectly matched .all")
        }
    }

    @Test("Ordering cases are distinct")
    func orderingCases_distinct() {
        #expect(Ordering.byCaptureTimeDesc != .byCaptureTimeAsc)
    }

    @Test("HydrationLevel cases are distinct")
    func hydrationLevelCases_distinct() {
        #expect(HydrationLevel.structured != .full)
    }
}
