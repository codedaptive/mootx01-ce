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
// System registration is supplied by MootIntentPackage; linking apps expose
// this intent through their extracted App Intents metadata.

public struct CaptureDrawerIntent: MootEstateIntent {

    public static let title: LocalizedStringResource = "Capture Memory"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(anyAppleOS 27.0, *)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public static let description = IntentDescription(
        "File caller content into the MOOT as a verbatim drawer.",
        categoryName: "Memory"
    )

    /// The content to capture, verbatim. Maps to moot_file_memory `content`.
    @Parameter(title: "Content")
    public var content: String

    /// One sentence (≤120 chars) stating what this memory asserts. Maps to
    /// moot_file_memory `subject` — the field the dense recall row renders,
    /// which is why the tool requires it.
    ///
    /// A Shortcut author is the best subject source this package has: they
    /// know what the automation is capturing and why, so they can write the
    /// assertion rather than an extract of it. Optional with a nil default —
    /// matching the `wing` / `eventTime` precedent below — so every Shortcut
    /// built before this parameter existed keeps working; when it is absent
    /// `perform()` derives one from `content`. The TOOL argument is never
    /// optional: the substrate always receives a subject.
    @Parameter(title: "Subject")
    public var subject: String?

    /// Subject-matter location hint. Maps to moot_file_memory `location`
    /// (the drawer's room).
    @Parameter(title: "Location", default: "memories")
    public var location: String

    /// Access-control sensitivity tier. Maps to moot_file_memory `sensitivity`.
    @Parameter(title: "Sensitivity", default: .normal)
    public var sensitivity: SensitivityAppEnum

    // Ingestion targeting (M-ING-1). The targeting model for miners and
    // Shortcuts recipes: `location` = room (subject matter), `wing` = life
    // area (e.g. "Personal Life"), `eventTime` = when the captured fact was
    // TRUE (mined-history support — a health sample from last Tuesday files
    // with last Tuesday's event_time, not today's). Estate targeting is a
    // future parameter once multi-estate exists; it is deliberately NOT
    // modeled yet. Both parameters are optional with nil defaults so every
    // existing Shortcut, callback URL, and test is unchanged.

    /// Wing to route the drawer into. Maps to moot_file_memory `wing`.
    /// nil = the server default wing ("Agentic Memory").
    @Parameter(title: "Wing")
    public var wing: String?

    /// When the captured content was true, for historical ingestion. Maps to
    /// moot_file_memory `event_time` (ISO8601). nil = now (streaming capture).
    @Parameter(title: "Event Time")
    public var eventTime: Date?

    /// The tool caller injected by the host. `nil` triggers the
    /// `IntentRuntimeBridge.shared.bridge()` fallback so the
    /// system-instantiated Shortcuts path also reaches the live estate.
    public var caller: (any MootToolCalling)?

    public init() {}

    public init(
        content: String,
        location: String = "memories",
        sensitivity: SensitivityAppEnum = .normal,
        wing: String? = nil,
        eventTime: Date? = nil,
        subject: String? = nil,
        caller: (any MootToolCalling)? = nil
    ) {
        self.content = content
        self.location = location
        self.sensitivity = sensitivity
        self.wing = wing
        self.eventTime = eventTime
        self.subject = subject
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        // A Shortcut that fills in the Subject parameter states the assertion
        // itself; one that leaves it empty gets a subject derived from the
        // content's leading sentence. The derivation is the weaker of the two
        // (an extract, not an assertion) — the improvement path for any
        // automation that matters is to set the Subject parameter, not to make
        // the derivation smarter.
        let resolvedSubject = CaptureSubject.resolve(supplied: subject, body: content)
        var arguments: [String: JSONValue] = [
            "content": .string(content),
            "subject": .string(resolvedSubject),
            "location": .string(location),
            "sensitivity": .string(sensitivity.rawValue),
        ]
        if let wing, !wing.isEmpty {
            arguments["wing"] = .string(wing)
        }
        if let eventTime {
            // moot_file_memory expects ISO8601 text (schema invariant: dates
            // are TEXT, never epoch numbers).
            arguments["event_time"] = .string(
                ISO8601DateFormatter().string(from: eventTime)
            )
        }
        let result = await c.callTool("moot_file_memory", arguments: arguments)
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
