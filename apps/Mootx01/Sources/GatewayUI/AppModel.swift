import Foundation
import SwiftUI
import MootGateway
import AriaMCP   // JSONValue (for reading tools/list schemas)

// MARK: - AppModel
//
// The single observable model behind the five tabs, shared verbatim by the
// macOS executable and the iOS app. It owns no substrate logic — it drives
// `MootBridge` (through GatewayRuntime so the App Intent shells share the same
// estate) and holds the rendered results. Every action keeps the full
// GatewayCall (request + response JSON) so the views can show the wire, which
// is the whole point: see the top-level communication.

/// One tool descriptor pulled from `tools/list`, grouped for display.
struct ToolDescriptor: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let schemaPretty: String
    let group: String
}

@MainActor
@Observable
public final class AppModel {

    // Lifecycle
    public private(set) var bridge: MootBridge?
    var statusLine: String = "Not attached"
    var databasePath: String?

    // Capture tab
    var captureContent: String = "MOOTx01 projects ARIA onto Apple surfaces."
    var captureLocation: String = "gateway"
    var captureSensitivity: String = "normal"
    var lastCaptureCall: GatewayCall?

    // Recall tab
    var recallQuery: String = "ARIA"
    var recallPublicOnly: Bool = false
    var lastRecallCall: GatewayCall?

    // The Top tab
    var tools: [ToolDescriptor] = []

    // Apple Surfaces tab — results of running an intent shell in-process
    var intentRunLog: [String] = []

    let sensitivityOptions = ["normal", "elevated", "restricted", "secret"]

    public init() {}

    /// Attach the shared bridge over a durable SQLite estate, then preload the
    /// tool surface for "The Top".
    public func start() async {
        let url = Self.defaultDatabaseURL()
        await GatewayRuntime.shared.configure(databaseURL: url)
        do {
            let attached = try await GatewayRuntime.shared.bridge()
            bridge = attached
            databasePath = attached.databasePath
            statusLine = "Attached · \(attached.serverName) · \(attached.databasePath ?? "in-memory")"
            await loadTools()
            await seedIfEmpty(attached)
        } catch {
            statusLine = "Attach failed: \(error)"
        }
    }

    /// Ship-with-sample-data: on first launch (empty estate) file a few sample
    /// drawers so the app has content to show. A prebuilt bundled `.sqlite`
    /// would achieve the same; seeding on first launch is simpler and keeps the
    /// estate in the user's own container.
    private func seedIfEmpty(_ bridge: MootBridge) async {
        let probe = await bridge.callTool("moot_memory_search", arguments: ["query": .string("MOOTx01")])
        guard probe.text.contains("found 0") else { return }
        let samples = [
            ("MOOTx01 projects ARIA onto Apple surfaces — Siri, Spotlight, Shortcuts.", "gateway"),
            ("The engine is the clean, Rust-mirrored server; the app envelopes it (ADR-005).", "architecture"),
            ("One estate, one host: embedded server-in-app, or a handed-off daemon.", "architecture"),
        ]
        for (content, room) in samples {
            _ = await bridge.callTool("moot_file_memory", arguments: [
                "content": .string(content), "location": .string(room),
            ])
        }
    }

    /// `<Application Support>/mootx01/mootx01.sqlite`. Cross-platform:
    /// on macOS this is ~/Library/Application Support/…; on iOS it is the app
    /// sandbox container, so each install gets its own estate.
    /// (`homeDirectoryForCurrentUser` is macOS-only, so it is not used here.)
    static func defaultDatabaseURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("mootx01/mootx01.sqlite")
    }

    // MARK: Capture / Recall

    func doCapture() async {
        guard let bridge else { return }
        lastCaptureCall = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(captureContent),
            "location": .string(captureLocation),
            "sensitivity": .string(captureSensitivity),
        ])
    }

    func doRecall() async {
        guard let bridge else { return }
        var arguments: [String: JSONValue] = ["query": .string(recallQuery)]
        if recallPublicOnly {
            arguments["filter"] = .string("exportable")
        }
        lastRecallCall = await bridge.callTool("moot_memory_search", arguments: arguments)
    }

    // MARK: The Top — tool surface

    func loadTools() async {
        guard let bridge else { return }
        let list = await bridge.toolsList()
        let entries = list.objectValue?["tools"]?.arrayValue ?? []
        tools = entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            let description = object["description"]?.stringValue ?? ""
            let schema = object["inputSchema"].map(MootBridge.pretty) ?? "{}"
            return ToolDescriptor(
                name: name,
                description: description,
                schemaPretty: schema,
                group: Self.group(for: name)
            )
        }
    }

    private static func group(for name: String) -> String {
        if name.hasPrefix("moot_lens_") { return "Reasoning lenses" }
        if name.hasPrefix("moot_vault_") { return "Vault" }
        if name.contains("fact") { return "Knowledge graph" }
        if name.contains("connection") || name.contains("link") { return "Connections" }
        if name.contains("journal") { return "Journal" }
        if name.contains("estate") { return "Estate" }
        if name.contains("lens") || name.contains("synthesize") || name.contains("migration") { return "Recipes" }
        return "Core memory"
    }

    /// Tool groups in a stable display order.
    var toolGroups: [(String, [ToolDescriptor])] {
        let order = ["Core memory", "Connections", "Knowledge graph", "Journal", "Estate", "Recipes", "Reasoning lenses", "Vault"]
        let grouped = Dictionary(grouping: tools, by: \.group)
        return order.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            return (key, items)
        }
    }

    // MARK: Apple Surfaces — run an intent shell in-process

    /// Invoke a real App Intent's perform() against the live shared estate,
    /// proving the shell runs before any app bundle registers it.
    func runIntent(_ verb: String) async {
        do {
            switch verb {
            case "capture":
                _ = try await CaptureDrawerIntent(
                    content: "Captured via the CaptureDrawerIntent shell at \(timestamp()).",
                    location: "apple-surfaces"
                ).perform()
                intentRunLog.insert("✓ CaptureDrawerIntent.perform() ran — drawer filed into the live estate.", at: 0)
            case "recall":
                _ = try await RecallDrawerIntent(query: "apple-surfaces").perform()
                intentRunLog.insert("✓ RecallDrawerIntent.perform() ran against the live estate (result returned as IntentResult).", at: 0)
            default:
                intentRunLog.insert("· No runnable shell wired for \(verb).", at: 0)
            }
        } catch {
            intentRunLog.insert("✘ \(verb) intent threw: \(error)", at: 0)
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
