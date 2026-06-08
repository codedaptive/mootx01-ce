import Foundation

// MARK: - AdapterStatus / Edges
//
// The honest readout of the gateway: which adapters are live, which are seams,
// which are shells, and the concrete edges discovered while wiring it. This is
// data, not prose, so the Edges tab and any future report read the same source.

/// How far along one adapter is.
public enum AdapterState: String, Sendable {
    /// Working end-to-end in this app.
    case live = "live"
    /// A typed seam exists; the real implementation lands elsewhere/later.
    case seam = "seam"
    /// A compiling shell whose perform() routes through the bridge, but which
    /// is not yet system-registered (needs an Xcode app bundle).
    case shell = "shell"
}

/// One of the six gateway adapters (A1–A6 from the gateway spec).
public struct AdapterRow: Sendable, Identifiable {
    public var id: String { code }
    public let code: String          // A1…A6
    public let name: String
    public let state: AdapterState
    public let why: String
}

/// A concrete seam discovered while building — the things you can only learn
/// by wiring it, not by reading the spec.
public struct EdgeFinding: Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let detail: String
}

public enum GatewayEdges {

    public static let adapters: [AdapterRow] = [
        AdapterRow(code: "A1", name: "Embedded (in-process)", state: .live,
                   why: "GeniusLocusKit opened in-process, driven via the ARIA tool surface. This is the live, working path."),
        AdapterRow(code: "A2", name: "ARIA_MCP server on this device", state: .seam,
                   why: "Dispatcher runs in-process, but there is no HTTP/Bonjour transport here — only stdio exists in ARIA_MCP. The loopback-HTTP/SSE transport is planned as a separate transport workstream. LAN clients can't reach this app yet."),
        AdapterRow(code: "A3", name: "Consume other estates (MCP client)", state: .shell,
                   why: "A separate client component (ARIA is always the server — it never acts as a client). Shell only; folds results in via capture/learn."),
        AdapterRow(code: "A4", name: "App Intents (Siri/Spotlight/Shortcuts)", state: .shell,
                   why: "Real compiling AppIntent/AppEntity types routed to the bridge; not system-registered until an Xcode app bundle wraps them."),
        AdapterRow(code: "A5", name: "Callback URL (x-callback-url)", state: .shell,
                   why: "MootURLRouter parses and routes; URL-scheme registration needs an app bundle Info.plist."),
        AdapterRow(code: "A6", name: "Shortcuts library", state: .shell,
                   why: "AppShortcutsProvider donating the A4 intents; surfaces once the bundle registers."),
    ]

    public static let findings: [EdgeFinding] = [
        EdgeFinding(
            title: "Export policy is half-wired",
            detail: "The adjective bitmap has exportability (private=0 / public=32) and recall exposes filter:exportable — but capture (moot_file_memory / CaptureFrame) has no exportability slot and MutationKind has no set-exportability case. So nothing can be marked public through the tool surface: a recall with filter:exportable returns empty. The serve-out gate (§6.2) exists on the read side with no write side to feed it."
        ),
        EdgeFinding(
            title: "Tool surface exposes far less than the substrate can filter",
            detail: "The bitmap evaluator filters on state, sensitivity, sensitivityAtMost, room, contentMatches, createdAfter/Before, lineage, exportable, contained. The moot_memory_search tool exposes only four named filters (unconfirmed, userConfirmed, exportable, contained). Rich recall is reachable in-process but not projected to callers."
        ),
        EdgeFinding(
            title: "Tool results are text, not structured nouns",
            detail: "moot_file_memory / moot_memory_search return MCP text content blocks (\"filed memory <id>\", \"found N memory(s)\"), not a structured Drawer. An App Intent that wants a typed DrawerEntity result must either parse text or call a (not-yet-existing) structured recall. The app renders text and notes the gap."
        ),
        EdgeFinding(
            title: "propose / associate have no caller path by design",
            detail: "Two of the nine verbs are Brain-emitted; they are not tools and cannot be invoked from any Apple surface. The natural Apple home for them is App Intents *elicitation* (confirm a proposal) — a post-WWDC mapping, not a callable verb."
        ),
        EdgeFinding(
            title: "Estate binding is per-process, single default",
            detail: "ToolDispatcher binds one default estate; multi-estate routing exists via an optional estateID arg. An Apple app hosting several MOOTs (per-app domains) would drive estateID per intent — the seam is present but this app uses one estate."
        ),
    ]
}
