import Foundation
import AriaMCP   // JSONValue

// MARK: - MootToolCalling
//
// The sole seam between MootIntentKit and the substrate. Every intent,
// URL router, and share sink calls through this protocol; nothing in this
// package imports GeniusLocusKit, LocusKit, or PersistenceKit directly.
//
// MootBridge (in apps/Mootx01-App/Sources/MootGateway/) conforms to this
// protocol. Test code (in Tests/MootIntentKitTests/) provides a TestBridge
// conformance (a MootBridge-equivalent over a real in-memory estate) so
// perform() exercises actual substrate behaviour. The protocol carries only what the
// intent layer needs: tool calls and the result shape.
//
// `actor` isolation: the intents drive `callTool` from @MainActor contexts;
// the protocol is Sendable-safe because actors are Sendable and all
// conformances must be actors. Concrete conformances use `actor` to
// serialize calls — this is the same constraint MootBridge already satisfies.

/// The call record an intent receives after one tool invocation.
public struct IntentCallResult: Sendable {
    /// Concatenated text from every content[].text block in the tool response.
    public let text: String
    /// True when the substrate (or the ARIA surface) refused the operation.
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// The seam MootIntentKit uses to reach the MOOT. Conforming types live
/// above this package (apps/Mootx01-App/MootGateway/MootBridge) or in test
/// infrastructure. The kit never imports the concrete type.
public protocol MootToolCalling: Actor, Sendable {
    /// Invoke a named moot_* tool with string/bool/integer arguments and
    /// return the result. Arguments are JSONValue so the intents can pass
    /// typed values (string, bool) without reaching into the substrate's
    /// own parameter structs.
    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult
}

// MARK: - Structured recall extension

extension MootToolCalling {
    /// Recall drawers as typed entities by parsing the `moot_memory_search`
    /// text response. The tool response lines have the format:
    ///   `<uuid>  [<room>]  <content preview up to 120 chars>`
    /// This gateway-layer parse gives id, room, and content-preview without
    /// requiring a new ARIA surface. Lines that don't match the UUID-bracket
    /// format (the header and provenance lines) are silently skipped.
    ///
    /// - Parameters:
    ///   - query: The free-text query sent to moot_memory_search.
    ///   - publicOnly: When true, sets filter:exportable (§6.2 serve-out gate).
    ///   - limit: Maximum hits to request (default 20, capped at 50 by the tool).
    public func recallDrawers(
        query: String,
        publicOnly: Bool = false,
        limit: Int = 20
    ) async -> [DrawerEntity] {
        var arguments: [String: JSONValue] = [
            "query": .string(query),
            "limit": .integer(Int64(limit)),
        ]
        if publicOnly {
            arguments["filter"] = .string("exportable")
        }
        let result = await callTool("moot_memory_search", arguments: arguments)
        guard !result.isError else { return [] }
        return Self.parseDrawerLines(result.text)
    }

    /// Parse `moot_memory_search` text response lines into DrawerEntity values.
    /// Each result line is `<uuid>  [<room>]  <content>`. The first line
    /// ("found N memory(s)") and the recall_provenance line are skipped.
    public static func parseDrawerLines(_ text: String) -> [DrawerEntity] {
        // UUID pattern: 8-4-4-4-12 hex groups.
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        // Full line pattern: <uuid>  [<room>]  <content>
        // Two spaces separate each field segment per the ToolDispatch format.
        let linePattern = "^(\(uuidPattern))  \\[([^\\]]+)\\]  (.+)$"
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return [] }

        return text.components(separatedBy: "\n").compactMap { line -> DrawerEntity? in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { return nil }

            func capture(_ idx: Int) -> String? {
                guard let r = Range(match.range(at: idx), in: line) else { return nil }
                return String(line[r])
            }
            guard let id = capture(1), let room = capture(2), let content = capture(3) else {
                return nil
            }
            return DrawerEntity(id: id, content: content, room: room)
        }
    }
}

// MARK: - IntentToolError

/// Surfaces a substrate refusal from any intent as a thrown error so
/// Shortcuts surfaces the reason rather than silently succeeding.
public enum IntentToolError: Error, CustomLocalizedStringResourceConvertible {
    case substrateRefused(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .substrateRefused(let why):
            return "The MOOT refused the operation: \(why)"
        }
    }
}
