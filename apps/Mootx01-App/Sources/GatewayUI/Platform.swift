import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform shims
//
// The gateway UI is shared verbatim between the macOS executable and the iOS
// app. Only two spots are platform-specific — a pasteboard write and an
// editor-field background color. They live here behind #if so every view file
// stays platform-neutral.

extension Color {
    /// A recessed field/code background that reads correctly on both platforms.
    static var gatewayEditorField: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

/// Copy text to the system pasteboard. macOS uses NSPasteboard; iOS UIPasteboard.
@MainActor
func gatewayCopyToPasteboard(_ text: String) {
    #if os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
