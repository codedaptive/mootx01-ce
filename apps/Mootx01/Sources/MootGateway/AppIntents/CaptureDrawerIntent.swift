import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - CaptureDrawerIntent  (verb: capture · A4b submit-in · WRITE)
//
// The submit-in leg: bring caller content into the MOOT as a verbatim drawer.
// `capture` is a caller-driven core verb (invariant I-7) — there is no
// dreaming/propose gate on it, so this works the moment an app bundle
// registers it. perform() routes through the same in-process ARIA tool
// surface (moot_file_memory) every other adapter uses; nothing here reaches
// around the dispatcher into the substrate.
//
// SHELL status: compiles and runs in-process (the app's "Apple Surfaces"
// tab and the test target invoke perform() directly). Not Siri-discoverable
// until an Xcode app bundle declares this package's AppIntentsPackage.

public struct CaptureDrawerIntent: AppIntent {

    public static let title: LocalizedStringResource = "Capture Memory"

    public static let description = IntentDescription(
        "File caller content into the MOOT as a verbatim drawer.",
        categoryName: "Memory"
    )

    /// The content to capture, verbatim. Maps to moot_file_memory `content`.
    @Parameter(title: "Content")
    public var content: String

    /// Subject-matter location hint. Maps to moot_file_memory `location`
    /// (the drawer's room).
    @Parameter(title: "Location", default: "memories")
    public var location: String

    /// Access-control sensitivity tier. Maps to moot_file_memory `sensitivity`.
    @Parameter(title: "Sensitivity", default: .normal)
    public var sensitivity: SensitivityAppEnum

    public init() {}

    public init(content: String, location: String = "memories", sensitivity: SensitivityAppEnum = .normal) {
        self.content = content
        self.location = location
        self.sensitivity = sensitivity
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = try await GatewayRuntime.shared.bridge()
        let call = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(content),
            "location": .string(location),
            "sensitivity": .string(sensitivity.rawValue),
        ])
        if call.isError {
            throw GatewayIntentError.substrateRefused(call.text)
        }
        return .result(dialog: IntentDialog(stringLiteral: call.text))
    }
}

// MARK: - GatewayIntentError

/// Surfaces a substrate refusal (a tools/call result with isError) as a
/// thrown intent error, so Shortcuts shows the reason rather than a silent
/// success.
public enum GatewayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case substrateRefused(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .substrateRefused(let why):
            return "The MOOT refused the operation: \(why)"
        }
    }
}
