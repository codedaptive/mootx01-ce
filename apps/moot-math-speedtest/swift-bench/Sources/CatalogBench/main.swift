import Foundation
import Harness

struct Measurement: Codable {
    let primitive: String
    let cookbookSection: String
    let casesPerIteration: Int
    let iterations: Int
    let nsPerBatchMin: UInt64
    let nsPerBatchMean: UInt64
    let nsPerBatchStddev: UInt64
    let nsPerCaseMin: Double

    enum CodingKeys: String, CodingKey {
        case primitive
        case cookbookSection = "cookbook_section"
        case casesPerIteration = "cases_per_iteration"
        case iterations
        case nsPerBatchMin = "ns_per_batch_min"
        case nsPerBatchMean = "ns_per_batch_mean"
        case nsPerBatchStddev = "ns_per_batch_stddev"
        case nsPerCaseMin = "ns_per_case_min"
    }
}

struct Timing: Codable {
    let warmupMs: Int
    let measureMs: Int
    let quickMode: Bool

    enum CodingKeys: String, CodingKey {
        case warmupMs = "warmup_ms"
        case measureMs = "measure_ms"
        case quickMode = "quick_mode"
    }
}

struct Platform: Codable {
    let arch: String
    let os: String
}

struct Report: Codable {
    let schemaVersion = "catalog-1"
    let language = "swift"
    let op = "canonical_primitive_validation"
    let date: String
    let generatedAt: String
    let hardwareTag: String
    let commitSha: String
    let vectorRoot: String
    let timing: Timing
    let platform: Platform
    let measurements: [Measurement]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language, op, date
        case generatedAt = "generated_at"
        case hardwareTag = "hardware_tag"
        case commitSha = "commit_sha"
        case vectorRoot = "vector_root"
        case timing, platform, measurements
    }
}

enum CatalogBenchError: Error { case validationDrift(String) }

func usage() -> Never {
    fputs("usage: catalog-bench --vectors <dir> [--primitive <name>] [--out <path>] [--quick]\n", stderr)
    exit(2)
}

func gitCommit() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "unknown" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch {
        return "unknown"
    }
}

func stats(_ samples: [UInt64]) -> (UInt64, UInt64, UInt64) {
    let minimum = samples.min() ?? 0
    let meanDouble = samples.reduce(0.0) { $0 + Double($1) } / Double(max(samples.count, 1))
    let variance = samples.reduce(0.0) { $0 + pow(Double($1) - meanDouble, 2) }
        / Double(max(samples.count, 1))
    return (minimum, UInt64(meanDouble.rounded()), UInt64(sqrt(variance).rounded()))
}

func measure(
    warmupNs: UInt64,
    measureNs: UInt64,
    body: () throws -> UInt32
) rethrows -> (Int, UInt64, UInt64, UInt64) {
    let warmupStart = DispatchTime.now().uptimeNanoseconds
    var checksum: UInt32 = 0
    repeat {
        checksum ^= try body()
    } while DispatchTime.now().uptimeNanoseconds - warmupStart < warmupNs

    var samples: [UInt64] = []
    let measureStart = DispatchTime.now().uptimeNanoseconds
    repeat {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum ^= try body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    } while DispatchTime.now().uptimeNanoseconds - measureStart < measureNs
    withExtendedLifetime(checksum) {}
    let (minimum, mean, stddev) = stats(samples)
    return (samples.count, minimum, mean, stddev)
}

var vectorRoot: String?
var primitive: String?
var outPath: String?
var quick = false
let args = CommandLine.arguments
var index = 1
while index < args.count {
    switch args[index] {
    case "--vectors": index += 1; guard index < args.count else { usage() }; vectorRoot = args[index]
    case "--primitive": index += 1; guard index < args.count else { usage() }; primitive = args[index]
    case "--out": index += 1; guard index < args.count else { usage() }; outPath = args[index]
    case "--quick": quick = true
    case "--help", "-h": usage()
    default: usage()
    }
    index += 1
}
guard let vectorRoot else { usage() }

let descriptors: [PrimitiveDescriptor]
if let primitive {
    guard let descriptor = PrimitiveRegistry.find(primitive) else {
        fputs("unknown primitive: \(primitive)\n", stderr)
        exit(2)
    }
    descriptors = [descriptor]
} else {
    descriptors = PrimitiveRegistry.all
}

let warmupMs = quick ? 5 : 30
let measureMs = quick ? 20 : 120
var measurements: [Measurement] = []
for descriptor in descriptors {
    let path = URL(fileURLWithPath: vectorRoot).appendingPathComponent("\(descriptor.name).json")
    let text = try String(contentsOf: path, encoding: .utf8)
    let file = try JSONReader.parseVectorFile(text)
    let initial = try descriptor.validate(file)
    guard initial.passed else {
        fputs("conformance prerequisite failed for \(descriptor.name)\n", stderr)
        exit(1)
    }
    let timed = try measure(
        warmupNs: UInt64(warmupMs) * 1_000_000,
        measureNs: UInt64(measureMs) * 1_000_000
    ) {
        let result = try descriptor.validate(file)
        guard result.passed else { throw CatalogBenchError.validationDrift(descriptor.name) }
        return result.crcActual
    }
    let row = Measurement(
        primitive: descriptor.name,
        cookbookSection: descriptor.cookbookSection,
        casesPerIteration: file.cases.count,
        iterations: timed.0,
        nsPerBatchMin: timed.1,
        nsPerBatchMean: timed.2,
        nsPerBatchStddev: timed.3,
        nsPerCaseMin: file.cases.isEmpty ? 0 : Double(timed.1) / Double(file.cases.count)
    )
    measurements.append(row)
    print(String(format: "  %-30s %4d cases  %10llu ns/batch  %10.1f ns/case",
                 (descriptor.name as NSString).utf8String!, file.cases.count, timed.1, row.nsPerCaseMin))
}

let iso = ISO8601DateFormatter()
let generatedAt = iso.string(from: Date())
let report = Report(
    date: String(generatedAt.prefix(10)),
    generatedAt: generatedAt,
    hardwareTag: Hardware.tag(),
    commitSha: gitCommit(),
    vectorRoot: vectorRoot,
    timing: Timing(warmupMs: warmupMs, measureMs: measureMs, quickMode: quick),
    platform: Platform(arch: ProcessInfo.processInfo.machineArchitecture, os: "macos"),
    measurements: measurements
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(report)
let destination = outPath ?? "catalog-swift.json"
try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
print("  wrote \(destination)")

extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        var machine = info.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
