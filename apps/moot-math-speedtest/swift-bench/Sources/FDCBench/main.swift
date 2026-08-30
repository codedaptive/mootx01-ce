import Foundation
import Harness
import LatticeLib

struct Measurement: Codable {
    let operation: String
    let workload: String
    let bytes: Int
    let tokens: Int
    let iterations: Int
    let nsPerCallMin: UInt64
    let nsPerCallMean: UInt64
    let nsPerCallStddev: UInt64

    enum CodingKeys: String, CodingKey {
        case operation, workload, bytes, tokens, iterations
        case nsPerCallMin = "ns_per_call_min"
        case nsPerCallMean = "ns_per_call_mean"
        case nsPerCallStddev = "ns_per_call_stddev"
    }
}

struct Report: Codable {
    let schemaVersion = "fdc-1"
    let language = "swift"
    let op = "fdc_classifier_v4"
    let date: String
    let generatedAt: String
    let hardwareTag: String
    let commitSha: String
    let classifierVersion: String
    let dataVersion: String
    let semanticModelVersion: String
    let semanticModelSHA256: String
    let coldStartNs: UInt64
    let timing: [String: Int]
    let quickMode: Bool
    let measurements: [Measurement]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language, op, date
        case generatedAt = "generated_at"
        case hardwareTag = "hardware_tag"
        case commitSha = "commit_sha"
        case classifierVersion = "classifier_version"
        case dataVersion = "data_version"
        case semanticModelVersion = "semantic_model_version"
        case semanticModelSHA256 = "semantic_model_sha256"
        case coldStartNs = "cold_start_ns"
        case timing
        case quickMode = "quick_mode"
        case measurements
    }
}

let workloads: [(String, String)] = [
    ("short_resolved", "graph algorithms and information retrieval"),
    ("medium_resolved", "A deterministic local memory system classifies documents, stores fingerprints, and retrieves related evidence with graph centrality and matrix scoring."),
    ("long_mixed", Array(repeating: "The memory substrate combines deterministic classification, bitmap filtering, semantic ranking, graph traversal, temporal scoring, and durable audit records.", count: 10).joined(separator: " ")),
    ("unresolved", "florble quux zibble wump snarkle"),
    ("code", "func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }")
]

func usage() -> Never {
    fputs("usage: fdc-bench [--out <path>] [--quick]\n", stderr)
    exit(2)
}

func gitCommit() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["rev-parse", "HEAD"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "unknown" }; p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

func timed(warmupNs: UInt64, measureNs: UInt64, _ body: () -> Int) -> (Int, UInt64, UInt64, UInt64) {
    var checksum = 0
    let warm = DispatchTime.now().uptimeNanoseconds
    repeat { checksum ^= body() } while DispatchTime.now().uptimeNanoseconds - warm < warmupNs
    var samples: [UInt64] = []
    let startWindow = DispatchTime.now().uptimeNanoseconds
    repeat {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum ^= body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    } while DispatchTime.now().uptimeNanoseconds - startWindow < measureNs
    withExtendedLifetime(checksum) {}
    let min = samples.min() ?? 0
    let meanD = samples.reduce(0.0) { $0 + Double($1) } / Double(max(1, samples.count))
    let variance = samples.reduce(0.0) { $0 + pow(Double($1) - meanD, 2) } / Double(max(1, samples.count))
    return (samples.count, min, UInt64(meanD.rounded()), UInt64(sqrt(variance).rounded()))
}

var quick = false
var outPath = "fdc-swift.json"
var i = 1
while i < CommandLine.arguments.count {
    switch CommandLine.arguments[i] {
    case "--quick": quick = true
    case "--out": i += 1; guard i < CommandLine.arguments.count else { usage() }; outPath = CommandLine.arguments[i]
    case "--help", "-h": usage()
    default: usage()
    }
    i += 1
}

let coldStart = DispatchTime.now().uptimeNanoseconds
_ = FDC.encode(workloads[0].1)
let coldStartNs = DispatchTime.now().uptimeNanoseconds - coldStart
guard FDC.isAvailable else { fputs("FDC artifacts unavailable\n", stderr); exit(1) }

let warmupMs = quick ? 5 : 30
let measureMs = quick ? 20 : 120
var rows: [Measurement] = []
for (name, text) in workloads {
    let operations: [(String, () -> Int)] = [
        ("encode", { FDC.encode(text)?.count ?? 0 }),
        ("encode_anchor_no_record", {
            let kind: FDCContentKind = name == "code" ? .code : .text
            let answer = FDC.encodeAnchor(text, contentKind: kind, recordNovel: false)
            return (answer.code?.count ?? 0) ^ (answer.conceptQID?.count ?? 0)
        }),
        ("semantic_candidates_8", { FDC.semanticCandidates(text, limit: 8).reduce(0) { $0 ^ $1.code.count ^ Int(truncatingIfNeeded: $1.score) } }),
        ("semantic_decision", { FDC.semanticDecision(text).map { $0.code.count ^ Int(truncatingIfNeeded: $0.score) } ?? 0 }),
    ]
    for (operation, body) in operations {
        let t = timed(warmupNs: UInt64(warmupMs) * 1_000_000, measureNs: UInt64(measureMs) * 1_000_000, body)
        rows.append(Measurement(operation: operation, workload: name, bytes: text.utf8.count,
                                tokens: text.split(whereSeparator: { $0.isWhitespace }).count,
                                iterations: t.0, nsPerCallMin: t.1, nsPerCallMean: t.2, nsPerCallStddev: t.3))
        print("  \(operation) \(name): \(t.1) ns")
    }
}

let now = ISO8601DateFormatter().string(from: Date())
let report = Report(date: String(now.prefix(10)), generatedAt: now, hardwareTag: Hardware.tag(), commitSha: gitCommit(),
                    classifierVersion: FDC.classifierVersion, dataVersion: FDC.dataVersion,
                    semanticModelVersion: FDC.semanticModelVersion, semanticModelSHA256: FDC.semanticModelSHA256,
                    coldStartNs: coldStartNs, timing: ["warmup_ms": warmupMs, "measure_ms": measureMs],
                    quickMode: quick, measurements: rows)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(report).write(to: URL(fileURLWithPath: outPath), options: .atomic)
print("  wrote \(outPath)")
