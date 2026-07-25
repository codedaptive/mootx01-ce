// StressTest/main.swift
//
// Empirical kernel benchmark sweep. Measures per-(kernel, op,
// batch_size, mode) latency and emits structured JSON for the
// kernel-learned-dispatch decision protocol.
//
// USAGE
//
//   stress-test [--seed <0xhex>]
//               [--op <name>]            (one of: hamming, simhash, or_reduce,
//                                          all; default: all)
//               [--kernel <name> | --all]  (default: --all)
//               [--out <path>]            (a directory, or a single .json
//                                          path; default: standard
//                                          benchmarks/results/{date}-{hw}/
//                                          location)
//               [--quick]                 (faster, less stable; for iteration)
//
// MODES
//
//   batched     - the protocol's batched method (default impl is a
//                 loop over the pair-at-a-time op; overrides exist
//                 in SimdKernel and any future SIMD/BNNS/Metal kernel)
//   sequential  - explicit N-call loop of the pair-at-a-time op
//                 from the caller side, no batched method
//
// OUTPUT
//
//   JSON file written to
//     test-harness/benchmarks/results/{YYYY-MM-DD}-{hw-slug}/
//       {op}-swift.json
//
//   The directory is gitignored. Decision docs cite the date +
//   hardware tag + commit hash that produced the numbers they
//   quote. The schema is committed (this file); the numbers
//   are not.
//
// Mirror of test-harness/rust/src/bin/stress_test.rs.

import Foundation
import Harness
import GeniusLocusReference

let DEFAULT_SEED: UInt64 = 0xCAFEBABEDEADBEEF
let BATCH_SIZES: [Int] = [1, 2, 4, 8, 16, 32, 64, 128, 256]

// Default per-(kernel, op, batch_size, mode) budget. Full
// sweep is BATCH_SIZES.count * 3 ops * 2 modes * N kernels.
// Each cell needs warmup + measure.
let WARMUP_FULL_NS: UInt64 = 50_000_000   // 50 ms
let MEASURE_FULL_NS: UInt64 = 200_000_000  // 200 ms
let WARMUP_QUICK_NS: UInt64 = 10_000_000   // 10 ms
let MEASURE_QUICK_NS: UInt64 = 40_000_000  // 40 ms

enum Mode: String {
    case batched
    case sequential
}

enum Op: String {
    case hammingDistanceBatch = "hamming_distance_batch"
    case simhashBlockBatch    = "simhash_block_batch"
    case orReduceBatch        = "or_reduce_batch"

    var cliName: String {
        switch self {
        case .hammingDistanceBatch: return "hamming"
        case .simhashBlockBatch:    return "simhash"
        case .orReduceBatch:        return "or_reduce"
        }
    }
    static func parseCLI(_ s: String) -> Op? {
        switch s {
        case "hamming":               return .hammingDistanceBatch
        case "simhash":               return .simhashBlockBatch
        case "or_reduce", "or-reduce": return .orReduceBatch
        default:                       return nil
        }
    }
}

struct Measurement {
    let kernel: KernelKind
    let op: Op
    let batchSize: Int
    let mode: Mode
    let iterations: UInt64
    let nsMin: UInt64
    let nsMean: UInt64
    let nsStddev: UInt64
}

struct Args {
    var seed: UInt64 = DEFAULT_SEED
    var out: String? = nil
    var kernel: KernelKind? = nil    // nil → use all available
    var op: String = "all"
    var quick: Bool = false
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: stress-test [--seed <0xhex>] [--op <name>] \
    [--kernel <name> | --all] [--out <path>] [--quick]

    Ops:     hamming, simhash, or_reduce, all (default: all)
    Kernels: scalar, simd, or use --all to iterate every available
             kernel (default: --all)
    Output:  --out <path> may be a directory (the binary names the
             file) or a .json path. Default: standard
             test-harness/benchmarks/results/{date}-{hw}/ directory.

