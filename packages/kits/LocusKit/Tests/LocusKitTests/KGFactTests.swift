import Testing
import Foundation
@testable import LocusKit

/// Tests for `KGFact` value type and its operational accessors per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1 and § 5.6.
///
/// Covers KGFact value/accessor behavior: the four operational enums
/// and bitmap accessor round-trips. Persistence coverage lives in
/// `KGFactStoreTests.swift`.
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

    @Test
    func test_adjectiveBitmap_stateAccessor() {
        // Cookbook §2.3: state at bits 0–5. Contested = raw 2.
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: 2,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.state == .contested)
    }

    @Test
    func test_adjectiveBitmap_stateUnknownRawFallsBackToActive() {
        // Reserved per-cluster gap raw 4 fails closed to .active.
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: 4,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.state == .active)
    }

    @Test
    func test_adjectiveBitmap_sensitivityAccessor() {
        // Cookbook §2.3: sensitivity at bits 6–11. Secret = raw 48 → 48 << 6.
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: Int64(48 << 6),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.adjectiveSensitivity == .secret)
    }

    @Test
    func test_adjectiveBitmap_exportabilityAccessor() {
        // Cookbook §2.3: exportability at bits 12–17. Public = raw 32 → 32 << 12.
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: Int64(32 << 12),
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.exportability == .public_)
    }

    @Test
    func test_adjectiveBitmap_allFourAxesCoexist() {
        // Shared-bitmap conformance vector — mirrors the Rust
        // `all_four_axes_coexist_without_cross_talk` test. Each 6-bit axis
        // carries a distinct non-default value; every accessor must read
        // only its own field (masks/shifts do not bleed into neighbours).
        let bitmap: Int64 = 2                // state  = Contested (raw 2,  bits 0–5)
            | Int64(48 << 6)                 // sens   = Secret    (raw 48, bits 6–11)
            | Int64(32 << 12)                // export = Public    (raw 32, bits 12–17)
            | Int64(3 << 18)                 // trust  = Canonical (raw 3,  bits 18–23)
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: bitmap,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.state == .contested)
        #expect(fact.adjectiveSensitivity == .secret)
        #expect(fact.exportability == .public_)
        #expect(fact.trust == .canonical)
    }

    @Test
    func test_adjectiveBitmap_allAxesDefaultOnZeroBitmap() {
        // Zero bitmap decodes to the fail-closed baseline on every axis —
        // parity with the Rust `defaults_match_swift_initializer` test.
        let fact = KGFact(
            subject: "s", predicate: "p", object: "o", sourceDrawerID: "d",
            adjectiveBitmap: 0,
            filedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(fact.state == .active)
        #expect(fact.adjectiveSensitivity == .normal)
        #expect(fact.exportability == .private_)
        #expect(fact.trust == .verbatim)
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
