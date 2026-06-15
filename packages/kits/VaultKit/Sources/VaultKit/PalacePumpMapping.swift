import Foundation

// PalacePumpMapping.swift — builds the per-item MemPalace `add_drawer`
// arguments from one `NoteIR`.
//
// This fixes the benchmarker TransferEngine's GAP A (it wrote CONTENT ONLY
// plus fixed constant args, identical for every item). The pump instead
// derives wing + room + source_file PER ITEM from each note, and folds the
// unmappable fields into the content via PalacePayloadEnvelope.
//
// ## The native arg surface (verified against the live tool)
//
// `mempalace_add_drawer` required: `wing`, `room`, `content`.
// Optional metadata: `source_file`, `added_by`. (tools/list, v3.3.3.)
//
// ## Per-item mapping
//
//   wing        ← pathComponents.first, sanitized; estate-level fallback
//   room        ← pathComponents.second (or .last beyond the wing), sanitized;
//                 a default room when the hierarchy is one level or flat
//   content     ← PalacePayloadEnvelope.encode(body, payload)   [GAP-A fix:
//                 body is per-item, plus the lossless envelope]
//   source_file ← stableSourceKey (the idempotency key; lets a human trace
//                 the drawer back to its origin note)
//   added_by    ← a constant pump actor id (provenance, not per-item)
//
// MemPalace derives the drawer id from wing/room + a content hash, and
// dedups on it (verified: a repeat add returns the same id with
// reason "already_exists"). So a stable per-item wing/room/content makes the
// pump idempotent on the target side too: re-running the pump does not
// duplicate drawers.

/// The MemPalace `add_drawer` arguments for one note: the native arg values
/// plus the encoded content. Plain strings (the wire layer wraps them in
/// JSON), `Equatable` so the arg-building test asserts an exact mapping.
public struct PalaceDrawerArgs: Sendable, Equatable {
    /// The `wing` argument — the project/top-level grouping.
    public let wing: String
    /// The `room` argument — the aspect/sub-grouping.
    public let room: String
    /// The `content` argument — verbatim body plus the fenced envelope.
    public let content: String
    /// The `source_file` metadata argument — the note's stable source key.
    public let sourceFile: String
    /// The `added_by` metadata argument — the pump actor id (provenance).
    public let addedBy: String

    public init(wing: String, room: String, content: String, sourceFile: String, addedBy: String) {
        self.wing = wing
        self.room = room
        self.content = content
        self.sourceFile = sourceFile
        self.addedBy = addedBy
    }
}

/// The MemPalace call a ``PalaceItem`` maps to: the tool name and its
/// argument map. The four-noun generalization of ``PalaceDrawerArgs`` — where
/// `PalaceDrawerArgs` is the drawer-only `NoteIR` shape, `PalaceCall` carries
/// any noun's tool + native args (the envelope is already folded into whichever
/// arg carries the noun's text). `Equatable` so the arg-building vectors assert
/// an exact mapping across the Swift and Rust ports.
public struct PalaceCall: Sendable, Equatable, Codable {
    /// The MemPalace MCP tool name (e.g. `mempalace_add_drawer`).
    public let tool: String
    /// The native arguments for the call, keyed by the MemPalace arg name.
    public let arguments: [String: PalaceJSONValue]

    public init(tool: String, arguments: [String: PalaceJSONValue]) {
        self.tool = tool
        self.arguments = arguments
    }
}

/// Pure mapping from a `NoteIR` to MemPalace `add_drawer` arguments. No
/// instances — a function namespace. Deterministic and byte-identical across
/// the Swift and Rust ports.
public enum PalacePumpMapping {

    /// The `added_by` provenance value every pumped drawer carries.
    public static let pumpActor = "mootx01-pump"

    /// The wing assigned when a note has no path hierarchy to derive one
    /// from. The estate placement is unknown at the IR level, so a single
    /// stable bucket keeps such notes addressable.
    public static let defaultWing = "mootx01"

    /// The room assigned when the hierarchy is flat or one level deep (only a
    /// wing, no aspect).
    public static let defaultRoom = "general"

