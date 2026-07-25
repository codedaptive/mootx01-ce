import CoreGraphics

// MARK: - UIAdaptivity (FAB5-L1)
//
// Layout constants for iPad regular-width size-class adaptivity.
// Views that fill full-width on iPhone cap and center their content at
// readableContentMaxWidth on wider screens. modalCTAMaxWidth caps action
// buttons in fullscreen-cover flows (onboarding) so they never span a
// 1024pt+ iPad screen.
//
// Bit assignments and schema invariants do not apply here (GatewayUI only,
// no persisted entity). UIAdaptivity is a pure layout namespace.
enum UIAdaptivity {
    // Maximum width for main content VStacks on regular-width layouts (iPad).
    // Keeps line lengths within the ergonomic 45–75 character window at body
    // font size. Views apply this as frame(maxWidth:) with a centering wrapper.
    static let readableContentMaxWidth: CGFloat = 720

    // Maximum width for CTA buttons in modal/onboarding contexts.
    // Prevents the "Get Started" and similar primary actions from spanning
    // the full width of an iPad Pro landscape screen (~1366pt).
    static let modalCTAMaxWidth: CGFloat = 400
}
