import Foundation
import Testing
@testable import LocusKit

/// Operational bitmap coverage — enum raw values per spec § 5.6,
/// the four-axis composite encoding (capture_channel, content_kind,
/// feature_flags, state_extension_flag), and the default-zero
/// behavior of `Drawer.operationalBitmap` for callers that omit
/// the parameter.
///
/// `operationalBitmap` persistence is implemented in `DrawerStore`
/// and covered by the store-level test suites. This file exercises
/// pure value types — enum raw values, bit-extraction accessors,
/// OptionSet membership, and Codable equality — without touching
/// DrawerStore.
@Suite("DrawerOperationalTests")
struct DrawerOperationalTests {

    // MARK: - CaptureChannel raw values (spec § 5.6)

    @Test("CaptureChannel raw values 0…5 per cookbook §2.4 (actuator NEW in v0.6)")
    func captureChannelRawValues() {
        #expect(CaptureChannel.typed.rawValue == 0)
        #expect(CaptureChannel.voiced.rawValue == 1)
        #expect(CaptureChannel.ocr.rawValue == 2)
        #expect(CaptureChannel.importedFile.rawValue == 3)
        #expect(CaptureChannel.sensor.rawValue == 4)
        #expect(CaptureChannel.actuator.rawValue == 5)
    }

    // MARK: - ContentKind raw values (spec § 5.6)

    @Test("ContentKind raw values 0…6 per cookbook §2.4 (fingerprintOnly NEW in v0.6)")
    func contentKindRawValues() {
        #expect(ContentKind.prose.rawValue == 0)
        #expect(ContentKind.code.rawValue == 1)
        #expect(ContentKind.transcript.rawValue == 2)
        #expect(ContentKind.list.rawValue == 3)
        #expect(ContentKind.structuredJSON.rawValue == 4)
        #expect(ContentKind.imageCaption.rawValue == 5)
        #expect(ContentKind.fingerprintOnly.rawValue == 6)
    }

    // MARK: - DrawerFeatureFlags bit positions (spec § 5.6)

    @Test("DrawerFeatureFlags occupy bits 12–18 with cookbook §2.4 values")
    func featureFlagBitPositions() {
        #expect(DrawerFeatureFlags.hasAttachments.rawValue == 0x1000)   // bit 12
        #expect(DrawerFeatureFlags.hasVoice.rawValue       == 0x2000)   // bit 13
        #expect(DrawerFeatureFlags.hasImage.rawValue       == 0x4000)   // bit 14
        #expect(DrawerFeatureFlags.hasLinks.rawValue       == 0x8000)   // bit 15
        #expect(DrawerFeatureFlags.isPinned.rawValue       == 0x10000)  // bit 16
        #expect(DrawerFeatureFlags.isKeystone.rawValue     == 0x20000)  // bit 17 NEW
        #expect(DrawerFeatureFlags.isLockedZone.rawValue   == 0x40000)  // bit 18 NEW
    }

    // MARK: - Composite bitmap encoding (spec § 5.6)

    /// Hand-verified composite under cookbook §2.4: captureChannel=.ocr(2)
    /// at bits 0–5, contentKind=.code(1) at bits 6–11, featureFlags=
    /// [.hasImage, .isPinned] at bits 14 + 16.
    /// 2 | (1 << 6) | (1 << 14) | (1 << 16) = 0x14042.
    @Test("Composite bitmap encodes all three axes at 0x14042 (cookbook §2.4)")
    func compositeBitmap() {
        let raw: Int64 =
            Int64(CaptureChannel.ocr.rawValue)
            | (Int64(ContentKind.code.rawValue) << 6)
            | DrawerFeatureFlags.hasImage.rawValue
            | DrawerFeatureFlags.isPinned.rawValue
        #expect(raw == 0x14042)

        let drawer = makeDrawer(operationalBitmap: raw)
        #expect(drawer.operationalBitmap == 0x14042)
    }

