import Foundation
import Testing
@testable import LocusKit

/// Cookbook §2.4 + §2.8 verification-table conformance gate for the
/// Drawer operational bitmap constants LocusKit owns: CaptureChannel,
/// ContentKind, DrawerFeatureFlags, state-extension flag, and the
/// lineage-clustering flag (NEW in v0.6).
///
/// Cookbook §2.8: "Implementations MUST surface this table as an
/// automated conformance test that fails when a source constant
/// deviates from spec." This file enforces that gate for the
/// operational layout.
///
/// F12 cascade (2026-05-27): added after the v0.6 raw-value migration
/// to lock the new constants in place.
///
/// Note: Tunnel/KGFact/Diary operational bitmaps are LocusKit-internal
/// layouts not specified by cookbook §2.4 v0.6. Their tests live in
/// their respective Tests/LocusKitTests files (`TunnelBitmapTests.swift`,
/// `TunnelKindTests.swift`, `TunnelTests.swift`, `KGFactStoreTests.swift`,
/// `DiaryOperationalTests.swift`) and are not gated by this conformance file.
@Suite("OperationalBitmapConformanceTests")
struct OperationalBitmapConformanceTests {

    // MARK: - CaptureChannel (cookbook §2.4 bits 0-5)

    private static let captureChannelTable: [(channel: CaptureChannel, expectedRaw: Int)] = [
        (.typed,        0),
        (.voiced,       1),
        (.ocr,          2),
        (.importedFile, 3),
        (.sensor,       4),
        (.actuator,     5),    // NEW in v0.6
    ]

