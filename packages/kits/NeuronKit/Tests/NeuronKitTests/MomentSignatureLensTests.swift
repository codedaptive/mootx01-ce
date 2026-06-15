import Testing
@testable import NeuronKit
import SubstrateML
import SubstrateTypes
import EngramLib

// MomentSignature lens tests (SPEC § 8.2, Lens 1 Topics+Time).
// Verify spec behavioural claims: OR-reduced signature, Hamming-distance ranking,
// edge totality (B-8), determinism (B-5).

@Suite("MomentSignature lens (SPEC § 8.2, Lens 1)")
struct MomentSignatureLensTests {

    private func fp(_ b0: UInt64, _ b1: UInt64 = 0, _ b2: UInt64 = 0, _ b3: UInt64 = 0) -> Fingerprint256 {
        Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }

    private func row(_ fingerprint: Fingerprint256) -> RowLite {
        RowLite(fingerprint: fingerprint,
                captureHLC: HLC(physicalTime: 0, logicalCount: 0, nodeID: 0))
    }

    // B-8 edge: empty fingerprints → zero signature, empty ranking.
    @Test("momentSignature: empty fingerprints yields zero signature and empty ranking")
    func emptyFingerprints() {
        let cand = fp(0xFFFF)
        let result = NeuronKit.momentSignature(fingerprints: [], candidates: [cand])
        #expect(result.signature == .zero)
        #expect(result.ranking.isEmpty)
    }

    // B-8 edge: empty candidates → zero signature, empty ranking.
    @Test("momentSignature: empty candidates yields zero signature and empty ranking")
    func emptyCandidates() {
        let result = NeuronKit.momentSignature(fingerprints: [row(fp(0xABCD))], candidates: [])
        #expect(result.signature == .zero)
        #expect(result.ranking.isEmpty)
    }

    // Single fingerprint row → signature equals that fingerprint.
    @Test("momentSignature: single row signature equals its fingerprint")
    func singleRowSignatureIdentity() {
        let f = fp(0xDEAD, 0xBEEF)
        let result = NeuronKit.momentSignature(fingerprints: [row(f)], candidates: [f])
        #expect(result.signature == f)
    }

    // OR-reduction: two rows with disjoint bits → signature is their bitwise OR.
    @Test("momentSignature: OR-reduces fingerprints from window rows")
    func orReductionCorrect() {
        let a = fp(0xFF00)
        let b = fp(0x00FF)
        let expected = fp(0xFFFF)
        let result = NeuronKit.momentSignature(fingerprints: [row(a), row(b)],
                                               candidates: [expected])
        #expect(result.signature == expected)
    }

    // Ranking: the candidate identical to the signature ranks first (distance 0).
    @Test("momentSignature: identical candidate ranks first with distance 0")
    func identicalCandidateRanksFirst() {
        let f = fp(0xABCD, 0xEF01)
        let near = fp(0xABCD, 0xEF01)                    // identical — distance 0
        let far = fp(0x0000, 0x0000, 0xFFFF, 0xFFFF)     // many differing bits
        let result = NeuronKit.momentSignature(fingerprints: [row(f)],
                                               candidates: [far, near])
        #expect(result.ranking.first?.candidate == near)
        #expect(result.ranking.first?.hammingDistance == 0)
    }

    // Ranking is ascending by Hamming distance.
    @Test("momentSignature: ranking is ascending by Hamming distance")
    func rankingAscendingByDistance() {
        let sig = fp(0xFFFF)
        let c0 = fp(0xFFFF)                    // distance 0
        let c1 = fp(0xFFFE)                    // distance 1
        let cFar = fp(0x0000, 0xFFFF)          // more bits differ
        let result = NeuronKit.momentSignature(fingerprints: [row(sig)],
                                               candidates: [cFar, c1, c0])
        let dists = result.ranking.map { $0.hammingDistance }
        #expect(dists == dists.sorted())
    }

    // B-5 determinism: same input twice → identical output.
    @Test("momentSignature: deterministic — same input produces same output")
    func deterministic() {
        let f = fp(0x1234, 0x5678, 0x9ABC, 0xDEF0)
        let cand = fp(0x1234)
        let r1 = NeuronKit.momentSignature(fingerprints: [row(f)], candidates: [cand])
        let r2 = NeuronKit.momentSignature(fingerprints: [row(f)], candidates: [cand])
        #expect(r1 == r2)
    }

    // C-17 fidelity: lens signature equals MomentSummary.orReduce called directly on
    // the same fingerprint array.
    @Test("momentSignature fidelity (C-17): signature equals direct MomentSummary.orReduce")
    func c17FidelitySignatureMatchesPrimitive() {
        let fps = [fp(0xFF00), fp(0x00FF)]
        let rowLites = fps.map { row($0) }
        let direct = MomentSummary.orReduce(fps)
        let result = NeuronKit.momentSignature(fingerprints: rowLites, candidates: [direct])
        #expect(result.signature == direct,
                "lens signature must equal MomentSummary.orReduce on the same inputs")
    }
}
