// glk-distilled-overlay — apply one versioned mechanical representation to a
// marked, disposable estate clone and recompose only its dense-float vectors.
//
// This executable is intentionally outside the GeniusLocusKit library target:
// it cannot change product distillation behavior.  It uses the same public
// Estate and CorpusContentEngine seams as production, but refuses the benchmark
// source volume and any clone without an explicit disposable marker.

import CorpusKit
import CorpusKitProviders
import CryptoKit
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

private let disposableMarker = ".distill-overlay-disposable"
private let forbiddenSourcePrefix = "/Volumes/llm_models/benchmark/wings/"
private let allowedEstateRoot = URL(
    fileURLWithPath: "/Users/bob/devlop/benchmark-cache/mootx01-ee-bench/experiments",
    isDirectory: true)

private struct OverlayMetrics: Decodable {
    let distilledTokensEstimate: Int64

    enum CodingKeys: String, CodingKey {
        case distilledTokensEstimate = "distilled_tokens_est"
    }
}

private struct OverlayRow: Decodable {
    let drawerID: String
    let converterID: String
    let sourceSHA256: String
    let original: String
    let aiText: String
    let miningBody: String
    let eventTime: String
    let metrics: OverlayMetrics

    enum CodingKeys: String, CodingKey {
        case drawerID = "drawer_id"
        case converterID = "converter_id"
        case sourceSHA256 = "source_sha256"
        case original
        case aiText = "ai_text"
        case miningBody = "mining_body"
        case eventTime = "event_time"
        case metrics
    }
}

private struct Arguments {
    let estate: URL
    let overlay: URL
    let converterID: String
    let expectedCount: Int
    let preflightOnly: Bool

    static func parse(_ values: [String]) throws -> Self {
        var fields: [String: String] = [:]
        var preflightOnly = false
        var index = 1
        while index < values.count {
            let key = values[index]
            if key == "--preflight-only" {
                guard !preflightOnly else {
                    throw ToolError.usage("duplicate argument \(key)")
                }
                preflightOnly = true
                index += 1
                continue
            }
            guard key.hasPrefix("--"), index + 1 < values.count else {
                throw ToolError.usage("unexpected or valueless argument \(key)")
            }
            guard fields[key] == nil else {
                throw ToolError.usage("duplicate argument \(key)")
            }
            fields[key] = values[index + 1]
            index += 2
        }
        let known = Set(["--estate", "--overlay", "--converter-id", "--expected-count"])
        let unknown = Set(fields.keys).subtracting(known)
        guard unknown.isEmpty else {
            throw ToolError.usage("unknown argument(s): \(unknown.sorted().joined(separator: ", "))")
        }
        guard let estate = fields["--estate"],
              let overlay = fields["--overlay"],
              let converterID = fields["--converter-id"],
              let countText = fields["--expected-count"],
              let expectedCount = Int(countText), expectedCount > 0 else {
            throw ToolError.usage(
                "required: --estate PATH --overlay JSONL --converter-id ID --expected-count N "
                    + "[--preflight-only]")
        }
        return Self(
            estate: URL(fileURLWithPath: estate).standardizedFileURL,
            overlay: URL(fileURLWithPath: overlay).standardizedFileURL,
            converterID: converterID,
            expectedCount: expectedCount,
            preflightOnly: preflightOnly)
    }
}

private enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let message): return "usage: \(message)"
        case .invalid(let message): return message
        }
    }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func parseDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let value = formatter.date(from: text) else {
        throw ToolError.invalid("invalid event_time \(text.debugDescription)")
    }
    return value
}

private func readOverlay(_ url: URL) throws -> [OverlayRow] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n", omittingEmptySubsequences: true)
        .enumerated().map { index, line in
            do {
                return try decoder.decode(OverlayRow.self, from: Data(line.utf8))
            } catch {
                throw ToolError.invalid("overlay line \(index + 1) is invalid: \(error)")
            }
        }
}

