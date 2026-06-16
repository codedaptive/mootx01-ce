import Testing
@testable import NeuronKit
import SubstrateML

// Precedence lens tests (SPEC § 8.2, Lens 3 Prediction).
// Verify spec behavioural claims: target filtering, count-ranked antecedents,
// edge totality (B-8), determinism (B-5).

@Suite("Precedence lens (SPEC § 8.2, Lens 3)")
struct PrecedenceLensTests {

    private func coord(_ field: String, _ value: String) -> TemporalFieldCoord {
        TemporalFieldCoord(fieldPath: field, valueRepr: value)
    }

    private func key(src: TemporalFieldCoord, tgt: TemporalFieldCoord,
                     lag: Int = 1) -> TemporalCausalityKey {
        TemporalCausalityKey(source: src, target: tgt, lagBucket: lag)
    }

    // B-8 edge: empty pairs → empty.
    @Test("precedence: empty pairs yields empty")
    func emptyPairs() {
        let target = coord("status", "string:active")
        let result = NeuronKit.precedence(pairs: [], target: target, k: 5)
        #expect(result.isEmpty)
    }

    // B-8 edge: k == 0 → empty.
    @Test("precedence: k zero yields empty")
    func kZero() {
        let src = coord("type", "string:note")
        let tgt = coord("status", "string:active")
        let pairs: [(TemporalCausalityKey, Int64)] = [(key(src: src, tgt: tgt), 10)]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 0)
        #expect(result.isEmpty)
    }

    // No pair targets the given coord → empty.
    @Test("precedence: no matching target yields empty")
    func noMatchingTarget() {
        let src = coord("type", "string:note")
        let tgt = coord("status", "string:active")
        let other = coord("status", "string:archived")
        let pairs: [(TemporalCausalityKey, Int64)] = [(key(src: src, tgt: other), 10)]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        #expect(result.isEmpty)
    }

    // Filters by target field-value coord, excludes unrelated pairs.
    @Test("precedence: filters by target coord")
    func filtersCorrectly() {
        let src1 = coord("type", "string:note")
        let src2 = coord("type", "string:task")
        let tgt = coord("status", "string:active")
        let other = coord("status", "string:archived")
        let pairs: [(TemporalCausalityKey, Int64)] = [
            (key(src: src1, tgt: tgt), 5),
            (key(src: src2, tgt: other), 20),   // different target — excluded
        ]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        #expect(result.count == 1)
        #expect(result[0].source == src1)
    }

    // Result sorted by count descending.
    @Test("precedence: sorted by count descending")
    func sortedByCountDescending() {
        let tgt = coord("status", "string:active")
        let src1 = coord("a", "v:1")
        let src2 = coord("b", "v:2")
        let src3 = coord("c", "v:3")
        let pairs: [(TemporalCausalityKey, Int64)] = [
            (key(src: src3, tgt: tgt), 5),
            (key(src: src1, tgt: tgt), 100),
            (key(src: src2, tgt: tgt), 30),
        ]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        let counts = result.map(\.count)
        #expect(counts == counts.sorted(by: >))
        #expect(result[0].source == src1)
    }

    // Result capped to k.
    @Test("precedence: result capped to k")
    func cappedToK() {
        let tgt = coord("status", "string:active")
        var pairs: [(TemporalCausalityKey, Int64)] = []
        for i in 0..<10 {
            pairs.append((key(src: coord("f", "v:\(i)"), tgt: tgt), Int64(i + 1)))
        }
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 3)
        #expect(result.count == 3)
    }

    // lagBucket is preserved from the key.
    @Test("precedence: lagBucket carried through to result")
    func lagBucketPreserved() {
        let src = coord("type", "string:note")
        let tgt = coord("status", "string:active")
        let pairs: [(TemporalCausalityKey, Int64)] = [(key(src: src, tgt: tgt, lag: 16), 7)]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        #expect(result[0].lagBucket == 16)
    }

    // B-5 determinism.
    @Test("precedence: deterministic — same input produces same output")
    func deterministic() {
        let tgt = coord("status", "string:active")
        let pairs: [(TemporalCausalityKey, Int64)] = [
            (key(src: coord("a", "v:1"), tgt: tgt), 42),
            (key(src: coord("b", "v:2"), tgt: tgt), 17),
        ]
        let r1 = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        let r2 = NeuronKit.precedence(pairs: pairs, target: tgt, k: 5)
        #expect(r1 == r2)
    }

    // C-17 fidelity: count in lens output equals count from input pairs after
    // filtering and sorting — the lens does no arithmetic on the count value.
    @Test("precedence fidelity (C-17): output count equals input pair count (no transformation)")
    func c17FidelityCountPassThrough() {
        let tgt = coord("status", "string:active")
        let src = coord("type", "string:note")
        let inputCount: Int64 = 42
        let pairs: [(TemporalCausalityKey, Int64)] = [(key(src: src, tgt: tgt), inputCount)]
        let result = NeuronKit.precedence(pairs: pairs, target: tgt, k: 1)
        #expect(result[0].count == inputCount,
                "lens must pass the count through unchanged — it owns no math")
    }
}
