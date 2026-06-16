// TopKBench/main.swift
//
// Phase 2.δ-1 measurement: branchless top-K ladder maintenance
// (cookbook §11.2). Sweeps K and N independently to characterize
// the SimdKernel.hammingTopK vs ScalarKernel.hammingTopK
// crossover and check the cookbook §17.1 hot-path budget of
// K=10 over 1M rows < 100 µs.
//
// USAGE
//
//   topk-bench [--seed <0xhex>]
//              [--kernel <name>]    (default: all available)
//              [--n <list>]          (default: 256,1024,4096,16384,65536,262144,1048576)
//              [--k <list>]          (default: 1,4,10,32,100)
//              [--out <path>]
//              [--quick]
//
// OUTPUT
//
//   Structured JSON with per-(kernel, N, K) latency. Reuses the
//   benchmarks/results/{date}-{hw}/ directory.

import Foundation
import Harness
import GeniusLocusReference

let DEFAULT_SEED: UInt64 = 0xCAFEBABEDEADBEEF
let DEFAULT_N: [Int] = [256, 1024, 4096, 16384, 65536, 262144, 1048576]
let DEFAULT_K: [Int] = [1, 4, 10, 32, 100]

let WARMUP_FULL_NS: UInt64 = 50_000_000
let MEASURE_FULL_NS: UInt64 = 200_000_000
let WARMUP_QUICK_NS: UInt64 = 10_000_000
let MEASURE_QUICK_NS: UInt64 = 40_000_000

struct TopKMeasurement {
    let kernel: KernelKind
    let n: Int
    let k: Int
    let iterations: UInt64
    let nsMin: UInt64
    let nsMean: UInt64
    let nsStddev: UInt64
}

struct Args {
    var seed: UInt64 = DEFAULT_SEED
    var out: String? = nil
    var kernel: KernelKind? = nil
    var nList: [Int] = DEFAULT_N
    var kList: [Int] = DEFAULT_K
    var quick: Bool = false
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: topk-bench [--seed <0xhex>] [--kernel <name>] \
    [--n <comma-list>] [--k <comma-list>] [--out <path>] [--quick]

    Defaults:
      N: 256, 1024, 4096, 16384, 65536, 262144, 1048576
      K: 1, 4, 10, 32, 100