private func requireDisposableEstate(_ requestedEstate: URL) throws -> URL {
    // Resolve every symlink before making a safety decision, then keep using
    // this exact canonical URL through SQLite open.  Lexical standardization
    // alone does not prevent an in-root symlink from targeting a live estate.
    let estate = requestedEstate.resolvingSymlinksInPath().standardizedFileURL
    // The allowlist itself is a literal physical boundary.  Do not resolve it:
    // if that directory is ever replaced by a symlink, canonical estate paths
    // will fall outside this declared root and be refused.
    let root = allowedEstateRoot.standardizedFileURL
    let path = estate.path

    guard estate.lastPathComponent == "estate.sqlite" else {
        throw ToolError.invalid("--estate must name estate.sqlite")
    }
    guard !path.hasPrefix(forbiddenSourcePrefix) else {
        throw ToolError.invalid("refusing benchmark source estate: \(path)")
    }

    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard path.hasPrefix(rootPrefix) else {
        throw ToolError.invalid(
            "refusing estate outside benchmark-cache experiments: \(path)")
    }

    let estateValues = try? estate.resourceValues(forKeys: [.isRegularFileKey])
    guard estateValues?.isRegularFile == true else {
        throw ToolError.invalid("estate.sqlite is not a regular file: \(path)")
    }

    let marker = estate.deletingLastPathComponent().appendingPathComponent(disposableMarker)
    let markerValues = try? marker.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard markerValues?.isRegularFile == true,
          markerValues?.isSymbolicLink != true else {
        throw ToolError.invalid("disposable marker missing: \(marker.path)")
    }
    return estate
}

@main
private struct GLKDistilledOverlayMain {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("glk-distilled-overlay: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let args = try Arguments.parse(CommandLine.arguments)
        let estateURL = try requireDisposableEstate(args.estate)
        if args.preflightOnly {
            print("PREFLIGHT estate=\(estateURL.path)")
            return
        }
        let rows = try readOverlay(args.overlay)
        guard rows.count == args.expectedCount else {
            throw ToolError.invalid(
                "overlay row count \(rows.count) != expected \(args.expectedCount)")
        }
        let ids = Set(rows.map(\.drawerID))
        guard ids.count == rows.count else {
            throw ToolError.invalid("overlay contains duplicate drawer IDs")
        }
        for row in rows {
            guard row.converterID == args.converterID else {
                throw ToolError.invalid(
                    "drawer \(row.drawerID): converter \(row.converterID) != \(args.converterID)")
            }
            guard row.aiText == row.miningBody else {
                throw ToolError.invalid("drawer \(row.drawerID): ai_text != mining_body")
            }
        }

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 30.0))
        let storage = try SQLiteStorage(configuration: configuration)
        let owner = OwnerCredentials(ownerIdentifier: "mootx01-user")
        let estate = try await LocusKit.Estate.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        do {
            let counts = try await apply(
                args: args, rows: rows, estate: estate, storage: storage)
            try await estate.close()
            print("OVERLAY converter=\(args.converterID) "
                  + "rows=\(counts.updated) dense=\(counts.recomposed)")
        } catch {
            try? await estate.close()
            throw error
        }
    }

    private static func apply(
        args: Arguments,
        rows: [OverlayRow],
        estate: LocusKit.Estate,
        storage: SQLiteStorage
    ) async throws -> (updated: Int, recomposed: Int) {
        let liveDrawers = try await estate.allDrawers()
        let liveByID = Dictionary(uniqueKeysWithValues: liveDrawers.map { ($0.id, $0) })

        // Validate the complete overlay before the first write.  A mismatch can
        // therefore never leave a half-applied clone.
        for row in rows {
            guard let drawer = liveByID[row.drawerID] else {
                throw ToolError.invalid("overlay drawer not found: \(row.drawerID)")
            }
            guard drawer.content == row.original else {
                throw ToolError.invalid("drawer \(row.drawerID): original content mismatch")
            }
            let actualDigest = sha256(drawer.content)
            guard actualDigest == row.sourceSHA256 else {
                throw ToolError.invalid(
                    "drawer \(row.drawerID): source digest \(actualDigest) != \(row.sourceSHA256)")
            }
        }

        let corpus = try await CorpusContentEngine(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent),
            source: LocusDrawerCorpusContentSource(estate: estate),
            models: CorpusEnsemble.defaultEnsemble())
        try await corpus.reconcileConfiguredProviders(now: Date(timeIntervalSince1970: 0))

        var updated = 0
        var recomposed = 0
        for row in rows.sorted(by: { $0.drawerID < $1.drawerID }) {
            let generatedAt = try parseDate(row.eventTime)
            let count = try await estate.setDistilledRepresentation(
                drawerId: row.drawerID,
                distilled: row.aiText,
                pipelineVersion: row.converterID,
                tokenCount: row.metrics.distilledTokensEstimate,
                at: generatedAt)
            guard count == 1 else {
                throw ToolError.invalid("drawer \(row.drawerID): update count \(count) != 1")
            }
            updated += count
            guard try await corpus.recomposeDenseVector(id: row.drawerID, now: generatedAt) else {
                throw ToolError.invalid("drawer \(row.drawerID): dense source disappeared")
            }
            recomposed += 1
        }
        guard updated == args.expectedCount, recomposed == args.expectedCount else {
            throw ToolError.invalid(
                "incomplete apply: updated=\(updated) recomposed=\(recomposed)")
        }
        return (updated, recomposed)
    }
}
