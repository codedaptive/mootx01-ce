import Testing
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
@testable import LocusKit

/// LocusKit's declared vocabulary must freeze without overlap or basis
/// collision — the precondition for arming the write gate at open.
/// Mirror of rust/src/vocabulary.rs `vocabulary_freezes_clean`.
@Suite("LocusKitVocabularyTests")
struct LocusKitVocabularyTests {
    @Test
    func testVocabularyFreezesClean() {
        guard case .success = LocusKitVocabulary.frozen() else {
            Issue.record("LocusKit union must freeze without overlap/collision")
            return
        }
    }

    /// Every operational/provenance slot is the consumer union, disjoint
    /// from the substrate basis (which is adjective-only).
    @Test
    func testUnionIsAdjectiveDisjoint() {
        for slot in LocusKitVocabulary.unionSlots {
            #expect(slot.column != .adjective,
                "LocusKit union must not claim adjective bits (those are basis)")
        }
    }
}
