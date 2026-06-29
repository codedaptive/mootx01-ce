// SubstrateValidator (Swift) — primary field validator of the substrate libs.
//
// (B)+2: per primitive, compute the conformance CRC THREE ways — the shipping
// lib (packages/libs, via Lib_<name>.crc), the glref reference (via the Harness
// PrimitiveRegistry), and the committed value — and report all three plus
// lib↔glref agreement.
//
// Registry-driven: each Lib_<name>.swift contributes one entry. Primitives land
// here as their lib-side validator files are added. Subsystems 2 (backend A/B),
// 4 (timing), 5 (source↔cookbook audit), and 6 (source-CRC drift) are now wired
// via `--backends`, `--time`, `--audit`, and `--stamp`/`--drift`. Only the
// cross-language comparator (3) remains outside this file.

import Foundation
import Harness

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// Committed vectors: package root (validation-app/swift-app) -> up two to
// substrate_math_performance, then test-harness/vectors.
let pkgRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // SubstrateValidator
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // swift-app (package root)
let vectorsDir = pkgRoot
    .appendingPathComponent("../../test-harness/vectors")
    .standardizedFileURL

// Each entry: primitive name -> shipping-lib conformance CRC over the committed vector.
let libValidators: [(String, (VectorFile) -> UInt32)] = [
    ("bitwise", Lib_bitwise.crc),
    ("fingerprint", Lib_fingerprint.crc),
    ("fnv", Lib_fnv.crc),
    ("hlc", Lib_hlc.crc),
    ("hamming", Lib_hamming.crc),
    ("or_reduce", Lib_or_reduce.crc),
    ("hamming_nn", Lib_hamming_nn.crc),
    ("simhash", Lib_simhash.crc),
    ("anomaly", Lib_anomaly.crc),
    ("lattice", Lib_lattice.crc),
    ("matrix_decay", Lib_matrix_decay.crc),
    ("eigenvalue_centrality", Lib_eigenvalue_centrality.crc),
    ("moment_summary", Lib_moment_summary.crc),
    ("field_presence_matrix_f", Lib_field_presence_matrix_f.crc),
    ("bit_field_masked_equals", Lib_bit_field_masked_equals.crc),
    ("info_theory", Lib_info_theory.crc),
    ("bradley_terry", Lib_bradley_terry.crc),
    ("partial_state_recall", Lib_partial_state_recall.crc),
    ("temporal_compression", Lib_temporal_compression.crc),
    ("tier_contribution", Lib_tier_contribution.crc),
    ("fft", Lib_fft.crc),
    ("pairing_handshake", Lib_pairing_handshake.crc),
    ("nmf", Lib_nmf.crc),
    ("audit_log_fold", Lib_audit_log_fold.crc),
]

// Subsystem 5 (advisory): structural source↔cookbook audit. Heuristic token
// coverage, NOT a gate — exits 0 regardless; the gates are conformance + cross-lang.
if CommandLine.arguments.contains("--audit") {
    _ = CookbookAudit.run()
    exit(0)
}

// Subsystem 6: source-CRC drift. --stamp records the lib-source CRC; --drift
// recomputes and compares. (SwiftPM's plugin sandbox precludes Rust's build.rs
// build-time stamp; --stamp is the explicit release/build-time stamp point.)
if CommandLine.arguments.contains("--stamp") { exit(SourceDrift.stamp()) }
if CommandLine.arguments.contains("--drift") { exit(SourceDrift.drift()) }

// Subsystem 2: backend A/B — kernel-dispatched ops byte-identical across backends.
if CommandLine.arguments.contains("--backends") { exit(Int32(BackendAB.run())) }

// Subsystem 4: timing — warmup then measure ns per lib-CRC call, per primitive
// (validate-call granularity, matching the Rust app). Hardware-tagged.
if CommandLine.arguments.contains("--time") {
    print("SubstrateValidator (Swift) — timing: lib CRC per primitive (ns/call)")
    print("hardware: \(Hardware.tag())\n")
    print("\(pad("primitive", 26)) \(pad("runs", 7)) \(pad("ns_min", 10)) ns_mean")
    for (name, libFn) in libValidators {
        let path = vectorsDir.appendingPathComponent("\(name).json").path
        guard let json = try? String(contentsOfFile: path, encoding: .utf8),
              let file = try? JSONReader.parseVectorFile(json) else { continue }
        var t = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - t < 50_000_000 { _ = libFn(file) }  // 50ms warmup
        var samples: [Double] = []
        t = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - t < 150_000_000 {                   // 150ms measure
            let s = DispatchTime.now().uptimeNanoseconds
            _ = libFn(file)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - s))
        }
        let mn = samples.min() ?? 0
        let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        print("\(pad(name, 26)) \(pad(String(samples.count), 7)) "
            + "\(pad(String(format: "%.0f", mn), 10)) \(String(format: "%.0f", mean))")
    }
    exit(0)
}

let jsonOut = CommandLine.arguments.contains("--json")

// Collect per-primitive results first, then emit table or JSON.
struct Row { let name: String; let committed: UInt32; let lib: UInt32; let glref: UInt32 }
var rows: [Row] = []
for (name, libFn) in libValidators {
    let path = vectorsDir.appendingPathComponent("\(name).json").path
    guard let json = try? String(contentsOfFile: path, encoding: .utf8),
          let file = try? JSONReader.parseVectorFile(json) else { continue }
    let committed = file.outputCrc32
    let lib = libFn(file)
    let glref = (try? PrimitiveRegistry.find(name)?.validate(file).crcActual) ?? UInt32.max
    rows.append(Row(name: name, committed: committed, lib: lib, glref: glref))
}

let total = rows.count
let libPass = rows.filter { $0.lib == $0.committed }.count
let glrefPass = rows.filter { $0.glref == $0.committed }.count
let agree = rows.filter { $0.lib == $0.glref }.count
let allOK = libPass == total && glrefPass == total && agree == total

if jsonOut {
    func q(_ s: String) -> String { "\"\(s)\"" }
    var prims: [String] = []
    for r in rows {
        prims.append("""
        {"primitive":\(q(r.name)),"committed":\(q(HexCoding.crc32(r.committed))),\
        "lib":\(q(HexCoding.crc32(r.lib))),"glref":\(q(HexCoding.crc32(r.glref))),\
        "lib_ok":\(r.lib == r.committed),"glref_ok":\(r.glref == r.committed),\
        "lib_eq_glref":\(r.lib == r.glref)}
        """)
    }
    print("""
    {"tool":"substrate-validator-swift","hardware":\(q(Hardware.tag())),"all_ok":\(allOK),\
    "primitives":[\(prims.joined(separator: ","))]}
    """)
} else {
    print("SubstrateValidator (Swift) — 3-way: shipping lib vs glref vs committed")
    print("hardware: \(Hardware.tag())\n")
    print("\(pad("primitive", 16)) \(pad("committed", 12)) \(pad("lib", 13)) \(pad("glref", 13)) lib==glref")
    for r in rows {
        print("\(pad(r.name, 16)) \(pad(HexCoding.crc32(r.committed), 12)) "
            + "\(pad(HexCoding.crc32(r.lib) + (r.lib == r.committed ? " " : "✗"), 13)) "
            + "\(pad(HexCoding.crc32(r.glref) + (r.glref == r.committed ? " " : "✗"), 13)) \(r.lib == r.glref)")
    }
    print("\nlib \(libPass)/\(total) conformant, glref \(glrefPass)/\(total) conformant, lib==glref \(agree)/\(total)")
}
exit(allOK ? 0 : 1)
