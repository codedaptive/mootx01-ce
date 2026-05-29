// DrawerFingerprintTests.swift
//
// Tests for the drawer-to-fingerprint derivation that un-defers
// LOCI_V035_18. The load-bearing checks are determinism (a contract the
// whole estate coordinate system rests on), replica agreement, and
// family independence (the blockIndex landmine: the three 64-bit blocks
// must project through distinct hyperplanes).

import Foundation
import SubstrateTypes
import Testing
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
@testable import LocusKit

@Suite("DrawerFingerprintTests")
struct DrawerFingerprintTests {

    private let estateA = "11111111-1111-1111-1111-111111111111"
    private let estateB = "22222222-2222-2222-2222-222222222222"

    private func drawer(
        content: String = "hello",
        provenance: Int64 = 0,
        adjective: Int64 = 0,
        operational: Int64 = 0,
        lineageID: UUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        udc: String = "613.71",
        qid: String? = "Q42",
        filedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Drawer {
        Drawer(content: content, wing: "w", room: "r", addedBy: "test",
               filedAt: filedAt, embeddingModelID: "m",
               provenance: provenance, adjectiveBitmap: adjective,
               operationalBitmap: operational, lineageID: lineageID,
               udcCode: udc, wikidataQID: qid)
    }

    // MARK: - Family independence (the blockIndex landmine)

    @Test("The four families are independent per block")
    func familiesAreIndependentPerBlock() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        #expect(fam.families.count == 4)
        let hashes = fam.families.map { $0.canonicalHash() }
        // If generate did not diversify per block, the three 64-bit-input
        // families would be identical and this fails.
        #expect(Set(hashes).count == 4, "families collapsed; seeds not diversified")
    }

    @Test("Block 0 projects a wider input than blocks 1 through 3")
    func blockZeroFamilyIsWiderInput() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        #expect(fam.families[0].inputBitLength == 192)
        #expect(fam.families[1].inputBitLength == 64)
        #expect(fam.families[2].inputBitLength == 64)
        #expect(fam.families[3].inputBitLength == 64)
    }

    // MARK: - Determinism and replica agreement

    @Test("Same drawer yields the same fingerprint")
    func deterministicForSameDrawer() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        let d = drawer()
        #expect(fam.fingerprint(of: d) == fam.fingerprint(of: d))
    }

    @Test("Independent family sets for one estate agree bit for bit")
    func replicaAgreement() {
        let famA1 = EstateFingerprintFamilies(estateUUID: estateA)
        let famA2 = EstateFingerprintFamilies(estateUUID: estateA)
        #expect(famA1.families.map { $0.canonicalHash() }
                == famA2.families.map { $0.canonicalHash() })
        let d = drawer()
        #expect(famA1.fingerprint(of: d) == famA2.fingerprint(of: d))
    }

    @Test("Different estates get different families")
    func differentEstatesDifferentFamilies() {
        let famA = EstateFingerprintFamilies(estateUUID: estateA)
        let famB = EstateFingerprintFamilies(estateUUID: estateB)
        #expect(famA.families.map { $0.canonicalHash() }
                != famB.families.map { $0.canonicalHash() })
    }

    // MARK: - Field sensitivity (the right facets move the fingerprint)

    @Test("A bitmap change moves the fingerprint")
    func bitmapChangeMovesFingerprint() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        #expect(fam.fingerprint(of: drawer(adjective: 0))
                != fam.fingerprint(of: drawer(adjective: 0x00FF_FF00)))
    }

    @Test("A lineage change moves the fingerprint")
    func lineageChangeMovesFingerprint() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        let l1 = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let l2 = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        #expect(fam.fingerprint(of: drawer(lineageID: l1))
                != fam.fingerprint(of: drawer(lineageID: l2)))
    }

    @Test("A provenance change moves the fingerprint")
    func provenanceChangeMovesFingerprint() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        #expect(fam.fingerprint(of: drawer(provenance: 0))
                != fam.fingerprint(of: drawer(provenance: 0x0000_0000_0000_0123)))
    }

    // MARK: - I-17 null handling (absent facets do not crash, stay deterministic)

    @Test("Empty optional fields stay deterministic and nonzero")
    func emptyOptionalFieldsAreDeterministic() {
        let fam = EstateFingerprintFamilies(estateUUID: estateA)
        let d = drawer(udc: "", qid: nil)
        #expect(fam.fingerprint(of: d) == fam.fingerprint(of: d))
        #expect(fam.fingerprint(of: d) != Fingerprint256.zero)
    }

    // MARK: - Sub-field unit checks

    @Test("Capture-week bucket counts whole weeks from the 2020 epoch")
    func captureWeekBucket() {
        let epoch = Date(timeIntervalSince1970: 1_577_836_800)
        #expect(EstateFingerprintFamilies.captureWeekBucket(epoch) == 0)
        let oneWeek = Date(timeIntervalSince1970: 1_577_836_800 + 7 * 86_400 + 10)
        #expect(EstateFingerprintFamilies.captureWeekBucket(oneWeek) == 1)
        let preEpoch = Date(timeIntervalSince1970: 0)
        #expect(EstateFingerprintFamilies.captureWeekBucket(preEpoch) == 0)
    }

    @Test("UDC prefix hash strips separators to the first four digits")
    func udcPrefixHashStripsSeparators() {
        #expect(EstateFingerprintFamilies.udcPrefixHash("613.71")
                == EstateFingerprintFamilies.udcPrefixHash("6137"))
    }
}
