import Foundation
import AppIntents

// MARK: - DrawerEntity
//
// The noun `Drawer` projected as an App Intents `AppEntity`, so Siri,
// Spotlight, and Shortcuts can carry a memory between steps and the system
// can index it. This is a SHELL: it compiles and conforms fully, but it is
// only discovered by the system once an Xcode app bundle declares this
// package's intents. In this app it is constructed directly from recall
// results and exercised in-process.
//
// Mapping (see LEXICON_TO_APPLE_MAPPING.md, Noun section):
//   Drawer.id        → AppEntity.id (stable across recall/Spotlight/chaining)
//   Drawer.content   → DisplayRepresentation title/subtitle
//   Drawer.room      → a property the recall intent can group by
//   the 4 adjectives → read-only properties (capture sets them; not user-set here)

public struct DrawerEntity: AppEntity, Identifiable, Sendable {

    /// Stable drawer id (LocusKit `Drawer.id`). The contract that lets a
    /// Shortcut recall a drawer in one step and act on it in the next.
    public let id: String

    /// Verbatim content preview. A drawer's content is immutable at its core;
    /// what we carry here is exactly what was captured.
    @Property(title: "Content")
    public var content: String

    /// Structural location (the drawer's room).
    @Property(title: "Location")
    public var room: String

    public init(id: String, content: String, room: String) {
        self.id = id
        self.content = content
        self.room = room
    }

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memory"

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(content)",
            subtitle: "\(room)"
        )
    }

    public static let defaultQuery = DrawerEntityQuery()
}

// MARK: - DrawerEntityQuery
//
// App Intents requires an EntityQuery so the system can resolve an entity by
// id (e.g. re-hydrating a drawer a Shortcut saved earlier). SHELL behavior:
// it routes through the bridge's recall, but the current tool surface returns
// text rather than structured drawers (see the "tool results are text" edge),
// so by-id resolution is best-effort and may return nothing. The real
// implementation needs a structured recall-by-id tool — flagged, not faked.

public struct DrawerEntityQuery: EntityQuery {

    public init() {}

    /// Resolve entities by id. Shell: returns empty until a structured
    /// recall-by-id exists on the tool surface. Documented, not silently
    /// returning wrong data.
    public func entities(for identifiers: [String]) async throws -> [DrawerEntity] {
        // No structured by-id recall is projected to the tool surface yet.
        // Returning [] is the honest shell answer; see GatewayEdges.findings.
        []
    }

    /// Suggested entities for pickers. Shell: empty for the same reason.
    public func suggestedEntities() async throws -> [DrawerEntity] {
        []
    }
}

// MARK: - SensitivityAppEnum
//
// The `sensitivity` adjective surfaced as a Shortcuts-pickable parameter. The
// raw values match the tool surface's decodeSensitivity strings exactly, so
// the enum case carries straight through to moot_file_memory with no mapping.

public enum SensitivityAppEnum: String, AppEnum, Sendable {
    case normal
    case elevated
    case restricted
    case secret

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sensitivity"

    public static let caseDisplayRepresentations: [SensitivityAppEnum: DisplayRepresentation] = [
        .normal: "Normal",
        .elevated: "Elevated",
        .restricted: "Restricted",
        .secret: "Secret",
    ]
}
