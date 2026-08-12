// CodexMemory.swift
//
// Codex-native memory lifecycle support. This deliberately consumes only the
// documented hook wire fields; in particular it never opens transcript_path.

import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexMemoryMode: String, Codable, Sendable {
    case augment
    case mootOnly = "moot-only"
}

public struct CodexPriorSetting: Codable, Equatable, Sendable {
    public var existed: Bool
    public var rawValue: String?

    public init(existed: Bool, rawValue: String?) {
        self.existed = existed
        self.rawValue = rawValue
    }
}

public struct CodexMemoryConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var enabled: Bool
    public var mode: CodexMemoryMode
    public var automaticRecall: Bool
    public var recallLimit: Int
    public var recallCharacterBudget: Int
    public var nativeMemorySnapshot: [String: CodexPriorSetting]?
    public var codexConfigBackupPath: String?

    public init(
        enabled: Bool = true,
        mode: CodexMemoryMode = .augment,
        automaticRecall: Bool = false,
        recallLimit: Int = 3,
        recallCharacterBudget: Int = 4_000,
        nativeMemorySnapshot: [String: CodexPriorSetting]? = nil,
        codexConfigBackupPath: String? = nil
    ) {
        self.enabled = enabled
        self.mode = mode
        self.automaticRecall = automaticRecall
        self.recallLimit = min(max(recallLimit, 1), 5)
        self.recallCharacterBudget = min(max(recallCharacterBudget, 500), 8_000)
        self.nativeMemorySnapshot = nativeMemorySnapshot
        self.codexConfigBackupPath = codexConfigBackupPath
    }
}

public struct CodexHookState: Codable, Equatable, Sendable {
    public var observedMOOTRead = false
    public var observedMOOTWrite = false
    public var stopGateUsed = false
    public var compacted = false

    public init() {}
}

public enum CodexMemoryPaths {
    public static func root(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".mootx01/codex-memory", isDirectory: true)
    }

    public static func configuration(homeDirectory: URL) -> URL {
        root(homeDirectory: homeDirectory).appendingPathComponent("config.json")
    }

    public static func sessions(homeDirectory: URL) -> URL {
        root(homeDirectory: homeDirectory).appendingPathComponent("sessions", isDirectory: true)
    }

    public static func chronicleIndex(homeDirectory: URL) -> URL {
        root(homeDirectory: homeDirectory).appendingPathComponent("chronicle-index.json")
    }

    public static func codexHome(homeDirectory: URL, environment: [String: String]) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func codexConfig(homeDirectory: URL, environment: [String: String]) -> URL {
        codexHome(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent("config.toml")
    }

    public static func chronicleRoot(homeDirectory: URL, environment: [String: String]) -> URL {
        codexHome(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent("memories_extensions/chronicle", isDirectory: true)
    }

    public static func stateFile(sessionID: String, homeDirectory: URL) -> URL {
        let safe = sessionID.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            return allowed ? Character(String(scalar)) : "_"
        }
        let name = String(safe.prefix(120))
        return sessions(homeDirectory: homeDirectory)
            .appendingPathComponent(name.isEmpty ? "unknown.json" : "\(name).json")
    }
}

public enum CodexMemoryStore {
    public static func load(homeDirectory: URL) -> CodexMemoryConfiguration? {
        let url = CodexMemoryPaths.configuration(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexMemoryConfiguration.self, from: data)
    }

    public static func save(_ config: CodexMemoryConfiguration, homeDirectory: URL) throws {
        let url = CodexMemoryPaths.configuration(homeDirectory: homeDirectory)
        try secureWrite(config, to: url)
    }

    public static func loadState(sessionID: String, homeDirectory: URL) -> CodexHookState {
        let url = CodexMemoryPaths.stateFile(sessionID: sessionID, homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CodexHookState.self, from: data)
        else { return CodexHookState() }
        return state
    }

    public static func saveState(_ state: CodexHookState, sessionID: String, homeDirectory: URL) throws {
        try secureWrite(state, to: CodexMemoryPaths.stateFile(
            sessionID: sessionID, homeDirectory: homeDirectory))
    }

