import Foundation
import SwiftUI
import MootGateway
import MootIntentKit   // intent types: CaptureDrawerIntent, RecallDrawerIntent, CallerVerbIntents
import AriaMCP         // JSONValue (for reading tools/list schemas)
import OSLog

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

    // First-run flag — shown once; UserDefaults-backed so it survives app restarts.
    // Default false (not completed). Set to true when onboarding is dismissed or skipped.
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "com.mootx01.gateway.hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "com.mootx01.gateway.hasCompletedOnboarding") }
    }

    // Tab profile — false = Standard (Capture/Recall/Intelligence/Settings only);
    // true = Advanced (Standard + engineering tabs). Default Standard.
    var isAdvancedMode: Bool = UserDefaults.standard.bool(forKey: "com.mootx01.gateway.isAdvancedMode") {
        didSet { UserDefaults.standard.set(isAdvancedMode, forKey: "com.mootx01.gateway.isAdvancedMode") }
    }

    // Lifecycle
    public private(set) var bridge: MootBridge?
    var statusLine: String = "Not attached"
    var databasePath: String?

    // Capture tab
    var captureContent: String = "MOOTx01 projects ARIA onto Apple surfaces."
    var captureLocation: String = "gateway"
    var captureSensitivity: String = "normal"
    /// Exportability of the next capture: "private" (default) or "public".
    /// "public" drawers are returned by filter:exportable recall (§6.2 serve-out gate).
    var captureExportability: String = "private"
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
    /// The two exportability choices; raw values match the moot_file_memory tool vocabulary.
    let exportabilityOptions = ["private", "public"]

    public init() {}

    /// Attach the shared bridge over a durable SQLite estate, then preload the
    /// tool surface for "The Top".
    public func start() async {
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
        let probe = await bridge.callToolFull("moot_memory_search", arguments: ["query": .string("MOOTx01")])
        guard probe.text.contains("found 0") else { return }
        let samples = [
            ("MOOTx01 projects ARIA onto Apple surfaces — Siri, Spotlight, Shortcuts.", "gateway"),
            ("The engine is the clean, Rust-mirrored server; the app envelopes it.", "architecture"),
            ("One estate, one host: embedded server-in-app, or a handed-off daemon.", "architecture"),
        ]
        for (content, room) in samples {
            _ = await bridge.callToolFull("moot_file_memory", arguments: [
                "content": .string(content), "location": .string(room),
            ])
        }
    }

    /// `<Application Support>/mootx01/mootx01.sqlite`. Cross-platform:
    /// on macOS this is ~/Library/Application Support/…; on iOS it is the app
    /// sandbox container, so each install gets its own estate.
    /// (`homeDirectoryForCurrentUser` is macOS-only, so it is not used here.)
    static func defaultDatabaseURL() -> URL {
        EstateConfigurationResolver.defaultDatabaseURL()
    }

    // MARK: Capture / Recall

    func doCapture() async {
        guard let bridge else { return }
        lastCaptureCall = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string(captureContent),
            "location": .string(captureLocation),
            "sensitivity": .string(captureSensitivity),
            // exportability: "private" (default, omitting is equivalent) or "public".
            // "public" lets this drawer surface via filter:exportable recall (A4a serve-out gate).
            "exportability": .string(captureExportability),
        ])
    }

    func doRecall() async {
        guard let bridge else { return }
        var arguments: [String: JSONValue] = ["query": .string(recallQuery)]
        if recallPublicOnly {
            arguments["filter"] = .string("exportable")
        }
        lastRecallCall = await bridge.callToolFull("moot_memory_search", arguments: arguments)
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

    // MARK: Apple Surfaces — run an intent in-process

    /// Invoke any of the six caller-driven verb intents against the live shared
    /// estate. All six run in-process today; system registration (Siri,
    /// Shortcuts catalog) requires the Xcode app bundle packaging step.
    /// The structural verbs (reanchor/mutate/withdraw/expunge) use the most
    /// recently filed drawer's id from the run log, falling back to a sentinel
    /// value when none is available (the substrate will reject the sentinel and
    /// report the refusal as a logged error, which is the correct behavior).
    func runIntent(_ verb: String) async {
        do {
            switch verb {
            case "capture":
                // Route through the bridge directly (same path CaptureDrawerIntent
                // uses internally) so the tool-response text is available here to
                // extract the drawer id. The response first line is always
                // "filed memory <UUID>" (ToolDispatch.runFileMemory), which lets
                // subsequent structural verbs (reanchor/mutate/withdraw/expunge)
                // resolve the id via lastLoggedID() without a sentinel fall-back.
                guard let b = bridge else { throw IntentToolError.substrateRefused("no bridge attached") }
                let captureResult = await b.callTool("moot_file_memory", arguments: [
                    "content": .string("Captured via the CaptureDrawerIntent at \(timestamp())."),
                    "location": .string("apple-surfaces"),
                ])
                if captureResult.isError { throw IntentToolError.substrateRefused(captureResult.text) }
                // Log the first line of the result ("filed memory <UUID>") verbatim
                // so lastLoggedID() can extract the UUID via a standard UUID pattern.
                let resultFirstLine = captureResult.text.components(separatedBy: "\n").first ?? captureResult.text
                intentRunLog.insert("capture: \(resultFirstLine) — filed into the live estate.", at: 0)

            case "recall":
                _ = try await RecallDrawerIntent(query: "apple-surfaces").perform()
                intentRunLog.insert("recall: RecallDrawerIntent.perform() ran — results returned as IntentResult.", at: 0)

            case "reanchor":
                // Uses the last-captured id extracted from the run log, or a
                // sentinel that the substrate will reject with a clear error.
                let id = lastLoggedID() ?? "no-id-captured-yet"
                _ = try await ReanchorDrawerIntent(id: id, location: "apple-surfaces-reanchored").perform()
                intentRunLog.insert("reanchor: ReanchorDrawerIntent.perform() ran for id=\(id).", at: 0)

            case "mutate":
                let id = lastLoggedID() ?? "no-id-captured-yet"
                _ = try await MutateDrawerIntent(id: id, mutation: "confirm").perform()
                intentRunLog.insert("mutate: MutateDrawerIntent.perform() ran (confirm) for id=\(id).", at: 0)

            case "withdraw":
                let id = lastLoggedID() ?? "no-id-captured-yet"
                _ = try await WithdrawDrawerIntent(id: id).perform()
                intentRunLog.insert("withdraw: WithdrawDrawerIntent.perform() ran for id=\(id).", at: 0)

            case "expunge":
                // Runs with confirmed=false so the view-layer test does not
                // permanently erase data. The substrate must refuse; the refusal
                // is logged to confirm the confirmation guard is active.
                // To actually erase, the Shortcuts flow prompts confirmed=true.
                let id = lastLoggedID() ?? "no-id-captured-yet"
                do {
                    _ = try await ExpungeDrawerIntent(id: id, reason: "in-process test", confirmed: false).perform()
                    intentRunLog.insert("expunge: performed (substrate accepted confirmed=false — confirmation guard may be missing).", at: 0)
                } catch {
                    // Expected: the substrate refuses confirmed=false. Log the
                    // refusal so the operator can see the guard is working.
                    intentRunLog.insert("expunge: substrate refused confirmed=false (confirmation guard active) — \(error).", at: 0)
                }
                return  // Already inserted the log line above; skip the catch below.

            default:
                intentRunLog.insert("\(verb): no in-process path wired.", at: 0)
            }
        } catch {
            intentRunLog.insert("\(verb): intent threw — \(error)", at: 0)
        }
    }

    /// Extract the most recently captured drawer id from the run log, if any.
    ///
    /// The capture log line written by `runIntent("capture")` includes the
    /// substrate's response first line verbatim, which is always in the form
    /// `"filed memory <UUID>"` (see `ToolDispatch.runFileMemory`). This method
    /// scans `intentRunLog` newest-first (index 0 is newest, inserted at 0)
    /// for a UUID pattern adjacent to that prefix and returns the first match.
    /// Returns nil when no capture has been logged yet.
    /// Internal (not private) so the `GatewayUITests` target can reach it via
    /// `@testable import GatewayUI`. The function has no behavior that needs
    /// external visibility — internal is the minimum required for testability.
    func lastLoggedID() -> String? {
        // The UUID pattern per RFC 4122: eight-four-four-four-twelve hex digits.
        let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let regex = try? Regex(uuidPattern) else { return nil }
        for line in intentRunLog {
            guard line.hasPrefix("capture:") else { continue }
            if let match = line.firstMatch(of: regex) {
                return String(line[match.range])
            }
        }
        return nil
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: URL routing (A5 — x-callback-url)

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "AppModel")

    /// Route an inbound x-callback-url through MootURLRouter. Called from
    /// the view layer's `.onOpenURL` modifier. The router enforces a verb
    /// allowlist (capture/recall/reanchor only) and a callback-scheme
    /// allowlist (empty here — the host does not auto-open return URLs;
    /// the caller is responsible for checking the returnURL in its own process).
    /// See MootURLRouter for the full security rationale.
    func handleOpenURL(_ url: URL) async {
        guard let bridge else {
            Self.log.error("handleOpenURL: no bridge attached, dropping \(url.absoluteString, privacy: .public)")
            return
        }
        // Empty permitted-callback-schemes: the app never opens a return URL
        // on the caller's behalf — prevents open-redirect abuse where a crafted
        // x-success could cause the app to open an arbitrary URL.
        let router = MootURLRouter(permittedCallbackSchemes: [])
        let outcome = await router.route(url, using: bridge)
        switch outcome {
        case .routed(_, let text, let isError):
            Self.log.info("x-callback-url routed: isError=\(isError, privacy: .public) result=\(text.prefix(80), privacy: .public)")
        case .notHandled(let reason):
            Self.log.info("x-callback-url not handled: \(reason, privacy: .public)")
        }
    }
}