    @Test("CaptureChannel raw values match cookbook §2.4")
    func captureChannelRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.captureChannelTable {
            if entry.channel.rawValue != entry.expectedRaw {
                mismatches.append("CaptureChannel.\(entry.channel) expected raw=\(entry.expectedRaw), got \(entry.channel.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "CaptureChannel diverges from cookbook §2.4:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("CaptureChannel field lives at bits 0-5 (cookbook §2.4)")
    func captureChannelFieldPosition() {
        for entry in Self.captureChannelTable {
            let bitmap = Int64(entry.expectedRaw)  // bits 0-5
            let drawer = Drawer(
                content: "c", parentNodeId: "test-parent", addedBy: "test",
                filedAt: Date(timeIntervalSince1970: 0),
                embeddingModelID: "minilm-v6",
                operationalBitmap: bitmap
            )
            #expect(drawer.captureChannel == entry.channel,
                "bitmap=\(bitmap) should decode to \(entry.channel)")
        }
    }

    // MARK: - ContentKind (cookbook §2.4 bits 6-11)

    private static let contentKindTable: [(kind: ContentKind, expectedRaw: Int)] = [
        (.prose,           0),
        (.code,            1),
        (.transcript,      2),
        (.list,            3),
        (.structuredJSON,  4),
        (.imageCaption,    5),
        (.fingerprintOnly, 6),   // NEW in v0.6
    ]

    @Test("ContentKind raw values match cookbook §2.4")
    func contentKindRawValuesMatchTable() {
        var mismatches: [String] = []
        for entry in Self.contentKindTable {
            if entry.kind.rawValue != entry.expectedRaw {
                mismatches.append("ContentKind.\(entry.kind) expected raw=\(entry.expectedRaw), got \(entry.kind.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "ContentKind diverges from cookbook §2.4:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("ContentKind field lives at bits 6-11 (cookbook §2.4)")
    func contentKindFieldPosition() {
        for entry in Self.contentKindTable {
            let bitmap = Int64(entry.expectedRaw) << 6
            let drawer = Drawer(
                content: "c", parentNodeId: "test-parent", addedBy: "test",
                filedAt: Date(timeIntervalSince1970: 0),
                embeddingModelID: "minilm-v6",
                operationalBitmap: bitmap
            )
            #expect(drawer.contentKind == entry.kind,
                "bitmap=\(bitmap) (\(entry.expectedRaw) << 6) should decode to \(entry.kind)")
        }
    }

    // MARK: - DrawerFeatureFlags (cookbook §2.4 bits 12-23)

    private static let featureFlagTable: [(flag: DrawerFeatureFlags, expectedBit: Int)] = [
        (.hasAttachments, 12),
        (.hasVoice,       13),
        (.hasImage,       14),
        (.hasLinks,       15),
        (.isPinned,       16),
        (.isKeystone,     17),   // NEW in v0.6
        (.isLockedZone,   18),   // NEW in v0.6
    ]

    @Test("DrawerFeatureFlags bit positions match cookbook §2.4")
    func featureFlagBitPositionsMatchTable() {
        var mismatches: [String] = []
        for entry in Self.featureFlagTable {
            let expected: Int64 = 1 << entry.expectedBit
            if entry.flag.rawValue != expected {
                mismatches.append("\(entry.flag) expected bit \(entry.expectedBit) (=\(expected)), got rawValue=\(entry.flag.rawValue)")
            }
        }
        if !mismatches.isEmpty {
            Issue.record(Comment(rawValue: "DrawerFeatureFlags diverges from cookbook §2.4:\n" + mismatches.joined(separator: "\n")))
        }
    }

    @Test("featureFlags accessor masks the bits 12-23 region")
    func featureFlagsAccessorMasksField() {
        // Set bit 0 (capture_channel.voiced) and bit 30 (out-of-field) AND a real flag bit.
        let bitmap: Int64 = 0x1 | (1 << 30) | DrawerFeatureFlags.hasImage.rawValue
        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            operationalBitmap: bitmap
        )
        // Accessor should only return bits 12-23.
        #expect(drawer.featureFlags.rawValue == DrawerFeatureFlags.hasImage.rawValue,
            "featureFlags accessor leaked bits outside 12-23")
    }

    // MARK: - State-extension + lineage-clustering flags (cookbook §2.4 bits 24, 25)

    @Test("state_extension flag lives at bit 24 (cookbook §2.4)")
    func stateExtensionAtBit24() {
        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            operationalBitmap: 1 << 24
        )
        #expect(drawer.stateExtensionActive)
        #expect(!drawer.lineageClusteringActive, "bit 24 must not trigger lineage_clustering")
    }

    @Test("lineage_clustering flag lives at bit 25 (NEW in v0.6 per cookbook §2.4)")
    func lineageClusteringAtBit25() {
        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            operationalBitmap: 1 << 25
        )
        #expect(drawer.lineageClusteringActive)
        #expect(!drawer.stateExtensionActive, "bit 25 must not trigger state_extension")
    }

    // MARK: - Full composite (all axes simultaneously)

    /// captureChannel=.ocr(2) | contentKind=.code(1)<<6 | hasImage(1<<14) | isPinned(1<<16)
    /// = 2 | 0x40 | 0x4000 | 0x10000 = 0x14042.
    @Test("Composite operational bitmap round-trips through all accessors (cookbook §2.4)")
    func compositeOperationalRoundtrip() {
        let raw: Int64 =
            Int64(CaptureChannel.ocr.rawValue)
            | (Int64(ContentKind.code.rawValue) << 6)
            | DrawerFeatureFlags.hasImage.rawValue
            | DrawerFeatureFlags.isPinned.rawValue
        #expect(raw == 0x14042, "composite encoding mismatch: \(raw) != 0x14042")

        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            operationalBitmap: raw
        )
        #expect(drawer.captureChannel == .ocr)
        #expect(drawer.contentKind == .code)
        #expect(drawer.featureFlags.contains(.hasImage))
        #expect(drawer.featureFlags.contains(.isPinned))
        #expect(!drawer.stateExtensionActive)
        #expect(!drawer.lineageClusteringActive)
    }
}
