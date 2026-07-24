import Testing
@testable import GatewayUI

// MARK: - iPad size-class adaptivity constants (FAB5-L1)
//
// Verifies the UIAdaptivity constants that drive iPad regular-width layout
// adaptivity. These are not rendering tests — they assert the layout contract
// so an accidental widening past ergonomic bounds fails the suite.

@Suite("iPad size-class adaptivity (FAB5-L1)")
struct iPadAdaptivityTests {

    // readableContentMaxWidth keeps line lengths within the ergonomic range
    // at body font size. It must be narrower than iPad portrait width (1024pt)
    // so content never fills the full screen.
    @Test("readable content max width is narrower than iPad Pro portrait width")
    func readableWidthFitsPortrait() {
        // iPad Pro 12.9" portrait = 1024pt logical points.
        #expect(UIAdaptivity.readableContentMaxWidth < 1024)
    }

    // modalCTAMaxWidth prevents onboarding CTA buttons from spanning a full
    // iPad landscape screen. It must fit inside iPad mini portrait (768pt).
    @Test("modal CTA max width fits inside iPad mini portrait width")
    func modalCTAFitsMiniPortrait() {
        // iPad mini portrait = 768pt logical points.
        #expect(UIAdaptivity.modalCTAMaxWidth < 768)
    }

    // Sanity: readable area is wider than a modal CTA — content column is
    // always wider than a single action button.
    @Test("readable content width is wider than modal CTA width")
    func readableWiderThanCTA() {
        #expect(UIAdaptivity.readableContentMaxWidth > UIAdaptivity.modalCTAMaxWidth)
    }
}
