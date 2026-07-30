import Foundation
import Testing
@testable import LocusKit

/// Wave-2 vague-tier bitmap geometry (AC-1 from SPEC_CONSOLIDATION_VAGUE_RECALL §7).
///
/// Verifies bit positions, accessor correctness, and the bitmap invariants
/// specified in cookbook §2.4.2 for the three new fields:
///   - is_vague (bit 20)
///   - represented_by_vague (bit 21)
///   - vague_level 2-bit sub-field (bits 22–23)
///
/// AC-1 asserts evaluator-exclusion correctness. The episodic-lane invariant
/// tested here is: the `.currentAndVague` default tier filter is transparent
/// for all pre-Wave-2 drawers (bit-21 = 0), and correct for post-Wave-2
/// drawers (bit-21 = 1 excluded, bit-20 = 1 included alongside ordinary rows).
///
/// Pure value tests — no DrawerStore required.
@Suite("VagueTierBitmapTests — cookbook §2.4.2 bit geometry (AC-1)")
struct VagueTierBitmapTests {

    // MARK: - DrawerFeatureFlags constants (cookbook §2.4.2)

    @Test("isVague OptionSet member occupies bit 20 (raw = 0x100000)")
    func isVague_isBit20() {
        // Cookbook §2.4.2: is_vague = bit 20, mask = 0x100000.
        #expect(DrawerFeatureFlags.isVague.rawValue == 0x100000)
        #expect(DrawerFeatureFlags.isVague.rawValue == (1 << 20))
    }

    @Test("representedByVague OptionSet member occupies bit 21 (raw = 0x200000)")
    func representedByVague_isBit21() {
        // Cookbook §2.4.2: represented_by_vague = bit 21, mask = 0x200000.
        #expect(DrawerFeatureFlags.representedByVague.rawValue == 0x200000)
        #expect(DrawerFeatureFlags.representedByVague.rawValue == (1 << 21))
    }

    @Test("vague_level sub-field occupies bits 22–23 (mask = 0xC00000, shift = 22)")
    func vagueLevel_bitsAre22to23() {
        // Cookbook §2.4.2: vague_level = 2-bit sub-field, shift 22, mask 0xC00000.
        // Bits 22-23 → width 2 at shift 22 → mask (0x3 << 22) = 0xC00000.
        let mask: Int64 = 0xC00000
        let shift: Int64 = 22
        // Level 1: bit 22 set.
        let level1: Int64 = 1 << shift
        #expect((level1 & mask) >> shift == 1)
        // Level 2: bit 23 set (binary 10 in 2-bit field = value 2).
        let level2: Int64 = 2 << shift
        #expect((level2 & mask) >> shift == 2)
        // Level 3: raw value 3 in 2-bit field (maps to clamped 2).
        let level3raw: Int64 = 3 << shift
        #expect((level3raw & mask) >> shift == 3)
    }

    @Test("bits 20–21 are independent — setting one does not affect the other")
    func vagueAndAbsorbedBitsAreIndependent() {
        let both: Int64 = DrawerFeatureFlags.isVague.rawValue
            | DrawerFeatureFlags.representedByVague.rawValue
        #expect((both & DrawerFeatureFlags.isVague.rawValue) != 0)
        #expect((both & DrawerFeatureFlags.representedByVague.rawValue) != 0)
        // isVague alone.
        let vagueOnly = DrawerFeatureFlags.isVague.rawValue
        #expect((vagueOnly & DrawerFeatureFlags.representedByVague.rawValue) == 0)
        // representedByVague alone.
        let absorbedOnly = DrawerFeatureFlags.representedByVague.rawValue
        #expect((absorbedOnly & DrawerFeatureFlags.isVague.rawValue) == 0)
    }

    // MARK: - Drawer computed accessors (cookbook §2.4.2)

    @Test("Drawer.isVague reads bit 20 correctly")
    func drawerIsVague_decodesBit20() {
        let d = makeDrawer(opBitmap: DrawerFeatureFlags.isVague.rawValue)
        #expect(d.isVague == true)
        let n = makeDrawer(opBitmap: 0)
        #expect(n.isVague == false)
    }

    @Test("Drawer.representedByVague reads bit 21 correctly")
    func drawerRepresentedByVague_decodesBit21() {
        let d = makeDrawer(opBitmap: DrawerFeatureFlags.representedByVague.rawValue)
        #expect(d.representedByVague == true)
        let n = makeDrawer(opBitmap: 0)
        #expect(n.representedByVague == false)
    }