    """.data(using: .utf8)!)
    exit(2)
}

func parseArgs() -> Args {
    var args = Args()
    var allKernels = false
    var i = 1
    let cli = CommandLine.arguments
    while i < cli.count {
        switch cli[i] {
        case "--seed":
            i += 1
            guard i < cli.count else { usage() }
            var s = cli[i]
            if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
            guard let v = UInt64(s, radix: 16) else {
                FileHandle.standardError.write("invalid seed: \(cli[i])\n".data(using: .utf8)!)
                exit(2)
            }
            args.seed = v
        case "--op":
            i += 1
            guard i < cli.count else { usage() }
            args.op = cli[i]
        case "--kernel":
            i += 1
            guard i < cli.count else { usage() }
            guard let k = KernelSelector.parse(cli[i]) else {
                FileHandle.standardError.write("unknown kernel: \(cli[i])\n".data(using: .utf8)!)
                exit(2)
            }
            args.kernel = k
        case "--all":
            allKernels = true
        case "--out":
            i += 1
            guard i < cli.count else { usage() }
            args.out = cli[i]
        case "--quick":
            args.quick = true
        case "--help", "-h":
            usage()
        default:
            usage()
        }
        i += 1
    }
    if args.kernel != nil && allKernels {
        FileHandle.standardError.write("--kernel and --all are mutually exclusive\n".data(using: .utf8)!)
        exit(2)
    }
    return args
}

@inline(__always)
func nowNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

nonisolated(unsafe) var stressSink: UInt64 = 0

@inline(never) @_optimize(none)
func consumeStressResult(_ value: UInt64) {
    stressSink ^= value
}

func timeLoop(warmupNS: UInt64, measureNS: UInt64, body: () -> UInt64)
    -> (UInt64, UInt64, UInt64, UInt64)
{
    let warmupEnd = nowNS() + warmupNS
    while nowNS() < warmupEnd { consumeStressResult(body()) }

    // Batch very fast operations so every clock sample spans at least 10 us.
    // This avoids publishing zero-nanosecond rows caused by timer resolution.
    var callsPerSample: UInt64 = 1
    while callsPerSample < 1 << 20 {
        let t0 = nowNS()
        var checksum: UInt64 = 0
        for _ in 0..<callsPerSample { checksum ^= body() }
        let elapsed = nowNS() &- t0
        consumeStressResult(checksum)
        if elapsed >= 10_000 { break }
        callsPerSample &*= 2
    }

    var samples: [UInt64] = []
    samples.reserveCapacity(1 << 16)
    let measureEnd = nowNS() + measureNS
    while nowNS() < measureEnd {
        let t0 = nowNS()
        var checksum: UInt64 = 0
        for _ in 0..<callsPerSample { checksum ^= body() }
        let dt = nowNS() &- t0
        consumeStressResult(checksum)
        samples.append((dt &+ callsPerSample &- 1) / callsPerSample)
    }

    let sampleCount = UInt64(samples.count)
    if sampleCount == 0 { return (0, 0, 0, 0) }
    let iters = sampleCount &* callsPerSample
    let minNS = samples.min() ?? 0

    // Use Double for mean/stddev to keep this simple; sample counts
    // and ns values are well within Double's precision range for
    // our use.
    var sum: Double = 0
    for s in samples { sum += Double(s) }
    let mean = sum / Double(sampleCount)
    var varSum: Double = 0
    for s in samples {
        let d = Double(s) - mean
        varSum += d * d
    }
    let variance = varSum / Double(sampleCount)
    let stddev = variance.squareRoot()
    return (iters, minNS, UInt64(mean), UInt64(stddev))
}

func fingerprintFromRNG(_ rng: inout Harness.SplitMix64) -> Fingerprint256 {
    return Fingerprint256(block0: rng.next(), block1: rng.next(),
                          block2: rng.next(), block3: rng.next())
}

func expandSeedTo32(_ seed: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    var s = seed
    for i in 0..<4 {
        s = s &+ 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        for j in 0..<8 {
            out[i * 8 + j] = UInt8((z >> (j * 8)) & 0xFF)
        }
    }
    return out
}

func measureHamming(_ kernel: SubstrateKernel, _ rng: inout Harness.SplitMix64,
                    _ batchSize: Int, _ warmupNS: UInt64, _ measureNS: UInt64)
    -> (Measurement, Measurement)
{
    let probe = fingerprintFromRNG(&rng)
    let candidates: [Fingerprint256] = (0..<batchSize).map { _ in fingerprintFromRNG(&rng) }
    let (itB, mnB, muB, sdB) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        let result = kernel.hammingDistanceBatch(probe: probe, candidates: candidates)
        return UInt64(result.first ?? 0)
    }
    let (itS, mnS, muS, sdS) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        var total = 0
        for cand in candidates { total &+= kernel.hammingDistance256(probe, cand) }
        return UInt64(total)
    }

    return (
        Measurement(kernel: kernel.kind, op: .hammingDistanceBatch,
                    batchSize: batchSize, mode: .batched,
                    iterations: itB, nsMin: mnB, nsMean: muB, nsStddev: sdB),
        Measurement(kernel: kernel.kind, op: .hammingDistanceBatch,
                    batchSize: batchSize, mode: .sequential,
                    iterations: itS, nsMin: mnS, nsMean: muS, nsStddev: sdS)
    )
}

func measureSimhash(_ kernel: SubstrateKernel, _ rng: inout Harness.SplitMix64,
                    _ batchSize: Int, _ warmupNS: UInt64, _ measureNS: UInt64)
    -> (Measurement, Measurement)
{
    let blockIndex = 0
    let inputBitLength = 192
    let inputWordCount = (inputBitLength + 63) / 64
    let hyperplaneSeed = rng.next()
    let seedBytes = expandSeedTo32(hyperplaneSeed)
    let family = HyperplaneFamily.generate(
        seed: seedBytes, blockIndex: blockIndex,
        inputBitLength: inputBitLength, density: 1.0)

    var inputs: [[UInt64]] = []
    inputs.reserveCapacity(batchSize)
    for _ in 0..<batchSize {
        var w = [UInt64]()
        w.reserveCapacity(inputWordCount)
        for _ in 0..<inputWordCount { w.append(rng.next()) }
        inputs.append(w)
    }
    let (itB, mnB, muB, sdB) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        let result = kernel.simhashBlockBatch(inputs: inputs, family: family)
        return result.first ?? 0
    }
    let (itS, mnS, muS, sdS) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        var total: UInt64 = 0
        for inp in inputs { total &+= SimHash.block(over: inp, family: family) }
        return total
    }

    return (
        Measurement(kernel: kernel.kind, op: .simhashBlockBatch,
                    batchSize: batchSize, mode: .batched,
                    iterations: itB, nsMin: mnB, nsMean: muB, nsStddev: sdB),
        Measurement(kernel: kernel.kind, op: .simhashBlockBatch,
                    batchSize: batchSize, mode: .sequential,
                    iterations: itS, nsMin: mnS, nsMean: muS, nsStddev: sdS)
    )
}

func measureOrReduce(_ kernel: SubstrateKernel, _ rng: inout Harness.SplitMix64,
                     _ batchSize: Int, _ warmupNS: UInt64, _ measureNS: UInt64)
    -> (Measurement, Measurement)
{
    let innerCount = 8
    var batches: [[Fingerprint256]] = []
    batches.reserveCapacity(batchSize)
    for _ in 0..<batchSize {
        var cohort = [Fingerprint256]()
        cohort.reserveCapacity(innerCount)
        for _ in 0..<innerCount { cohort.append(fingerprintFromRNG(&rng)) }
        batches.append(cohort)
    }
    let (itB, mnB, muB, sdB) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        let result = kernel.orReduceBatch(batches: batches)
        return result.first?.block0 ?? 0
    }
    let (itS, mnS, muS, sdS) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        var totalB0: UInt64 = 0
        for cohort in batches { totalB0 &+= kernel.orReduce256(cohort).block0 }
        return totalB0
    }

    return (
        Measurement(kernel: kernel.kind, op: .orReduceBatch,
                    batchSize: batchSize, mode: .batched,
                    iterations: itB, nsMin: mnB, nsMean: muB, nsStddev: sdB),
        Measurement(kernel: kernel.kind, op: .orReduceBatch,
                    batchSize: batchSize, mode: .sequential,
                    iterations: itS, nsMin: mnS, nsMean: muS, nsStddev: sdS)
    )
}

func measureOneOp(_ op: Op, kernel: SubstrateKernel,
                  rng: inout Harness.SplitMix64,
                  warmupNS: UInt64, measureNS: UInt64) -> [Measurement]
{
    var out: [Measurement] = []
    out.reserveCapacity(BATCH_SIZES.count * 2)
    let err = FileHandle.standardError
    for bs in BATCH_SIZES {
        let (b, s): (Measurement, Measurement)
        switch op {
        case .hammingDistanceBatch:
            (b, s) = measureHamming(kernel, &rng, bs, warmupNS, measureNS)
        case .simhashBlockBatch:
            (b, s) = measureSimhash(kernel, &rng, bs, warmupNS, measureNS)
        case .orReduceBatch:
            (b, s) = measureOrReduce(kernel, &rng, bs, warmupNS, measureNS)
        }
        err.write(String(format: "    bs=%5d  batched: %7lluns  sequential: %7lluns\n",
                         bs, b.nsMin, s.nsMin).data(using: .utf8)!)
        out.append(b)
        out.append(s)
    }
    return out
}

func gitShortSHA() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["git", "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run(); task.waitUntilExit() } catch { return "unknown" }
    guard task.terminationStatus == 0 else { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8) else { return "unknown" }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown" : trimmed
}

func todayDate() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = TimeZone(identifier: "UTC")
    return fmt.string(from: Date())
}

func nowISO() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: Date())
}

func writeJSON(_ ms: [Measurement], path: String, op: Op,
               seed: UInt64, warmupNS: UInt64, measureNS: UInt64,
               quick: Bool) throws
{
    var s = ""
    let now = nowISO()
    let date = todayDate()
    let hw = Hardware.tag()
    let sha = gitShortSHA()

    s += "{\n"
    s += "  \"schema_version\": \"2\",\n"
    s += "  \"language\": \"swift\",\n"
    s += "  \"op\": \"\(op.rawValue)\",\n"
    s += "  \"date\": \"\(date)\",\n"
    s += "  \"generated_at\": \"\(now)\",\n"
    s += "  \"hardware_tag\": \"\(hw)\",\n"
    s += "  \"commit_sha\": \"\(sha)\",\n"
    s += String(format: "  \"seed\": \"0x%016llx\",\n", seed)
    s += "  \"timing\": {\n"
    s += "    \"warmup_ms\": \(warmupNS / 1_000_000),\n"
    s += "    \"measure_ms\": \(measureNS / 1_000_000),\n"
    s += "    \"quick_mode\": \(quick ? "true" : "false")\n"
    s += "  },\n"
    s += "  \"platform\": {\n"
    #if arch(arm64)
    s += "    \"arch\": \"arm64\",\n"
    #elseif arch(x86_64)
    s += "    \"arch\": \"x86_64\",\n"
    #else
    s += "    \"arch\": \"unknown\",\n"
    #endif
    #if os(macOS)
    s += "    \"os\":   \"macos\"\n"
    #elseif os(Linux)
    s += "    \"os\":   \"linux\"\n"
    #else
    s += "    \"os\":   \"unknown\"\n"
    #endif
    s += "  },\n"
    s += "  \"measurements\": [\n"
    for (i, m) in ms.enumerated() {
        let comma = i + 1 < ms.count ? "," : ""
        let nsPerElement = m.batchSize > 0 ? Double(m.nsMin) / Double(m.batchSize) : 0.0
        s += "    { \"kernel\": \"\(m.kernel.rawValue)\", \"batch_size\": \(m.batchSize), \"mode\": \"\(m.mode.rawValue)\", "
        s += "\"iterations\": \(m.iterations), \"ns_per_call_min\": \(m.nsMin), "
        s += "\"ns_per_call_mean\": \(m.nsMean), \"ns_per_call_stddev\": \(m.nsStddev), "
        s += String(format: "\"ns_per_element_min\": %.3f", nsPerElement)
        s += " }\(comma)\n"
    }
    s += "  ]\n"
    s += "}\n"
    try s.write(toFile: path, atomically: true, encoding: .utf8)
}

func defaultOutputDir() -> String {
    // Walk up from #file location to find the test-harness/ root,
    // then append benchmarks/results/{date}-{hw}/.
    //
    // Important: SwiftPM rewrites #file to omit the `Sources/`
    // segment. The runtime #file value is:
    //   .../test-harness/swift/StressTest/main.swift
    // (not .../test-harness/swift/Sources/StressTest/main.swift)
    // So three .deletingLastPathComponent() calls land on
    // test-harness/, not four as the literal source layout
    // would suggest.
    let thisFile = URL(fileURLWithPath: #file)
    let harnessRoot = thisFile
        .deletingLastPathComponent()   // StressTest
        .deletingLastPathComponent()   // swift
        .deletingLastPathComponent()   // test-harness
    let date = todayDate()
    let hw = Hardware.tag()
    return harnessRoot
        .appendingPathComponent("benchmarks")
        .appendingPathComponent("results")
        .appendingPathComponent("\(date)-\(hw)")
        .path
}

// ----- main -----

let args = parseArgs()

// Resolve op list
let ops: [Op]
if args.op == "all" {
    ops = [.hammingDistanceBatch, .simhashBlockBatch, .orReduceBatch]
} else {
    guard let o = Op.parseCLI(args.op) else {
        FileHandle.standardError.write("unknown op: \(args.op)\n".data(using: .utf8)!)
        exit(2)
    }
    ops = [o]
}

// Resolve kernel list
let kernels: [KernelKind]
if let k = args.kernel {
    kernels = [k]
} else {
    kernels = KernelRegistry.available()
}

let (warmupNS, measureNS): (UInt64, UInt64) = args.quick
    ? (WARMUP_QUICK_NS, MEASURE_QUICK_NS)
    : (WARMUP_FULL_NS, MEASURE_FULL_NS)

let outDir: String
let outIsFile: Bool
if let outArg = args.out {
    if outArg.hasSuffix(".json") {
        if ops.count != 1 {
            FileHandle.standardError.write("--out <file.json> requires --op <one-op>\n".data(using: .utf8)!)
            exit(2)
        }
        outDir = outArg
        outIsFile = true
    } else {
        outDir = outArg
        outIsFile = false
    }
} else {
    outDir = defaultOutputDir()
    outIsFile = false
}

let err = FileHandle.standardError
err.write("# stress-test (swift)\n".data(using: .utf8)!)
err.write(String(format: "# seed:          0x%016llx\n", args.seed).data(using: .utf8)!)
err.write("# hardware:      \(Hardware.tag())\n".data(using: .utf8)!)
err.write("# kernels:       \(kernels.map { $0.rawValue }.joined(separator: ", "))\n".data(using: .utf8)!)
err.write("# ops:           \(ops.map { $0.rawValue }.joined(separator: ", "))\n".data(using: .utf8)!)
err.write("# batch sizes:   \(BATCH_SIZES)\n".data(using: .utf8)!)
err.write("# timing:        warmup \(warmupNS / 1_000_000)ms, measure \(measureNS / 1_000_000)ms\(args.quick ? " (quick)" : "")\n\n".data(using: .utf8)!)

for op in ops {
    var allMeasurements: [Measurement] = []

    for k in kernels {
        let kernel = PortableKernel.kernel(of: k)
        if kernel.kind != k {
            err.write("  skipping \(k.rawValue) (requested but dispatcher returned \(kernel.kind.rawValue))\n".data(using: .utf8)!)
            continue
        }
        err.write("  kernel=\(k.rawValue)  op=\(op.rawValue)\n".data(using: .utf8)!)
        var rng = Harness.SplitMix64(seed: args.seed)
        let ms = measureOneOp(op, kernel: kernel, rng: &rng,
                              warmupNS: warmupNS, measureNS: measureNS)
        allMeasurements.append(contentsOf: ms)
    }

    let filePath: String
    if outIsFile {
        filePath = outDir
    } else {
        do {
            try FileManager.default.createDirectory(
                atPath: outDir,
                withIntermediateDirectories: true)
        } catch {
            err.write("failed to create output dir \(outDir): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        filePath = "\(outDir)/\(op.cliName)-swift.json"
    }

    do {
        try writeJSON(allMeasurements, path: filePath, op: op,
                      seed: args.seed, warmupNS: warmupNS, measureNS: measureNS,
                      quick: args.quick)
        err.write("  wrote \(filePath)\n\n".data(using: .utf8)!)
    } catch {
        err.write("write failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