    /// Build the `add_drawer` arguments for one note.
    ///
    /// - Parameters:
    ///   - note: the source note.
    /// - Returns: the per-item arguments, with the unmappable fields folded
    ///   into `content` via ``PalacePayloadEnvelope``.
    /// - Throws: rethrows ``PalacePayloadEnvelope`` encode failures (a JSON
    ///   encoding error on the payload).
    public static func makeArgs(for note: NoteIR) throws -> PalaceDrawerArgs {
        let (wing, room) = placement(for: note)
        let payload = PalaceEnvelopePayload(from: note)
        let content = try PalacePayloadEnvelope.encode(body: note.flattenedBody, payload: payload)
        // source_file traces the drawer back to its origin note; never empty
        // (stableSourceKey is a required NoteIR field).
        let sourceFile = note.stableSourceKey.isEmpty ? "unknown" : note.stableSourceKey
        return PalaceDrawerArgs(
            wing: wing,
            room: room,
            content: content,
            sourceFile: sourceFile,
            addedBy: pumpActor
        )
    }

    /// Derive (wing, room) from a note's `pathComponents`, sanitizing each so
    /// the values are valid MemPalace identifiers. The mapping:
    ///
    ///   []                         → (defaultWing, defaultRoom)
    ///   [a]                        → (a, defaultRoom)
    ///   [a, b]                     → (a, b)
    ///   [a, b, c, ...]             → (a, joined(b...) )  — deeper levels are
    ///                                joined into the room with "/" so the
    ///                                hierarchy below the wing is preserved in
    ///                                the room name AND (losslessly) in the
    ///                                envelope's pathComponents.
    ///
    /// Sanitizing maps whitespace and path separators that MemPalace's id
    /// derivation would mangle to single hyphens; an empty result falls back
    /// to the default. Pure and deterministic.
    static func placement(for note: NoteIR) -> (wing: String, room: String) {
        let parts = note.pathComponents
        switch parts.count {
        case 0:
            return (defaultWing, defaultRoom)
        case 1:
            let w = sanitize(parts[0])
            return (w.isEmpty ? defaultWing : w, defaultRoom)
        default:
            let w = sanitize(parts[0])
            // Everything below the wing joins into the room with "/", keeping
            // the visible hierarchy; the exact components also survive in the
            // envelope, so this is a human-readable view, not the lossy layer.
            let roomRaw = parts[1...].map(sanitize).filter { !$0.isEmpty }.joined(separator: "/")
            return (
                w.isEmpty ? defaultWing : w,
                roomRaw.isEmpty ? defaultRoom : roomRaw
            )
        }
    }