    public static func removeState(sessionID: String, homeDirectory: URL) {
        let url = CodexMemoryPaths.stateFile(sessionID: sessionID, homeDirectory: homeDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    private static func secureWrite<T: Encodable>(_ value: T, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Narrow TOML editor for the three documented Codex memory settings. It
/// preserves comments, ordering, unrelated keys, and unrelated tables.
public enum CodexNativeMemorySettings {
    public static let managedKeys = [
        "features.memories",
        "memories.generate_memories",
        "memories.use_memories",
    ]

    public static func snapshot(in text: String) -> [String: CodexPriorSetting] {
        Dictionary(uniqueKeysWithValues: managedKeys.map { dotted in
            let parts = dotted.split(separator: ".", maxSplits: 1).map(String.init)
            let raw = value(in: text, table: parts[0], key: parts[1])
            return (dotted, CodexPriorSetting(existed: raw != nil, rawValue: raw))
        })
    }

    public static func disableNativeMemories(in text: String) -> String {
        var result = text
        result = setting(in: result, table: "features", key: "memories", rawValue: "false")
        result = setting(in: result, table: "memories", key: "generate_memories", rawValue: "false")
        result = setting(in: result, table: "memories", key: "use_memories", rawValue: "false")
        return result
    }

    public static func restore(_ snapshot: [String: CodexPriorSetting], in text: String) -> String {
        var result = text
        for dotted in managedKeys {
            guard let prior = snapshot[dotted] else { continue }
            let parts = dotted.split(separator: ".", maxSplits: 1).map(String.init)
            result = setting(
                in: result, table: parts[0], key: parts[1],
                rawValue: prior.existed ? prior.rawValue : nil)
        }
        return result
    }

    public static func value(in text: String, table: String, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var activeTable: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                activeTable = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard activeTable == table, !trimmed.hasPrefix("#"),
                  let equal = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            if lhs == key {
                return String(trimmed[trimmed.index(after: equal)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func setting(in text: String, table: String, key: String, rawValue: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var tableStart: Int?
        var tableEnd = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { continue }
            let name = String(trimmed.dropFirst().dropLast())
            if name == table { tableStart = index; continue }
            if tableStart != nil { tableEnd = index; break }
        }

        if let start = tableStart {
            var found: Int?
            if start + 1 < tableEnd {
                for index in (start + 1)..<tableEnd {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
                    if trimmed[..<equal].trimmingCharacters(in: .whitespaces) == key {
                        found = index
                        break
                    }
                }
            }
            if let found {
                if let rawValue { lines[found] = "\(key) = \(rawValue)" }
                else { lines.remove(at: found) }
            } else if let rawValue {
                lines.insert("\(key) = \(rawValue)", at: tableEnd)
            }
        } else if let rawValue {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(table)]")
            lines.append("\(key) = \(rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct CodexRecallClient: Sendable {
    private let endpoint: URL
    private let session: URLSession

    public init(port: Int, requestTimeout: Double = 1.25, resourceTimeout: Double = 2.0) {
        endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration)
    }

    public func recall(query: String, limit: Int) async throws -> String? {
        let arguments: [String: Any] = [
            "query": query,
            "limit": min(max(limit, 1), 5),
            // userConfirmed adds the confirmation constraint; the substrate's
            // default frame still inserts currentlyBelieve, trustworthy, and
            // sensitivityAtMost(elevated).
            "filter": "userConfirmed",
            "ack": "recall_distilled/v2",
        ]
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "moot_recall_distilled", "arguments": arguments],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil,
              let result = json["result"] as? [String: Any]
        else { return nil }
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return result["text"] as? String
    }
}

public struct ChronicleImportIndex: Codable, Equatable, Sendable {
    public var hashes: [String: String]
    public init(hashes: [String: String] = [:]) { self.hashes = hashes }
}

public struct ChronicleImportSummary: Equatable, Sendable {
    public var imported = 0
    public var duplicates = 0
    public var failed = 0
    public init() {}
}

public enum CodexChronicleImporter {
    public static func markdownFiles(root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func run(
        root: URL,
        homeDirectory: URL,
        daemon: some DaemonClient,
        now: Date = Date()
    ) async -> ChronicleImportSummary {
        let indexURL = CodexMemoryPaths.chronicleIndex(homeDirectory: homeDirectory)
        var index = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode(ChronicleImportIndex.self, from: $0) }
            ?? ChronicleImportIndex()
        var summary = ChronicleImportSummary()
        for file in markdownFiles(root: root) {
            guard let data = try? Data(contentsOf: file), let body = String(data: data, encoding: .utf8) else {
                summary.failed += 1
                continue
            }
            let digest = sha256(data)
            if index.hashes.values.contains(digest) {
                summary.duplicates += 1
                continue
            }
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard filePath.hasPrefix(prefix) else {
                summary.failed += 1
                continue
            }
            let relative = String(filePath.dropFirst(prefix.count))
            let provenance = """
            MOOTx01 import provenance:
            - source: Codex Chronicle generated Markdown
            - source_path: \(relative)
            - source_sha256: \(digest)
            - confirmation: unconfirmed

            \(body)
            """
            do {
                let subject = HarnessMemoryIngest.extractSubject(from: provenance, fileName: relative)
                let ok = try await daemon.fileMemory(
                    location: "codex-chronicle/\(relative)", content: provenance,
                    subject: subject,
                    eventTime: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now,
                    kind: "document")
                if ok {
                    index.hashes[relative] = digest
                    summary.imported += 1
                } else { summary.failed += 1 }
            } catch { summary.failed += 1 }
        }
        if let data = try? JSONEncoder().encode(index) {
            try? FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: indexURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        }
        return summary
    }
}
