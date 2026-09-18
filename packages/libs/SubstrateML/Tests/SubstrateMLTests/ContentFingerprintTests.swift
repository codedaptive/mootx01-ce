// ContentFingerprintTests.swift — pinned vectors shared with content_fingerprint_tests.rs (ADR-026).
import Testing
import SubstrateTypes
@testable import SubstrateML

struct ContentFingerprintTests {
    let fox = "The quick brown fox jumps over the lazy dog"

    @Test("pinned vectors: a sentence, a two-character text, the empty text")
    func pinnedVectors() {
        let f = ContentFingerprint.fingerprint(of: fox)
        #expect([f.block0, f.block1, f.block2, f.block3] == [0x2B60F941D15CAEE5, 0x1C47031194216C3A, 0x0DD73D2100654F5F, 0xB3CACB0CD2AEEA7C])
        let ab = ContentFingerprint.fingerprint(of: "ab")
        #expect([ab.block0, ab.block1, ab.block2, ab.block3] == [0x32F20CC2F25D2AF7, 0x7F4A8CCBA9F51C9E, 0x3E4E64B3921FC98D, 0x7DC1B4B9FF22AC34])
        #expect(ContentFingerprint.fingerprint(of: "") == .zero)
        #expect(ContentFingerprint.fingerprint(of: "THE QUICK brown fox jumps over the lazy DOG") == f, "case folds before shingling")
        #expect(ContentFingerprint.fingerprint(ofShingles: ShingleSimilarity.shingles(fox)) == f, "the set form is the same math")
    }

    @Test("Hamming distance falls with shingle overlap: a paraphrase is near, an unrelated sentence is far")
    func distanceTracksOverlap() {
        let f = ContentFingerprint.fingerprint(of: fox)
        let near = ContentFingerprint.fingerprint(of: "The quick brown fox jumped over the lazy dogs")
        let far = ContentFingerprint.fingerprint(of: "Quarterly revenue rose nine percent on services")
        #expect(Hamming.distance(f, near) == 30)
        #expect(Hamming.distance(f, far) == 92)
    }
}
