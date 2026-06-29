import Foundation

// PalaceResponseParsing.swift — parses MemPalace tool responses the pump
// depends on, fixing the benchmarker's GAP B and GAP C.
//
// GAP B (write-id): the benchmarker hardcoded `writeAssignedID = nil` for the
// jsonObjects shape, so it never learned the id MemPalace assigned. Verified
// live, `mempalace_add_drawer` returns a single text block whose text is a
// JSON object:
//
//     { "success": true, "drawer_id": "drawer_<wing>_<room>_<hash>",
//       "wing": "...", "room": "..." }
//
// and on a duplicate:
//
//     { "success": true, "reason": "already_exists",
//       "drawer_id": "drawer_<wing>_<room>_<hash>" }
//
// Either way `drawer_id` is present — the assigned (or pre-existing) id the
// pump must record. ``parseAddDrawerID`` extracts it.
//
// GAP C (round-trip by id, not search): MemPalace `search` returns no stable
// drawer id, so the benchmarker's search-based round-trip could not correlate
// the write. The pump verifies via `get_drawer` BY THE ASSIGNED ID instead.
// Verified live, `mempalace_get_drawer` returns a single text block whose text
// is a JSON object:
//
//     { "drawer_id": "...", "content": "...", "wing": "...", "room": "...",
//       "metadata": { ... } }
//
// ``parseGetDrawer`` extracts the id + full verbatim content.
//
// Both tools wrap their JSON in the MCP `content: [{type:"text", text:...}]`
// envelope. These parsers take the already-extracted text block(s) (the MCP
// client unwraps the envelope) and parse the inner JSON. Pure, deterministic,
// byte-identical across the Swift and Rust ports.

/// The parsed result of a `get_drawer` fetch: the drawer id MemPalace echoes
/// and its full verbatim content. Both present in a successful fetch.
public struct PalaceFetchedDrawer: Sendable, Equatable {
    /// The drawer id (echoed by `get_drawer`).
    public let drawerID: String
    /// The full verbatim content as stored (the envelope-bearing string the
    /// pump wrote).
    public let content: String

    public init(drawerID: String, content: String) {
        self.drawerID = drawerID
        self.content = content
    }
}

/// Errors raised while parsing MemPalace tool responses.
public enum PalaceResponseError: Error, Sendable, Equatable {
    /// No text block carried parseable JSON with the expected key.
    case missingField(String)
    /// A text block was present but its bytes were not valid JSON.
    case malformedJSON(String)
}

/// Pure parsers for the MemPalace tool responses the pump consumes. No
/// instances — a function namespace.
public enum PalaceResponseParsing {

    /// Parse the `drawer_id` MemPalace assigned (or echoed) from an
    /// `add_drawer` response's text blocks. Handles both the fresh-write
    /// shape and the `already_exists` shape — both carry `drawer_id`. GAP-B
    /// fix.
    ///
    /// - Parameter textBlocks: the text payloads from the MCP `content`
    ///   array (the client unwraps the MCP envelope before calling this).
    /// - Returns: the assigned/echoed drawer id.
    /// - Throws: ``PalaceResponseError`` when no block carries a `drawer_id`.
    public static func parseAddDrawerID(textBlocks: [String]) throws -> String {
        for block in textBlocks {
            guard let object = jsonObject(from: block) else { continue }
            if let id = object["drawer_id"] as? String, !id.isEmpty {
                return id
            }
        }
        throw PalaceResponseError.missingField("drawer_id")
    }

    /// Parse the id + full content from a `get_drawer` response's text blocks.
    /// Used to verify a write round-tripped by fetching it by the assigned id
    /// (GAP-C fix), and to reconstruct a `NoteIR` from a re-import.
    ///
    /// - Parameter textBlocks: the text payloads from the MCP `content` array.
    /// - Returns: the fetched drawer id and verbatim content.
    /// - Throws: ``PalaceResponseError`` when no block carries both
    ///   `drawer_id` and `content`.
    public static func parseGetDrawer(textBlocks: [String]) throws -> PalaceFetchedDrawer {
        for block in textBlocks {
            guard let object = jsonObject(from: block) else { continue }
            // get_drawer returns `content` even when empty-string; require the
            // key to be present (not the value non-empty) so an intentionally
            // empty drawer still parses.
            if let id = object["drawer_id"] as? String, !id.isEmpty,
               let content = object["content"] as? String {
                return PalaceFetchedDrawer(drawerID: id, content: content)
            }
        }
        throw PalaceResponseError.missingField("drawer_id+content")
    }

    /// Parse the assigned id from a write response's text blocks, given the
    /// id key that tool returns. The four-noun generalization of
    /// ``parseAddDrawerID(textBlocks:)``: each MemPalace write tool echoes the
    /// assigned (or pre-existing) row id under a tool-specific key —
    /// `add_drawer` → `drawer_id`, `create_tunnel` → `id` (bare key),
    /// `kg_add` → `triple_id`, `diary_write` → `entry_id` (verified live,
    /// v3.3.3). The
    /// `already_exists` shape carries the same key, so a duplicate still yields
    /// its id. Returns nil when no block carries a non-empty value for `idKey`
    /// (a write that produced no row).
    ///
    /// - Parameters:
    ///   - textBlocks: the text payloads from the MCP `content` array.
    ///   - idKey: the response key that carries the assigned id for this tool.
    /// - Returns: the assigned/echoed id, or nil when absent.
    public static func parseAssignedID(textBlocks: [String], idKey: String) -> String? {
        for block in textBlocks {
            guard let object = jsonObject(from: block) else { continue }
            if let id = object[idKey] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    /// The response key that carries the assigned row id for one noun's write
    /// tool. Verified live (v3.3.3); see ``parseAssignedID(textBlocks:idKey:)``.
    /// `create_tunnel` returns the symmetric tunnel id under the bare `id` key
    /// (not `tunnel_id`) — empirically determined against the live server.
    public static func assignedIDKey(for noun: PalaceNoun) -> String {
        switch noun {
        case .drawer: return "drawer_id"
        case .tunnel: return "id"
        case .kgFact: return "triple_id"
        case .diaryEntry: return "entry_id"
        }
    }

    /// Parse a JSON object from a text block, or nil when the block is not a
    /// JSON object. Tolerant: a text block that is not JSON (a diagnostic
    /// line) is simply skipped by the callers above.
    private static func jsonObject(from block: String) -> [String: Any]? {
        guard let data = block.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object
    }
}