    @Test("Drawer.vagueLevel reads bits 22–23 correctly for levels 0–3 and clamps 3→2")
    func drawerVagueLevel_extractsAndClamps() {
        let shift = 22
        // Level 0: bits 22-23 clear.
        #expect(makeDrawer(opBitmap: 0).vagueLevel == 0)
        // Level 1: bit 22 set.
        #expect(makeDrawer(opBitmap: Int64(1 << shift)).vagueLevel == 1)
        // Level 2: bits 22-23 set (raw = 2).
        #expect(makeDrawer(opBitmap: Int64(2 << shift)).vagueLevel == 2)
        // Level 3 (raw = 3): clamp to 2 per §5.4 cap invariant.
        #expect(makeDrawer(opBitmap: Int64(3 << shift)).vagueLevel == 2,
                "vagueLevel must clamp raw value 3 to 2 per §5.4 / D8")
    }

    @Test("All three fields can coexist in the same operationalBitmap without interference")
    func allVagueFieldsCoexist() {
        // is_vague=1, represented_by_vague=1, vague_level=1 in a single bitmap.
        let composite: Int64 = DrawerFeatureFlags.isVague.rawValue
            | DrawerFeatureFlags.representedByVague.rawValue
            | Int64(1 << 22)
        let d = makeDrawer(opBitmap: composite)
        #expect(d.isVague == true)
        #expect(d.representedByVague == true)
        #expect(d.vagueLevel == 1)
    }

    // MARK: - AC-1 evaluator geometry (invariant 6.1 both ways)
    //
    // The `.currentAndVague` predicate is (operationalBitmap & 0x200000) == 0.
    // For all pre-Wave-2 drawers (bit-21 = 0), this is always true — transparent.
    // For absorbed constituents (bit-21 = 1), this is always false — excluded.
    // For vague items (bit-20 = 1, bit-21 = 0), this is true — included.

    @Test("AC-1: pre-Wave-2 drawer (both bits clear) passes .currentAndVague (transparent)")
    func preWave2Drawer_passesCurrentAndVague() {
        // bit-21 = 0 → (op & 0x200000) == 0 → passes
        let op: Int64 = 0
        #expect((op & DrawerFeatureFlags.representedByVague.rawValue) == 0)
    }

    @Test("AC-1: absorbed constituent (bit-21 = 1) fails .currentAndVague (excluded)")
    func absorbedConstituent_failsCurrentAndVague() {
        // bit-21 = 1 → (op & 0x200000) != 0 → excluded
        let op: Int64 = DrawerFeatureFlags.representedByVague.rawValue
        #expect((op & DrawerFeatureFlags.representedByVague.rawValue) != 0)
    }

    @Test("AC-1: vague item (bit-20 = 1, bit-21 = 0) passes .currentAndVague (included)")
    func vagueItem_passesCurrentAndVague() {
        // bit-20 = 1, bit-21 = 0 → (op & 0x200000) == 0 → passes
        let op: Int64 = DrawerFeatureFlags.isVague.rawValue
        #expect((op & DrawerFeatureFlags.representedByVague.rawValue) == 0,
                "vague item has bit-20 set but bit-21 clear — passes currentAndVague")
    }

    @Test("AC-1: .currentOnly excludes both vague items and absorbed constituents")
    func currentOnly_excludesVagueBits() {
        let vagueOp = DrawerFeatureFlags.isVague.rawValue
        let absorbedOp = DrawerFeatureFlags.representedByVague.rawValue
        let normalOp: Int64 = 0
        let mask = DrawerFeatureFlags.isVague.rawValue | DrawerFeatureFlags.representedByVague.rawValue
        // Only the normal drawer passes currentOnly.
        #expect((normalOp & mask) == 0)
        #expect((vagueOp & mask) != 0,
                "vague item fails .currentOnly — bit 20 disqualifies it")
        #expect((absorbedOp & mask) != 0,
                "absorbed constituent fails .currentOnly — bit 21 disqualifies it")
    }

    @Test("AC-1: .vagueOnly includes only is_vague items")
    func vagueOnly_includesOnlyBit20Items() {
        let vagueOp = DrawerFeatureFlags.isVague.rawValue
        let absorbedOp = DrawerFeatureFlags.representedByVague.rawValue
        let normalOp: Int64 = 0
        #expect((vagueOp & DrawerFeatureFlags.isVague.rawValue) != 0)
        #expect((absorbedOp & DrawerFeatureFlags.isVague.rawValue) == 0)
        #expect((normalOp & DrawerFeatureFlags.isVague.rawValue) == 0)
    }

    // MARK: - Helpers

    private func makeDrawer(opBitmap: Int64) -> Drawer {
        Drawer(
            id: UUID().uuidString,
            content: "vague tier test",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: Date(timeIntervalSince1970: 1_000_000),
            embeddingModelID: "test-model-v1",
            operationalBitmap: opBitmap
        )
    }
}
