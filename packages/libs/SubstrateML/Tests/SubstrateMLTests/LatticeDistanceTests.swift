// LatticeDistanceTests.swift
//
// Lattice distance per cookbook § 8.3. swift-testing peer suite for
// Sources/SubstrateML/LatticeDistance.swift, mirroring
// rust/src/lattice_distance.rs (12 #[test]) case-for-case, including
// the synthetic MockGraph adjacency provider and the Rust 1e-9
// tolerance.

import Foundation
import Testing
@testable import SubstrateML

/// Synthetic adjacency provider for tests — mirrors the Rust
/// `MockGraph`. Edges are inserted symmetrically.
private final class MockGraph: WikidataAdjacencyProvider {
    private var adj: [UInt64: Set<UInt64>] = [:]

    @discardableResult
    func edge(_ a: UInt64, _ b: UInt64) -> MockGraph {
        adj[a, default: []].insert(b)
        adj[b, default: []].insert(a)
        return self
    }

    func neighbors(of qid: UInt64) -> Set<UInt64> {
        adj[qid] ?? []
    }
}

@Suite("LatticeDistance")
struct LatticeDistanceTests {

    private let tol = 1e-9

    // MARK: - UDC tree distance

    @Test("identical UDC codes have zero distance")
    func udcIdenticalZero() {
        #expect(UDCTreeDistance.distance("004.42", "004.42") == 0.0)
    }

    @Test("shared-prefix UDC codes: 004.42 vs 004.5 = 3/6")
    func udcSharedPrefix() {
        // lcp = "004.", len 4. len(a)=6, len(b)=5.
        // raw = (6-4)+(5-4) = 3. divisor = max(6,5) = 6. d = 3/6 = 0.5.
        let d = UDCTreeDistance.distance("004.42", "004.5")
        #expect(abs(d - 3.0 / 6.0) < tol)
    }

    @Test("no common prefix: 004 vs 37 clamped to 1.0")
    func udcNoCommonPrefix() {
        // lcp = "", raw = 3 + 2 = 5, divisor = max(3,2) = 3.
        // The raw formula gives 5/3 ≈ 1.667, but UDCTreeDistance clamps to
        // [0, 1] before returning because CompositeDistance.distance requires
        // latticeDistance ∈ [0, 1] (enforced via precondition at line 57-60
        // of CompositeDistance.swift). After the clamp, the result is 1.0.
        let d = UDCTreeDistance.distance("004", "37")
        #expect(d == 1.0, "clamped to [0,1]: raw 5/3 ≈ 1.667 → 1.0")
    }

    @Test("no common prefix equal length: 'abc' vs 'xyz' clamped to 1.0")
    func udcNoCommonPrefixEqualLengthClamped() {
        // Two strings with no common prefix and equal length produce raw = 2.0
        // (the maximum of the unnormalized formula: (n-0)+(n-0)/n = 2).
        // After clamping, must return 1.0, not 2.0. Feeding 2.0 into
        // CompositeDistance would trip its precondition(latticeDistance <= 1.0).
        let d = UDCTreeDistance.distance("abc", "xyz")
        #expect(d == 1.0, "no-common-prefix equal-length must clamp to 1.0, not 2.0")
    }

    @Test("UDC distance is bounded to [0, 1] for pairs with shared prefix")
    func udcBoundedUnit() {
        // Pairs where d ∈ [0.0, 1.0] (shared prefix keeps raw ≤ max_len).
        // Note: pairs with no common prefix and len_a ≠ len_b can produce
        // d > 1.0 per the glref formula — those are excluded from this check.
        let pairs: [(String, String)] = [
            ("004.42", "004.5"),  // d = 0.5
            ("", "004"),          // max=3, raw=3, d=1.0
            ("004.42", ""),       // max=6, raw=6, d=1.0
            ("004", "004.42"),    // lcp="004", raw=0+3=3, max=6, d=0.5
            ("004.42", "004.42"), // identical → 0.0
        ]
        for (a, b) in pairs {
            let d = UDCTreeDistance.distance(a, b)
            #expect(d >= 0.0 && d <= 1.0, "d=\(d) for (\(a), \(b)) is out of [0,1]")
        }
    }

    @Test("two empty UDC strings have zero distance")
    func udcEmptyStrings() {
        #expect(UDCTreeDistance.distance("", "") == 0.0)
    }

    // MARK: - Wikidata graph distance

    @Test("identical Q-IDs have zero graph distance")
    func wikidataIdenticalZero() {
        let g = MockGraph()
        #expect(WikidataGraphDistance.distance(from: 11_111, to: 11_111, provider: g) == 0.0)
    }

    @Test("null Q-ID yields maximal graph distance")
    func wikidataNullQidMaxDistance() {
        let g = MockGraph()
        #expect(WikidataGraphDistance.distance(from: 0, to: 11_111, provider: g) == 1.0)
        #expect(WikidataGraphDistance.distance(from: 11_111, to: 0, provider: g) == 1.0)
    }

    @Test("one-hop graph distance = 1 - exp(-1/3)")
    func wikidataDistance1Hop() {
        let g = MockGraph()
        g.edge(11_111, 22_222)
        let d = WikidataGraphDistance.distance(from: 11_111, to: 22_222, provider: g)
        let expected = 1.0 - exp(-1.0 / 3.0)
        #expect(abs(d - expected) < tol)
    }

    @Test("three-hop graph distance = 1 - exp(-1)")
    func wikidataDistance3Hop() {
        let g = MockGraph()
        g.edge(1, 2).edge(2, 3).edge(3, 4)
        let d = WikidataGraphDistance.distance(from: 1, to: 4, provider: g)
        let expected = 1.0 - exp(-1.0)
        #expect(abs(d - expected) < tol)
    }

    @Test("path beyond max depth returns maximal distance")
    func wikidataBeyondDepthReturnsMax() {
        let g = MockGraph()
        g.edge(1, 2).edge(2, 3).edge(3, 4).edge(4, 5).edge(5, 6)
        // Path 1→6 has length 5; maxDepth = 4 ⇒ unreachable ⇒ 1.0.
        #expect(WikidataGraphDistance.distance(from: 1, to: 6, provider: g) == 1.0)
    }

    // MARK: - Combined lattice distance

    @Test("combined lattice distance is reflexive")
    func latticeCombinedReflexive() {
        let g = MockGraph()
        let a = LatticeAnchorStr(udc: "004.42", qid: 11_111)
        let d = LatticeDistance.distance(a, a, provider: g, alphaUDC: 0.5, alphaQID: 0.5)
        #expect(abs(d) < tol)
    }

    @Test("combined lattice distance is the weighted sum of components")
    func latticeCombinedWeighted() {
        let g = MockGraph()
        g.edge(11_111, 22_222)
        let a = LatticeAnchorStr(udc: "004.42", qid: 11_111)
        let b = LatticeAnchorStr(udc: "004.5", qid: 22_222)
        let dUDC = UDCTreeDistance.distance("004.42", "004.5")
        let dQID = WikidataGraphDistance.distance(from: 11_111, to: 22_222, provider: g)
        let expected = 0.5 * dUDC + 0.5 * dQID
        let d = LatticeDistance.distance(a, b, provider: g, alphaUDC: 0.5, alphaQID: 0.5)
        #expect(abs(d - expected) < tol)
    }
}