    @Test("captureChannel accessor decodes bits 0–5 per cookbook §2.4")
    func captureChannelAccessor() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(drawer.captureChannel == .ocr)
    }

    @Test("contentKind accessor decodes bits 6–11 per cookbook §2.4")
    func contentKindAccessor() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(drawer.contentKind == .code)
    }

    @Test("featureFlags accessor decodes bits 12–23 as OptionSet per cookbook §2.4")
    func featureFlagsAccessor() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(drawer.featureFlags.contains(.hasImage))
        #expect(drawer.featureFlags.contains(.isPinned))
        #expect(!drawer.featureFlags.contains(.hasAttachments))
        #expect(!drawer.featureFlags.contains(.hasVoice))
        #expect(!drawer.featureFlags.contains(.hasLinks))
        #expect(!drawer.featureFlags.contains(.isKeystone))
        #expect(!drawer.featureFlags.contains(.isLockedZone))
    }

    @Test("hasFeatureFlag returns true only when the bit is set")
    func hasFeatureFlagPredicate() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(drawer.hasFeatureFlag(.hasImage))
        #expect(drawer.hasFeatureFlag(.isPinned))
        #expect(!drawer.hasFeatureFlag(.hasAttachments))
        #expect(!drawer.hasFeatureFlag(.hasVoice))
        #expect(!drawer.hasFeatureFlag(.hasLinks))
        #expect(!drawer.hasFeatureFlag(.isKeystone))
        #expect(!drawer.hasFeatureFlag(.isLockedZone))
    }

    // MARK: - State-extension flag (spec § 10.1)

    @Test("stateExtensionActive is true when bit 24 is set (cookbook §2.4)")
    func stateExtensionActiveTrue() {
        let drawer = makeDrawer(operationalBitmap: 1 << 24)
        #expect(drawer.stateExtensionActive)
    }

    @Test("stateExtensionActive is false when bit 24 is clear")
    func stateExtensionActiveFalse() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(!drawer.stateExtensionActive)
    }

    @Test("lineageClusteringActive is true when bit 25 is set (NEW in v0.6)")
    func lineageClusteringActiveTrue() {
        let drawer = makeDrawer(operationalBitmap: 1 << 25)
        #expect(drawer.lineageClusteringActive)
    }

    @Test("lineageClusteringActive is false when bit 25 is clear")
    func lineageClusteringActiveFalse() {
        let drawer = makeDrawer(operationalBitmap: 0x14042)
        #expect(!drawer.lineageClusteringActive)
    }

    // MARK: - Default-zero behavior

    /// A Drawer constructed without `operationalBitmap` carries the zero
    /// field, and every operational accessor returns its zero-mapped
    /// case (`.typed` / `.prose` / empty flags / stateExtensionActive=false).
    @Test("Default-zero operational bitmap yields all-zero accessors")
    func defaultZero() {
        let drawer = Drawer(
            content: "c",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
        #expect(drawer.operationalBitmap == 0)
        #expect(drawer.captureChannel == .typed)
        #expect(drawer.contentKind == .prose)
        #expect(drawer.featureFlags.isEmpty)
        #expect(!drawer.hasFeatureFlag(.hasAttachments))
        #expect(!drawer.hasFeatureFlag(.hasVoice))
        #expect(!drawer.hasFeatureFlag(.hasImage))
        #expect(!drawer.hasFeatureFlag(.hasLinks))
        #expect(!drawer.hasFeatureFlag(.isPinned))
        #expect(!drawer.hasFeatureFlag(.isKeystone))
        #expect(!drawer.hasFeatureFlag(.isLockedZone))
        #expect(!drawer.stateExtensionActive)
        #expect(!drawer.lineageClusteringActive)
    }

    // MARK: - Helpers

    private func makeDrawer(operationalBitmap: Int64) -> Drawer {
        Drawer(
            content: "c",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6",
            operationalBitmap: operationalBitmap
        )
    }
}