    /// Sanitize one path component into a MemPalace-safe identifier fragment:
    /// trim, lowercase nothing (MemPalace ids are case-preserving), collapse
    /// runs of whitespace to a single hyphen, and drop characters outside a
    /// conservative set. Returns "" when nothing survives (caller substitutes
    /// the default).
    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for scalar in raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if scalar == "_" || scalar == "-" {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = (scalar == "-")
            } else {
                // whitespace / separators / punctuation → a single hyphen
                if !lastWasHyphen && !out.isEmpty {
                    out.append("-")
                    lastWasHyphen = true
                }
            }
        }
        // Trim a trailing hyphen the collapse may have left.
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Four-noun mapping (drawer / tunnel / KG fact / diary)
    //
    // The four MemPalace tools the canonical pump drives. Verified against the
    // live server's tools/list (v3.3.3). For each noun the mapper picks the
    // tool, builds native args from the item's `nativeFields`, and folds the
    // `envelopeFields` into whichever native arg persists the noun's text — so
    // every non-native field survives and a re-import recovers the full noun.

    /// MemPalace `mempalace_add_drawer` — the drawer write tool.
    public static let addDrawerTool = "mempalace_add_drawer"
    /// MemPalace `mempalace_create_tunnel` — the tunnel write tool.
    public static let createTunnelTool = "mempalace_create_tunnel"
    /// MemPalace `mempalace_kg_add` — the KG-fact write tool.
    public static let kgAddTool = "mempalace_kg_add"
    /// MemPalace `mempalace_diary_write` — the diary write tool.
    public static let diaryWriteTool = "mempalace_diary_write"
    /// MemPalace `mempalace_get_drawer` — the drawer read-back tool (verify).
    public static let getDrawerTool = "mempalace_get_drawer"

    /// Build the MemPalace call for one ``PalaceItem``. Dispatches on the
    /// noun; the envelope is folded into the noun's text-bearing arg. Pure and
    /// byte-identical across the Swift and Rust ports.
    ///
    /// - Throws: rethrows ``PalacePayloadEnvelope`` encode failures.
    public static func call(for item: PalaceItem) throws -> PalaceCall {
        switch item.noun {
        case .drawer: return try drawerCall(item)
        case .tunnel: return try tunnelCall(item)
        case .kgFact: return try kgFactCall(item)
        case .diaryEntry: return try diaryCall(item)
        }
    }

    /// Drawer → `add_drawer(wing, room, content+envelope, added_by)`. The
    /// envelope rides `content` (add_drawer stores content verbatim), so every
    /// drawer metadata field survives and a fetch-by-id recovers the full noun.
    private static func drawerCall(_ item: PalaceItem) throws -> PalaceCall {
        let wing = item.nativeFields["wing"]?.stringValue ?? "wing_moot"
        let room = item.nativeFields["room"]?.stringValue ?? "imported"
        let content = try PalacePayloadEnvelope.encodeFields(body: item.body, fields: item.envelopeFields)
        return PalaceCall(tool: addDrawerTool, arguments: [
            "wing": .string(wing),
            "room": .string(room),
            "content": .string(content),
            // Provenance marker so a MemPalace operator can see what filed it.
            "added_by": .string(PalacePumpMapping.pumpActor),
        ])
    }

    /// Tunnel → `create_tunnel(endpoints, label+envelope)`. create_tunnel has
    /// no free-text body; the envelope rides `label`. The human label stays the
    /// visible prefix (envelopeFields carries no `label`), then the marker +
    /// JSON follow. The tunnel's kind and bitmaps — which create_tunnel cannot
    /// carry — are thereby preserved.
    private static func tunnelCall(_ item: PalaceItem) throws -> PalaceCall {
        var args: [String: PalaceJSONValue] = [:]
        // Endpoints map natively.
        for key in ["source_wing", "source_room", "target_wing", "target_room",
                    "source_drawer_id", "target_drawer_id"] {
            if let v = item.nativeFields[key] { args[key] = v }
        }
        let humanLabel = item.nativeFields["label"]?.stringValue ?? ""
        args["label"] = .string(
            try PalacePayloadEnvelope.encodeFields(body: humanLabel, fields: item.envelopeFields))
        return PalaceCall(tool: createTunnelTool, arguments: args)
    }

    /// KGFact → `kg_add(subject, predicate, object, valid_from, source_closet)`.
    ///
    /// kg_add validates subject/predicate/object as ENTITY NAME fields, each
    /// capped at MAX_NAME_LENGTH = 128 chars (verified live: a longer object is
    /// rejected with `success:false` and no triple_id). The lossless envelope is
    /// far larger than 128 chars, so it CANNOT ride the object — doing so was
    /// the original write-failure bug. The native triple therefore stays CLEAN
    /// (subject/predicate/object verbatim, queryable), and the envelope (id,
    /// sourceDrawerID, bitmaps, full filedAt) rides `source_closet` — a
    /// free-form, length-unbounded field kg_add persists and kg_query returns
    /// verbatim. An empty envelope sends no `source_closet` at all.
    private static func kgFactCall(_ item: PalaceItem) throws -> PalaceCall {
        let subject = item.nativeFields["subject"]?.stringValue ?? ""
        let predicate = item.nativeFields["predicate"]?.stringValue ?? ""
        let object = item.nativeFields["object"]?.stringValue ?? ""
        let validFrom = item.nativeFields["valid_from"]?.stringValue ?? ""
        var args: [String: PalaceJSONValue] = [
            "subject": .string(subject),
            "predicate": .string(predicate),
            "object": .string(object),
            "valid_from": .string(validFrom),
        ]
        // The envelope rides source_closet (unbounded), never the 128-capped
        // object. encodeFields returns "" for an empty field map, so a fact
        // with no extra metadata sends no source_closet.
        let envelope = try PalacePayloadEnvelope.encodeFields(body: "", fields: item.envelopeFields)
        if !envelope.isEmpty {
            args["source_closet"] = .string(envelope)
        }
        return PalaceCall(tool: kgAddTool, arguments: args)
    }

    /// DiaryEntry → `diary_write(agent_name, entry+envelope, topic, wing)`.
    /// diary_write stores `entry` verbatim; the envelope rides it. Native
    /// agent_name/topic map directly; wing is optional (defaults to
    /// wing_<agent> on the server) so it is sent only when the source entry
    /// names one.
    private static func diaryCall(_ item: PalaceItem) throws -> PalaceCall {
        let agent = item.nativeFields["agent_name"]?.stringValue ?? "moot"
        let topic = item.nativeFields["topic"]?.stringValue ?? "general"
        let wing = item.nativeFields["wing"]?.stringValue ?? ""
        let entry = try PalacePayloadEnvelope.encodeFields(body: item.body, fields: item.envelopeFields)
        var args: [String: PalaceJSONValue] = [
            "agent_name": .string(agent),
            "entry": .string(entry),
            "topic": .string(topic),
        ]
        if !wing.isEmpty { args["wing"] = .string(wing) }
        return PalaceCall(tool: diaryWriteTool, arguments: args)
    }
}
