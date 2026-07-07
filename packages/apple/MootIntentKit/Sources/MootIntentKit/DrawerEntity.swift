import Foundation
import AppIntents

// MARK: - DrawerEntity
//
// The noun `Drawer` projected as an App Intents `AppEntity` so Siri,
// Spotlight, and Shortcuts can carry a memory between steps and the system
// can index it. Compiles and conforms fully; system discovery requires an
// Xcode app bundle that declares this package's intents — that is a
// packaging step, not a capability gap. The intent code itself is complete.
//
// Mapping (see LEXICON_TO_APPLE_MAPPING.md, Noun section):
//   Drawer.id        → AppEntity.id (stable across recall/Spotlight/chaining)
//   Drawer.content   → DisplayRepresentation title/subtitle
//   Drawer.room      → a property the recall intent can group by
//   the 4 adjectives → read-only properties (capture sets them; not user-set here)

public struct DrawerEntity: AppEntity, Identifiable, Sendable {

    /// Stable drawer id (LocusKit `Drawer.id`). Lets a Shortcut recall a
    /// drawer in one step and act on it in the next.
    public let id: String

    /// Content preview from recall results. Carries the recall preview text
    /// (up to 120 characters); not guaranteed to be the verbatim full capture.
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

// MARK: - SyncableEntity (M-MXA-1)
//
// Declares to the system that DrawerEntity.id is STABLE across devices, so
// Siri can carry a drawer through a conversation that hops devices (App
// Intents 2027 wave, wwdc2026-345). The id is the LocusKit `Drawer.id`
// estate UUID: minted once at capture, identical on every device that opens
// the estate (sync/vault replication copies rows verbatim; ids are never
// re-minted). Because local id == stable id, no
// `SyncableEntityIdentifier<LocalID, StableID>` pairing is needed — that
// type exists for entities whose on-device ids differ per device (e.g.
// CoreData row ids). If a device-local drawer id scheme is ever introduced,
// this conformance must be revisited before it ships.
//
// Availability-gated rather than raising the package's platform floor:
// MootIntentKit stays at macOS/iOS 26 (Bob ruling 2026-07-07 — app moves to
// the 2027 wave, support kits stay on 26); the app targets 27, so the
// conformance is always live in the app.
@available(macOS 27.0, iOS 27.0, *)
extension DrawerEntity: SyncableEntity {}

// MARK: - DrawerEntityQuery
//
// App Intents requires an EntityQuery so the system can resolve an entity by
// id (e.g. re-hydrating a drawer a Shortcut saved earlier).
//
// Resolution strategy: `moot_memory_search` text response lines carry the UUID,
// room, and a content preview (up to 120 chars) in the format
// `<uuid>  [<room>]  <content>`. The gateway-layer parser in
// MootToolCalling.parseDrawerLines extracts typed DrawerEntity values from
// those lines — no new ARIA surface needed.
//
// By-id resolution (`entities(for:)`) runs one recall per identifier with the
// UUID string as the query, then filters for an exact id match. This is best-
// effort: the BM25+vector recall will surface the drawer by id if it is in the
// estate. If the drawer has been expunged or the estate is empty, the result is
// [] for that id — which is the correct, honest behavior.
//
// The caller is resolved through IntentRuntimeBridge.shared (the same fallback
// all intents use when the host has registered a bridge at launch).

public struct DrawerEntityQuery: EntityQuery {

    public init() {}

    /// Resolve entities by id. Runs a recall for each identifier and filters
    /// for an exact UUID match. Returns an empty array for ids not found.
    ///
    /// Identifiers are validated as UUID-format before being passed to the
    /// search engine. A non-UUID string could widen the BM25 search scope
    /// beyond the intended drawer; UUID validation constrains the query to
    /// well-formed structural identifiers only.
    public func entities(for identifiers: [String]) async throws -> [DrawerEntity] {
        guard let caller = try? await IntentRuntimeBridge.shared.bridge() else { return [] }
        var results: [DrawerEntity] = []
        for id in identifiers {
            // UUID validation: reject malformed or crafted identifiers before
            // they reach the BM25 search path (Perkins Advisory 2).
            guard UUID(uuidString: id) != nil else { continue }
            // Query by the UUID string. moot_memory_search surfaces the drawer
            // by id via the structural BM25 lane if it is in the estate.
            let hits = await caller.recallDrawers(query: id, limit: 5)
            // Exact-match filter: only the drawer whose id is exactly the
            // requested identifier belongs in the response. Prevents false
            // matches where a different drawer's content contains the UUID string.
            if let match = hits.first(where: { $0.id == id }) {
                results.append(match)
            }
        }
        return results
    }

    /// Suggested entities for Shortcuts pickers: the 20 most-recent drawers
    /// from the estate, returned as typed DrawerEntity values.
    public func suggestedEntities() async throws -> [DrawerEntity] {
        guard let caller = try? await IntentRuntimeBridge.shared.bridge() else { return [] }
        // An empty query returns recent drawers via the structural/BM25 lane.
        return await caller.recallDrawers(query: "", limit: 20)
    }
}

// MARK: - SensitivityAppEnum
//
// The `sensitivity` adjective surfaced as a Shortcuts-pickable parameter.
// Raw values match the tool surface's decodeSensitivity strings exactly, so
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
