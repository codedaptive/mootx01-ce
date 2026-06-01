import Testing
import Foundation
@testable import LocusKit

/// Tests for `KGFact` value type and its operational accessors per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1 and § 5.6.
///
/// Persistence ships in LOCI_V035_06B; this suite verifies the value
/// type, the four operational enums, and the bitmap accessor
/// round-trips only.
@Suite("KGFactTests")
struct KGFactTests {

    // MARK: - Designated initializer

    @Test
    func test_init_setsAllFields() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = KGFact(
            id: "fact-1",
            subject: "drawer-42",
            predicate: "is_about",
            object: "organic_chemistry",
            sourceDrawerID: "drawer-42",
            adjectiveBitmap: 0,
            operationalBitmap: 0,
            provenanceBitmap: 0,
            filedAt: now
        )
        #expect(fact.id == "fact-1")
        #expect(fact.subject == "drawer-42")
        #expect(fact.predicate == "is_about")
        #expect(fact.object == "organic_chemistry")
        #expect(fact.sourceDrawerID == "drawer-42")
        #expect(fact.adjectiveBitmap == 0)
        #expect(fact.operationalBitmap == 0)
        #expect(fact.provenanceBitmap == 0)
        #expect(fact.filedAt == now)
    }

    @Test
    func test_defaultID_isValidUUIDString() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(UUID(uuidString: fact.id) != nil,
                "default id must be a valid UUID string")
    }

    @Test
    func test_defaultBitmaps_areZero() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.adjectiveBitmap == 0)
        #expect(fact.operationalBitmap == 0)
        #expect(fact.provenanceBitmap == 0)
    }

    @Test
    func test_codableRoundTrip_preservesAllFields() throws {
        let original = KGFact(
            id: "fact-rt",
            subject: "subj",
            predicate: "pred",
            object: "obj",
            sourceDrawerID: "src-drawer",
            adjectiveBitmap: 0x3000,
            operationalBitmap: 0x3211,
            provenanceBitmap: 0x1234,
            filedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(KGFact.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - KGExtractorClass — bits 0–3, contiguous

    @Test
    func test_KGExtractorClass_rawValues() {
        #expect(KGExtractorClass.manual.rawValue == 0)
        #expect(KGExtractorClass.foundationModel.rawValue == 1)
        #expect(KGExtractorClass.specializedModel.rawValue == 2)
        #expect(KGExtractorClass.rulesBased.rawValue == 3)
        #expect(KGExtractorClass.importedKG.rawValue == 4)
        #expect(KGExtractorClass.federated.rawValue == 5)
    }

    // MARK: - KGAssertionKind — bits 4–6, contiguous

    @Test
    func test_KGAssertionKind_rawValues() {
        #expect(KGAssertionKind.asserted.rawValue == 0)
        #expect(KGAssertionKind.inferred.rawValue == 1)
        #expect(KGAssertionKind.hypothesized.rawValue == 2)
        #expect(KGAssertionKind.contradicted.rawValue == 3)
    }

    // MARK: - KGSpecificity — bits 7–9, scale-gapped

    @Test
    func test_KGSpecificity_rawValues() {
        #expect(KGSpecificity.general.rawValue == 0)
        #expect(KGSpecificity.domain.rawValue == 2)
        #expect(KGSpecificity.specific.rawValue == 4)
        #expect(KGSpecificity.instance.rawValue == 6)
    }

    @Test
    func test_KGSpecificity_scaleGapSentinels_areNil() {
        #expect(KGSpecificity(rawValue: 1) == nil)
        #expect(KGSpecificity(rawValue: 3) == nil)
        #expect(KGSpecificity(rawValue: 5) == nil)
    }

    // MARK: - KGConfidenceBand — bits 10–12, scale-gapped

    @Test
    func test_KGConfidenceBand_rawValues() {
        #expect(KGConfidenceBand.unknown.rawValue == 0)
        #expect(KGConfidenceBand.low.rawValue == 1)
        #expect(KGConfidenceBand.medium.rawValue == 2)
        #expect(KGConfidenceBand.high.rawValue == 4)
        #expect(KGConfidenceBand.certain.rawValue == 6)
    }

    @Test
    func test_KGConfidenceBand_scaleGapSentinels_areNil() {
        #expect(KGConfidenceBand(rawValue: 3) == nil)
        #expect(KGConfidenceBand(rawValue: 5) == nil)
    }

    // MARK: - Composite operational accessor round-trip

    @Test
    func test_operationalBitmap_composite_decodes() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0x3211,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.extractorClass == .foundationModel)
        #expect(fact.assertionKind == .inferred)
        #expect(fact.specificity == .specific)
        #expect(fact.confidenceBand == .high)
        #expect(fact.isCanonical)
    }

    // MARK: - Default-zero accessor defaults

    @Test
    func test_operationalBitmap_zero_returnsBaselineCases() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.extractorClass == .manual)
        #expect(fact.assertionKind == .asserted)
        #expect(fact.specificity == .general)
        #expect(fact.confidenceBand == .unknown)
        #expect(!fact.isCanonical)
    }

    // MARK: - Adjective accessor round-trip (mirrors Drawer pattern)

    @Test
    func test_adjectiveBitmap_trustAccessor() {
        // Cookbook §2.3 / §5.5: trust occupies bits 18–23 (6-bit), shared
        // with Drawer's adjective layout. canonical = raw 3 → 3 << 18 = 0xC0000.
        // (Pre-F11 this field was 4-bit at bits 12–15; the old 0x3000 value
        // was residue F11 missed when widening the adjective axes.)
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            adjectiveBitmap: 0xC0000,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.trust == .canonical)
    }

    // MARK: - Unknown raw value falls back to zero case

    @Test
    func test_extractorClass_unknownRawFallsBackToManual() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0xF,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.extractorClass == .manual,
                "raw 15 is outside the v1 case set; accessor must default to .manual")
    }

    @Test
    func test_specificity_scaleGapRaw_fallsBackToGeneral() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(1 << 7),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.specificity == .general,
                "scale-gap sentinel raw 1 must fall back to .general")
    }

    @Test
    func test_confidenceBand_scaleGapRaw_fallsBackToUnknown() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(3 << 10),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.confidenceBand == .unknown,
                "scale-gap sentinel raw 3 must fall back to .unknown")
    }

    @Test
    func test_isCanonical_isFalse_whenBit13Unset() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0x1FFF,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(!fact.isCanonical,
                "every bit below 13 set but bit 13 clear must read isCanonical=false")
    }

    @Test
    func test_isCanonical_isTrue_whenOnlyBit13Set() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(1 << 13),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.isCanonical,
                "bit 13 alone must read isCanonical=true with all other axes at baseline")
        #expect(fact.extractorClass == .manual)
        #expect(fact.assertionKind == .asserted)
        #expect(fact.specificity == .general)
        #expect(fact.confidenceBand == .unknown)
    }
}
