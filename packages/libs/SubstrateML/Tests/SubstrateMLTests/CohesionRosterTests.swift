// CohesionRosterTests.swift — pinned vectors shared with cohesion_roster_tests.rs (ADR-026).
import Testing
@testable import SubstrateML

struct CohesionRosterTests {
    let S = CohesionRoster.scale

    @Test("add accumulates exact sums, remove undoes them exactly, replace is remove then add")
    func addRemoveReplace() {
        var r = CohesionRoster()
        r.add(id: "a", digest: "a1", similarities: [])
        r.add(id: "b", digest: "b1", similarities: [S])            // a-b 1.0
        r.add(id: "c", digest: "c1", similarities: [S, S])         // a-c 1.0, b-c 1.0
        r.add(id: "d", digest: "d1", similarities: [0, 0, 0])      // d unlike everyone
        #expect(r.entries.map { [$0.id, "\($0.sum)"] } == [["a", "\(2 * Int64(S))"], ["b", "\(2 * Int64(S))"], ["c", "\(2 * Int64(S))"], ["d", "0"]])
        let before = r
        r.add(id: "e", digest: "e1", similarities: [S / 2, S / 2, S / 2, 0])
        r.remove(id: "e", similarities: [S / 2, S / 2, S / 2, 0])
        #expect(r == before, "remove restores the sums bit for bit")
        var viaReplace = r
        viaReplace.replace(id: "d", digest: "d2", oldSimilarities: [0, 0, 0], newSimilarities: [S, S, S])
        var viaSteps = r
        viaSteps.remove(id: "d", similarities: [0, 0, 0]); viaSteps.add(id: "d", digest: "d2", similarities: [S, S, S])
        #expect(viaReplace == viaSteps)
        #expect(viaReplace.entries.map(\.sum) == [3 * Int64(S), 3 * Int64(S), 3 * Int64(S), 3 * Int64(S)])
    }

    @Test("flags: the unlike member is the outlier at 1.5 sigma and not at 2; small rosters flag nothing")
    func flagsVector() {
        var r = CohesionRoster()
        r.add(id: "a", digest: "a1", similarities: [])
        r.add(id: "b", digest: "b1", similarities: [S])
        r.add(id: "c", digest: "c1", similarities: [S, S])
        r.add(id: "d", digest: "d1", similarities: [0, 0, 0])
        // cohesion a,b,c = 2/3, d = 0; mean 0.5; population sd ≈ 0.2887; z(d) ≈ −1.73
        #expect(r.flags(threshold: 1.5).map(\.anomalous) == [false, false, false, true])
        #expect(r.flags(threshold: 2.0).map(\.anomalous) == [false, false, false, false])
        var small = CohesionRoster()
        small.add(id: "x", digest: "x", similarities: [])
        small.add(id: "y", digest: "y", similarities: [0])
        #expect(small.flags(threshold: 0.1).map(\.anomalous) == [false, false])
    }

    @Test("quantise clamps and rounds to 24-bit fixed point")
    func quantise() {
        #expect(CohesionRoster.quantise(1.0) == S)
        #expect(CohesionRoster.quantise(0.5) == S / 2)
        #expect(CohesionRoster.quantise(-0.2) == 0 && CohesionRoster.quantise(1.7) == S)
        #expect(CohesionRoster.quantise(.nan) == 0)
    }
}
