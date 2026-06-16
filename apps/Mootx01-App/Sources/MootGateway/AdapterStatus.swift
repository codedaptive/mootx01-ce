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
    /// The implementation is complete and runs correctly in-process. It is
    /// not yet registered with the system (Siri, Spotlight, the Shortcuts
    /// catalog) because system registration requires the Xcode app bundle
    /// packaging step — not a capability gap, a packaging step.
    case pendingRegistration = "pending registration"
    /// Deliberately deferred to v1.1 by Bob's ruling. The shape is defined
    /// and the guard is in place; the outbound path is not built in beta.
    case deferredToV1_1 = "v1.1"
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
                   why: "Loopback-HTTP transport IS implemented (URLSession POST to 127.0.0.1 daemon; see Transport/GatewayTransport.swift). What is not yet done is Bonjour/LAN discovery (NSBonjourServices, Local Network entitlement). A2 stays .seam because the transport is not yet registered as the default path — the capability gap is LAN discovery, not HTTP."),
        AdapterRow(code: "A3", name: "Consume other estates (MCP client)", state: .deferredToV1_1,
                   why: "Outbound federation (MOOT-to-MOOT: reading another estate and folding it in) is a v1.1 surface by Bob's ruling. The fold-in path via capture IS real (MootEstateClient.foldIn). The outbound fetch is deliberately not built in beta — MootEstateClient.fetch throws outboundFederationNotInThisVersion as a guard."),
        AdapterRow(code: "A4", name: "App Intents (Siri/Spotlight/Shortcuts)", state: .pendingRegistration,
                   why: "Six live verb intents in MootIntentKit, all routed through the ARIA tool surface in-process. Mootx01Shortcuts.updateAppShortcutParameters() is called at every app launch to refresh donated phrases. System registration (Siri phrases, Shortcuts catalog) activates when xcodegen regenerates the Xcode project and the app bundle is built — that Xcode project build step is outside SPM."),
        AdapterRow(code: "A5", name: "Callback URL (x-callback-url)", state: .pendingRegistration,
                   why: "MootURLRouter parses and routes correctly (tested). CFBundleURLTypes for the mootx01:// scheme is declared in project.yml (the xcodegen spec). System URL-scheme registration activates when xcodegen regenerates the Xcode project and the app bundle is built."),
        AdapterRow(code: "A6", name: "Shortcuts catalog donation", state: .pendingRegistration,
                   why: "Mootx01Shortcuts (the app-target AppShortcutsProvider) donates capture and recall phrases; MootShortcutsProvider in MootIntentKit donates all six. updateAppShortcutParameters() is called at launch. Phrases appear in the Shortcuts app once the xcodegen-derived app bundle is built and installed."),
    ]

    public static let findings: [EdgeFinding] = [
        EdgeFinding(
            title: "CaptureView exportability Picker is live — private or public at capture time",
            detail: "The capture screen exposes an Exportability Picker (private / public). Choosing \"public\" passes exportability:\"public\" to moot_file_memory and stamps the drawer's adjective bitmap at birth. The read-side gate (filter:exportable) returns those drawers correctly. moot_update_memory correctExportability(public) remains the promotion path for drawers already captured as private."
        ),
        EdgeFinding(
            title: "Tool surface exposes far less than the substrate can filter",
            detail: "The bitmap evaluator filters on state, sensitivity, sensitivityAtMost, room, contentMatches, createdAfter/Before, lineage, exportable, contained. The moot_memory_search tool exposes only four named filters (unconfirmed, userConfirmed, exportable, contained). Rich recall is reachable in-process but not projected to callers."
        ),
        EdgeFinding(
            title: "DrawerEntity recall wired via gateway-layer text parse",
            detail: "moot_memory_search response lines carry the format \"<uuid>  [<room>]  <content preview>\". MootToolCalling.parseDrawerLines extracts typed DrawerEntity values from these lines at the gateway layer — no new ARIA tool needed. DrawerEntityQuery.entities(for:) and suggestedEntities() are now wired. Content is a preview (up to 120 chars from the tool); full content is not yet returned in the search path."
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
