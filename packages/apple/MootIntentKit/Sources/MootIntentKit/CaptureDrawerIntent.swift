import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - CaptureDrawerIntent  (verb: capture · A4b submit-in · WRITE)
//
// The submit-in leg: bring caller content into the MOOT as a verbatim drawer.
// `capture` is a caller-driven core verb (invariant I-7) — there is no
// dreaming/propose gate on it. perform() routes through the same in-process
// ARIA tool surface (moot_file_memory) every other adapter uses; nothing here
// reaches around the dispatcher into the substrate.
//
// System registration: this intent is a live iOS-native capability. It is not
// yet registered with the system Shortcuts catalog because that requires an
// Xcode app bundle to declare this package's AppIntentsPackage — a packaging
// step, not a capability gap. perform() runs correctly today in-process and
// in tests against a real estate.

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

    /// The tool caller injected by the host. `nil` triggers the
    /// `IntentRuntimeBridge.shared.bridge()` fallback so the
    /// system-instantiated Shortcuts path also reaches the live estate.
    public var caller: (any MootToolCalling)?

    public init() {}

    public init(
        content: String,
        location: String = "memories",
        sensitivity: SensitivityAppEnum = .normal,
        caller: (any MootToolCalling)? = nil
    ) {
        self.content = content
        self.location = location
        self.sensitivity = sensitivity
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        let result = await c.callTool("moot_file_memory", arguments: [
            "content": .string(content),
            "location": .string(location),
            "sensitivity": .string(sensitivity.rawValue),
        ])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(dialog: IntentDialog(stringLiteral: result.text))
    }

    /// Resolve the caller: use the injected one (tests / in-process hosts),
    /// or fall back to the shared runtime bridge (system-instantiated path).
    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}