    """.data(using: .utf8)!)
    exit(2)
}

func parseList(_ s: String) -> [Int]? {
    var out: [Int] = []
    for part in s.split(separator: ",") {
        guard let v = Int(part.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        out.append(v)
    }
    return out
}

func parseArgs() -> Args {
    var args = Args()
    var i = 1
    let cli = CommandLine.arguments
    while i < cli.count {
        switch cli[i] {
        case "--seed":
            i += 1
            guard i < cli.count else { usage() }
            var s = cli[i]
            if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
            guard let v = UInt64(s, radix: 16) else { usage() }
            args.seed = v
        case "--kernel":
            i += 1
            guard i < cli.count else { usage() }
            guard let k = KernelSelector.parse(cli[i]) else {
                FileHandle.standardError.write("unknown kernel: \(cli[i])\n".data(using: .utf8)!)
                exit(2)
            }
            args.kernel = k
        case "--n":
            i += 1
            guard i < cli.count, let vs = parseList(cli[i]) else { usage() }
            args.nList = vs
        case "--k":
            i += 1
            guard i < cli.count, let vs = parseList(cli[i]) else { usage() }
            args.kList = vs
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
    return args
}

@inline(__always)
func nowNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

func timeLoop(warmupNS: UInt64, measureNS: UInt64, body: () -> Void)
    -> (UInt64, UInt64, UInt64, UInt64)
{
    let warmupEnd = nowNS() + warmupNS
    while nowNS() < warmupEnd { body() }

    var samples: [UInt64] = []
    samples.reserveCapacity(1 << 16)
    let measureEnd = nowNS() + measureNS
    while nowNS() < measureEnd {
        let t0 = nowNS()
        body()
        let dt = nowNS() &- t0
        samples.append(dt)
    }

    let iters = UInt64(samples.count)
    if iters == 0 { return (0, 0, 0, 0) }
    let minNS = samples.min() ?? 0
    var sum: Double = 0
    for s in samples { sum += Double(s) }
    let mean = sum / Double(iters)
    var varSum: Double = 0
    for s in samples {
        let d = Double(s) - mean
        varSum += d * d
    }
    let stddev = (varSum / Double(iters)).squareRoot()
    return (iters, minNS, UInt64(mean), UInt64(stddev))
}

func fingerprintFromRNG(_ rng: inout Harness.SplitMix64) -> Fingerprint256 {
    return Fingerprint256(block0: rng.next(), block1: rng.next(),
                          block2: rng.next(), block3: rng.next())
}

func measureTopK(_ kernel: SubstrateKernel,
                 _ rng: inout Harness.SplitMix64,
                 _ n: Int, _ k: Int,
                 _ warmupNS: UInt64, _ measureNS: UInt64) -> TopKMeasurement
{
    let probe = fingerprintFromRNG(&rng)
    let candidates: [Fingerprint256] = (0..<n).map { _ in fingerprintFromRNG(&rng) }
    var sink: Int = 0

    let (its, mn, mu, sd) = timeLoop(warmupNS: warmupNS, measureNS: measureNS) {
        let result = kernel.hammingTopK(probe: probe, candidates: candidates, k: k)
        if !result.isEmpty { sink &+= result[0].distance }
    }
    if sink == 0xDEADBEEF { print("# sink: \(sink)") }

    return TopKMeasurement(
        kernel: kernel.kind, n: n, k: k,
        iterations: its, nsMin: mn, nsMean: mu, nsStddev: sd)
}

func todayDate() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = TimeZone(identifier: "UTC")
    return fmt.string(from: Date())
}

func defaultOutputDir() -> String {
    let thisFile = URL(fileURLWithPath: #file)
    let harnessRoot = thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let date = todayDate()
    let hw = Hardware.tag()
    return harnessRoot
        .appendingPathComponent("benchmarks")
        .appendingPathComponent("results")
        .appendingPathComponent("\(date)-\(hw)")
        .path
}

func writeJSON(_ ms: [TopKMeasurement], path: String,
               seed: UInt64, warmupNS: UInt64, measureNS: UInt64,
               quick: Bool) throws
{
    var s = ""
    s += "{\n"
    s += "  \"schema_version\": \"topk-1\",\n"
    s += "  \"language\": \"swift\",\n"
    s += "  \"op\": \"hamming_top_k\",\n"
    s += "  \"date\": \"\(todayDate())\",\n"
    s += "  \"hardware_tag\": \"\(Hardware.tag())\",\n"
    s += String(format: "  \"seed\": \"0x%016llx\",\n", seed)
    s += "  \"timing\": {\n"
    s += "    \"warmup_ms\": \(warmupNS / 1_000_000),\n"
    s += "    \"measure_ms\": \(measureNS / 1_000_000),\n"
    s += "    \"quick_mode\": \(quick ? "true" : "false")\n"
    s += "  },\n"
    s += "  \"measurements\": [\n"
    for (i, m) in ms.enumerated() {
        let comma = i + 1 < ms.count ? "," : ""
        s += "    { \"kernel\": \"\(m.kernel.rawValue)\", \"n\": \(m.n), \"k\": \(m.k), "
        s += "\"iterations\": \(m.iterations), \"ns_per_call_min\": \(m.nsMin), "
        s += "\"ns_per_call_mean\": \(m.nsMean), \"ns_per_call_stddev\": \(m.nsStddev)"
        s += " }\(comma)\n"
    }
    s += "  ]\n"
    s += "}\n"
    try s.write(toFile: path, atomically: true, encoding: .utf8)
}

// ----- main -----

let args = parseArgs()

let kernels: [KernelKind]
if let k = args.kernel {
    kernels = [k]
} else {
    kernels = KernelRegistry.available()
}

let (warmupNS, measureNS): (UInt64, UInt64) = args.quick
    ? (WARMUP_QUICK_NS, MEASURE_QUICK_NS)
    : (WARMUP_FULL_NS, MEASURE_FULL_NS)

let outPath: String
if let p = args.out {
    outPath = p
} else {
    let dir = defaultOutputDir()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    outPath = "\(dir)/hamming_topk-swift.json"
}

let err = FileHandle.standardError
err.write("# topk-bench (swift)\n".data(using: .utf8)!)
err.write(String(format: "# seed:       0x%016llx\n", args.seed).data(using: .utf8)!)
err.write("# hardware:   \(Hardware.tag())\n".data(using: .utf8)!)
err.write("# kernels:    \(kernels.map { $0.rawValue }.joined(separator: ", "))\n".data(using: .utf8)!)
err.write("# N values:   \(args.nList)\n".data(using: .utf8)!)
err.write("# K values:   \(args.kList)\n".data(using: .utf8)!)
err.write("# timing:     warmup \(warmupNS / 1_000_000)ms, measure \(measureNS / 1_000_000)ms\(args.quick ? " (quick)" : "")\n\n".data(using: .utf8)!)

var allMeasurements: [TopKMeasurement] = []
for k in kernels {
    let kernel = PortableKernel.kernel(of: k)
    if kernel.kind != k {
        err.write("  skipping \(k.rawValue) (dispatcher returned \(kernel.kind.rawValue))\n".data(using: .utf8)!)
        continue
    }
    err.write("  kernel=\(k.rawValue)\n".data(using: .utf8)!)
    var rng = Harness.SplitMix64(seed: args.seed)
    for n in args.nList {
        for kv in args.kList {
            let m = measureTopK(kernel, &rng, n, kv, warmupNS, measureNS)
            err.write(String(format: "    N=%7d  K=%4d  min: %9lluns  (%llu iters)\n",
                             n, kv, m.nsMin, m.iterations).data(using: .utf8)!)
            allMeasurements.append(m)
        }
    }
    err.write("\n".data(using: .utf8)!)
}

do {
    try writeJSON(allMeasurements, path: outPath,
                  seed: args.seed, warmupNS: warmupNS, measureNS: measureNS,
                  quick: args.quick)
    err.write("  wrote \(outPath)\n".data(using: .utf8)!)
} catch {
    err.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
