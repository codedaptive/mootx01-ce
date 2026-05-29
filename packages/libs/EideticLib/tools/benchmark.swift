// benchmark.swift
//
// Light benchmark suite for EideticLib. Measures cold-start
// time (parse JSON, build indexes) and warm lookup time
// across a small set of inputs. Run with:
//
//   swift run --package-path .. gnomon-bench
//
// or invoke directly:
//
//   swift Tools/benchmark.swift
//
// Numbers are wall-clock and printed in microseconds. The
// benchmark is not a precise microbenchmark; it's a rough
// "is this fast enough" check. For tighter measurements use
// Instruments (macOS) or perf (Linux) with a debug build.

import Foundation
import EideticLib

func nanoNow() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
}

func bench(label: String, iterations: Int, work: () -> Void) {
    // Warm up to amortize one-time costs.
    for _ in 0..<10 { work() }

    let start = nanoNow()
    for _ in 0..<iterations { work() }
    let elapsed = nanoNow() - start

    let perIterNs = Double(elapsed) / Double(iterations)
    let perIterUs = perIterNs / 1000.0
    let totalMs = Double(elapsed) / 1_000_000.0

    print(
        String(
            format: "  %-40s  %8.2f µs/iter  %8.2f ms total  (%d iters)",
            label, perIterUs, totalMs, iterations
        )
    )
}

print("EideticLib benchmark")
print("===================")
print("")

// Cold start: load schedule + subset, build internal state
// implicitly through one lookup.
let coldStart = nanoNow()
let _ = EideticLib.lookup("chemistry")
let coldElapsed = nanoNow() - coldStart
print(
    String(
        format: "Cold start (first lookup): %.2f ms",
        Double(coldElapsed) / 1_000_000.0
    )
)
print("")

// Warm lookups.
print("Warm lookup timings:")

bench(label: "chemistry", iterations: 10_000) {
    _ = EideticLib.lookup("chemistry")
}

bench(label: "organic chemistry (phrase)", iterations: 10_000) {
    _ = EideticLib.lookup("organic chemistry")
}

bench(label: "computer science programming", iterations: 10_000) {
    _ = EideticLib.lookup("computer science programming")
}

bench(label: "psychology", iterations: 10_000) {
    _ = EideticLib.lookup("psychology")
}

bench(label: "qwertyzxcvb (no-match)", iterations: 10_000) {
    _ = EideticLib.lookup("qwertyzxcvb")
}

bench(label: "empty input", iterations: 10_000) {
    _ = EideticLib.lookup("")
}

print("")
print("Done.")
