import XCTest
@testable import LocusKit

/// Tests for `KGFact` value type and its operational accessors per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1 and § 5.6.
///
/// Persistence ships in LOCI_V035_06B; this suite verifies the value
/// type, the four operational enums, and the bitmap accessor
/// round-trips only.
final class KGFactTests: XCTestCase {

    // MARK: - Designated initializer

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
        XCTAssertEqual(fact.id, "fact-1")
        XCTAssertEqual(fact.subject, "drawer-42")
        XCTAssertEqual(fact.predicate, "is_about")
        XCTAssertEqual(fact.object, "organic_chemistry")
        XCTAssertEqual(fact.sourceDrawerID, "drawer-42")
        XCTAssertEqual(fact.adjectiveBitmap, 0)
        XCTAssertEqual(fact.operationalBitmap, 0)
        XCTAssertEqual(fact.provenanceBitmap, 0)
        XCTAssertEqual(fact.filedAt, now)
    }

    func test_defaultID_isValidUUIDString() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotNil(UUID(uuidString: fact.id),
                        "default id must be a valid UUID string")
    }

    func test_defaultBitmaps_areZero() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.adjectiveBitmap, 0)
        XCTAssertEqual(fact.operationalBitmap, 0)
        XCTAssertEqual(fact.provenanceBitmap, 0)
    }

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
        XCTAssertEqual(decoded, original)
    }

    // MARK: - KGExtractorClass — bits 0–3, contiguous

    func test_KGExtractorClass_rawValues() {
        XCTAssertEqual(KGExtractorClass.manual.rawValue, 0)
        XCTAssertEqual(KGExtractorClass.foundationModel.rawValue, 1)
        XCTAssertEqual(KGExtractorClass.specializedModel.rawValue, 2)
        XCTAssertEqual(KGExtractorClass.rulesBased.rawValue, 3)
        XCTAssertEqual(KGExtractorClass.importedKG.rawValue, 4)
        XCTAssertEqual(KGExtractorClass.federated.rawValue, 5)
    }

    // MARK: - KGAssertionKind — bits 4–6, contiguous

    func test_KGAssertionKind_rawValues() {
        XCTAssertEqual(KGAssertionKind.asserted.rawValue, 0)
        XCTAssertEqual(KGAssertionKind.inferred.rawValue, 1)
        XCTAssertEqual(KGAssertionKind.hypothesized.rawValue, 2)
        XCTAssertEqual(KGAssertionKind.contradicted.rawValue, 3)
    }

    // MARK: - KGSpecificity — bits 7–9, scale-gapped

    func test_KGSpecificity_rawValues() {
        XCTAssertEqual(KGSpecificity.general.rawValue, 0)
        XCTAssertEqual(KGSpecificity.domain.rawValue, 2)
        XCTAssertEqual(KGSpecificity.specific.rawValue, 4)
        XCTAssertEqual(KGSpecificity.instance.rawValue, 6)
    }

    func test_KGSpecificity_scaleGapSentinels_areNil() {
        XCTAssertNil(KGSpecificity(rawValue: 1))
        XCTAssertNil(KGSpecificity(rawValue: 3))
        XCTAssertNil(KGSpecificity(rawValue: 5))
    }

    // MARK: - KGConfidenceBand — bits 10–12, scale-gapped

    func test_KGConfidenceBand_rawValues() {
        XCTAssertEqual(KGConfidenceBand.unknown.rawValue, 0)
        XCTAssertEqual(KGConfidenceBand.low.rawValue, 1)
        XCTAssertEqual(KGConfidenceBand.medium.rawValue, 2)
        XCTAssertEqual(KGConfidenceBand.high.rawValue, 4)
        XCTAssertEqual(KGConfidenceBand.certain.rawValue, 6)
    }

    func test_KGConfidenceBand_scaleGapSentinels_areNil() {
        XCTAssertNil(KGConfidenceBand(rawValue: 3))
        XCTAssertNil(KGConfidenceBand(rawValue: 5))
    }

    // MARK: - Composite operational accessor round-trip

    func test_operationalBitmap_composite_decodes() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0x3211,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.extractorClass, .foundationModel)
        XCTAssertEqual(fact.assertionKind, .inferred)
        XCTAssertEqual(fact.specificity, .specific)
        XCTAssertEqual(fact.confidenceBand, .high)
        XCTAssertTrue(fact.isCanonical)
    }

    // MARK: - Default-zero accessor defaults

    func test_operationalBitmap_zero_returnsBaselineCases() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.extractorClass, .manual)
        XCTAssertEqual(fact.assertionKind, .asserted)
        XCTAssertEqual(fact.specificity, .general)
        XCTAssertEqual(fact.confidenceBand, .unknown)
        XCTAssertFalse(fact.isCanonical)
    }

    // MARK: - Adjective accessor round-trip (mirrors Drawer pattern)

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
        XCTAssertEqual(fact.trust, .canonical)
    }

    // MARK: - Unknown raw value falls back to zero case

    func test_extractorClass_unknownRawFallsBackToManual() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0xF,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.extractorClass, .manual,
                       "raw 15 is outside the v1 case set; accessor must default to .manual")
    }

    func test_specificity_scaleGapRaw_fallsBackToGeneral() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(1 << 7),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.specificity, .general,
                       "scale-gap sentinel raw 1 must fall back to .general")
    }

    func test_confidenceBand_scaleGapRaw_fallsBackToUnknown() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(3 << 10),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(fact.confidenceBand, .unknown,
                       "scale-gap sentinel raw 3 must fall back to .unknown")
    }

    func test_isCanonical_isFalse_whenBit13Unset() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: 0x1FFF,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertFalse(fact.isCanonical,
                       "every bit below 13 set but bit 13 clear must read isCanonical=false")
    }

    func test_isCanonical_isTrue_whenOnlyBit13Set() {
        let fact = KGFact(
            subject: "s",
            predicate: "p",
            object: "o",
            sourceDrawerID: "d",
            operationalBitmap: Int64(1 << 13),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(fact.isCanonical,
                      "bit 13 alone must read isCanonical=true with all other axes at baseline")
        XCTAssertEqual(fact.extractorClass, .manual)
        XCTAssertEqual(fact.assertionKind, .asserted)
        XCTAssertEqual(fact.specificity, .general)
        XCTAssertEqual(fact.confidenceBand, .unknown)
    }
}
