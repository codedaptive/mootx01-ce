import Foundation

// MARK: - LexiconMap
//
// The single in-code source of truth for the ARIA-Lexicon → Apple-surface
// mapping. The "Apple Surfaces" tab renders this; the App Intent shells are
// the executable counterparts of the `callerInvokable` rows; and
// LEXICON_TO_APPLE_MAPPING.md is the prose mirror of this same table. When
// Apple's WWDC drop changes a surface, the delta lands in one of three
// places: this table, the matching shell file, and the mapping doc — and the
// reaction-delta section of that doc says which.
//
// The lexicon is fixed (AriaLexiconLib: one noun, nine verbs, four
// adjectives, invariants I-7/I-8). These rows therefore do not churn; only
// their Apple-side projections do.

/// How a verb is driven — who is allowed to invoke it.
public enum VerbFlow: String, Sendable {
    /// The caller initiates: a person, a Shortcut, Siri, an MCP client.
    case callerDriven = "caller-driven"
    /// The Brain layer emits it (standing signals / dreaming). Never a
    /// gateway-invoked tool; surfaces as an MCP notification.
    case brainEmitted = "substrate-driven (Brain-emitted)"
    /// Grounding-driven: ingests a canonical external reference.
    case groundingDriven = "grounding-driven"
}

/// The read/write character of a verb at the Apple surface.
public enum VerbDirection: String, Sendable {
    case read = "READ"
    case write = "WRITE"
    case structural = "STRUCTURAL"
    case none = "—"
}

/// One row of the lexicon→Apple mapping: a single ARIA verb and everything
/// the gateway needs to know to project it onto Apple surfaces.
public struct GatewayVerb: Sendable, Identifiable {
    public var id: String { verb }
    /// The ARIA verb (AriaLexiconLib `Verb`).
    public let verb: String
    public let flow: VerbFlow
    public let direction: VerbDirection
    /// The `moot_*` tool this verb projects to at the ARIA_MCP surface, if a
    /// caller-driven path exists. `nil` for Brain-emitted verbs (no tool).
    public let mootTool: String?
    /// The App Intent type name in this package's `AppIntents/` shell, if one
    /// exists. `nil` where no caller-facing intent is appropriate.
    public let intentType: String?
    /// Apple reach when surfaced (Siri/Spotlight/Shortcuts/Action Button/…).
    public let appleReach: [String]
    /// The x-callback-url path the URL router accepts for this verb, if any.
    public let xCallbackPath: String?
    /// Whether a gateway caller may invoke this verb (false for Brain verbs).
    public let callerInvokable: Bool
    /// One-line note on the mapping's status or a known edge.
    public let note: String
}

/// One adjective axis → its role at the Apple surface.
public struct GatewayAdjective: Sendable, Identifiable {
    public var id: String { axis }
    public let axis: String
    public let values: [String]
    /// How the adjective participates in an intent (parameter, gate, …).
    public let appleRole: String
}

public enum LexiconMap {

    /// The nine verbs, in lexicon order (AriaLexiconLib `Verb.swift`).
    public static let verbs: [GatewayVerb] = [
        GatewayVerb(
            verb: "capture", flow: .callerDriven, direction: .write,
            mootTool: "moot_file_memory", intentType: "CaptureDrawerIntent",
            appleReach: ["Share Sheet", "Shortcuts", "Siri", "Action Button"],
            xCallbackPath: "capture", callerInvokable: true,
            note: "Submit-in (A4b). Verbatim drawer; no propose-gate. Always captured private — see exportability edge."
        ),
        GatewayVerb(
            verb: "recall", flow: .callerDriven, direction: .read,
            mootTool: "moot_memory_search", intentType: "RecallDrawerIntent",
            appleReach: ["Siri", "Spotlight", "Shortcuts", "Action Button"],
            xCallbackPath: "recall", callerInvokable: true,
            note: "Serve-out (A4a/A5). Filtered by export policy; `filter:exportable` gates public rows."
        ),
        GatewayVerb(
            verb: "reanchor", flow: .callerDriven, direction: .structural,
            mootTool: "moot_move_memory", intentType: "ReanchorDrawerIntent",
            appleReach: ["Shortcuts"], xCallbackPath: "reanchor", callerInvokable: true,
            note: "Move where a drawer sits in structure. Shell routed; not yet surfaced to Siri."
        ),
        GatewayVerb(
            verb: "mutate", flow: .callerDriven, direction: .write,
            mootTool: "moot_update_memory", intentType: "MutateDrawerIntent",
            appleReach: ["Shortcuts"], xCallbackPath: "mutate", callerInvokable: true,
            note: "Change a drawer's structural state via a named mutation kind."
        ),
        GatewayVerb(
            verb: "withdraw", flow: .callerDriven, direction: .write,
            mootTool: "moot_withdraw_memory", intentType: "WithdrawDrawerIntent",
            appleReach: ["Shortcuts"], xCallbackPath: "withdraw", callerInvokable: true,
            note: "Retire a drawer; history preserved."
        ),
        GatewayVerb(
            verb: "expunge", flow: .callerDriven, direction: .write,
            mootTool: "moot_erase_memory", intentType: "ExpungeDrawerIntent",
            appleReach: ["Shortcuts"], xCallbackPath: "expunge", callerInvokable: true,
            note: "Irreversible hard-erase. Guarded: requires confirmed:true."
        ),
        GatewayVerb(
            verb: "propose", flow: .brainEmitted, direction: .none,
            mootTool: nil, intentType: nil,
            appleReach: [], xCallbackPath: nil, callerInvokable: false,
            note: "Brain-emitted. NOT a gateway tool — surfaces as an MCP notification (would map to App Intents elicitation later)."
        ),
        GatewayVerb(
            verb: "associate", flow: .brainEmitted, direction: .none,
            mootTool: nil, intentType: nil,
            appleReach: [], xCallbackPath: nil, callerInvokable: false,
            note: "Brain-emitted connective weight. NOT a gateway tool."
        ),
        GatewayVerb(
            verb: "learn", flow: .groundingDriven, direction: .write,
            mootTool: nil, intentType: nil,
            appleReach: [], xCallbackPath: nil, callerInvokable: false,
            note: "Ingest a canonical external reference. A3 consume-other-estate may feed this; no direct Apple intent yet."
        ),
    ]

    /// The four adjectives (AriaLexiconLib `Adjective`, invariant I-8).
    public static let adjectives: [GatewayAdjective] = [
        GatewayAdjective(
            axis: "state",
            values: ["active", "pending", "contested", "superseded", "decayed", "withdrawn", "expired", "rejected", "accepted", "tombstoned"],
            appleRole: "Result/recall context; not a capture parameter."
        ),
        GatewayAdjective(
            axis: "trust",
            values: ["verbatim", "observed", "imported", "proposed", "derived", "canonical"],
            appleRole: "Set by capture channel; surfaced read-only on DrawerEntity."
        ),
        GatewayAdjective(
            axis: "sensitivity",
            values: ["normal", "elevated", "restricted", "secret"],
            appleRole: "Capture parameter (AppEnum) + recall ceiling."
        ),
        GatewayAdjective(
            axis: "exportability",
            values: ["private", "public"],
            appleRole: "Serve-out gate (§6.2): recall `filter:exportable` exposes only public. EDGE: no caller path sets public yet."
        ),
    ]

    /// Verbs a gateway caller may invoke (the intent-shell set).
    public static var callerVerbs: [GatewayVerb] { verbs.filter(\.callerInvokable) }
}
