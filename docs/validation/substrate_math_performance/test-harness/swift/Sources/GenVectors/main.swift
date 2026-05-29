// GenVectors/main.swift
//
// CLI: `swift run gen-vectors --primitive <name> --seed <hex> [--out <path>]`
//
// Reads the named primitive's generator, produces a VectorFile,
// writes canonical JSON to the output path (defaulting to
// `vectors/<name>.json` relative to the harness root).

import Foundation
import Harness
import GeniusLocusReference

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: gen-vectors --primitive <name> --seed <0xhex> [--out <path>] [--kernel <name>]

    Kernels: scalar (default), simd

    Available primitives:
    """.data(using: .utf8)!)
    for p in PrimitiveRegistry.all {
        FileHandle.standardError.write("\n  - \(p.name)  (\(p.cookbookSection))".data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    exit(2)
}

func parseArgs() -> (primitive: String, seed: UInt64, out: String?, kernel: KernelKind) {
    var primitive: String?
    var seed: UInt64?
    var out: String?
    var kernel: KernelKind = .scalar
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--primitive":
            i += 1
            guard i < args.count else { usage() }
            primitive = args[i]
        case "--seed":
            i += 1
            guard i < args.count else { usage() }
            let bytes = (try? HexCoding.decode(args[i])) ?? []
            guard bytes.count == 8 else {
                FileHandle.standardError.write("seed must be 8 bytes (16 hex digits)\n".data(using: .utf8)!)
                exit(2)
            }
            seed = bytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << ($1.offset * 8))
            }
        case "--out":
            i += 1
            guard i < args.count else { usage() }
            out = args[i]
        case "--kernel":
            i += 1
            guard i < args.count else { usage() }
            guard let k = KernelSelector.parse(args[i]) else {
                FileHandle.standardError.write("unknown kernel: \(args[i])\n".data(using: .utf8)!)
                exit(2)
            }
            kernel = k
        default:
            usage()
        }
        i += 1
    }
    guard let p = primitive, let s = seed else { usage() }
    return (p, s, out, kernel)
}

let args = parseArgs()
KernelSelector.set(args.kernel)

guard let descriptor = PrimitiveRegistry.find(args.primitive) else {
    FileHandle.standardError.write("unknown primitive: \(args.primitive)\n".data(using: .utf8)!)
    usage()
}

let file: VectorFile
do {
    file = try descriptor.generate(args.seed)
} catch {
    FileHandle.standardError.write("generation failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let json = JSONWriter.write(file)

let outputPath: String
if let custom = args.out {
    outputPath = custom
} else {
    // Default: vectors/<name>.json relative to the harness root.
    let harnessRoot = ProcessInfo.processInfo.environment["GLREF_HARNESS_ROOT"]
        ?? FileManager.default.currentDirectoryPath
    outputPath = "\(harnessRoot)/../vectors/\(descriptor.name).json"
}

do {
    try json.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

print("wrote \(outputPath)")
print("  primitive: \(descriptor.name)")
print("  cookbook:  \(descriptor.cookbookSection)")
print("  cases:     \(file.cases.count)")
print("  crc32:     \(HexCoding.crc32(file.outputCrc32))")
