// ValidateVectors/main.swift
//
// CLI: `swift run validate-vectors <path-to-vector-json>`
//
// Reads a vector file, runs the matching primitive's validator
// against the Swift scalar reference, prints a structured report,
// exits 0 on PASS and 1 on FAIL.

import Foundation
import Harness
import GeniusLocusReference

func usage() -> Never {
    FileHandle.standardError.write("usage: validate-vectors <path-to-vector-json> [--kernel <name>]\n".data(using: .utf8)!)
    exit(2)
}

var path: String?
var kernel: KernelKind = .scalar
var i = 1
let rawArgs = CommandLine.arguments
while i < rawArgs.count {
    let a = rawArgs[i]
    switch a {
    case "--kernel":
        i += 1
        guard i < rawArgs.count else { usage() }
        guard let k = KernelSelector.parse(rawArgs[i]) else {
            FileHandle.standardError.write("unknown kernel: \(rawArgs[i])\n".data(using: .utf8)!)
            exit(2)
        }
        kernel = k
    default:
        if a.hasPrefix("--") {
            usage()
        }
        if path != nil { usage() }
        path = a
    }
    i += 1
}
guard let resolvedPath = path else { usage() }
KernelSelector.set(kernel)

let json: String
do {
    json = try String(contentsOfFile: resolvedPath, encoding: .utf8)
} catch {
    FileHandle.standardError.write("cannot read \(resolvedPath): \(error)\n".data(using: .utf8)!)
    exit(1)
}

let file: VectorFile
do {
    file = try JSONReader.parseVectorFile(json)
} catch {
    FileHandle.standardError.write("malformed vector file: \(error)\n".data(using: .utf8)!)
    exit(1)
}

guard let descriptor = PrimitiveRegistry.find(file.primitive) else {
    FileHandle.standardError.write("unknown primitive in file: \(file.primitive)\n".data(using: .utf8)!)
    exit(1)
}

let result: ValidationResult
do {
    result = try descriptor.validate(file)
} catch {
    FileHandle.standardError.write("validator error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

print("validating \(resolvedPath)")
print("  primitive: \(file.primitive)  (\(file.cookbookSection))")
print("  generator: \(file.generator.language) v\(file.generator.harnessVersion)")
print("  cases:     \(file.cases.count)")

var failedCount = 0
for cr in result.caseResults {
    if !cr.passed {
        failedCount += 1
        print("  FAIL \(cr.id): \(cr.diagnostic ?? "(no diagnostic)")")
    }
}
if failedCount > 0 {
    print("  \(failedCount) of \(result.caseResults.count) cases failed")
}

print("  crc expected: \(HexCoding.crc32(result.crcExpected))")
print("  crc actual:   \(HexCoding.crc32(result.crcActual))")
if result.crcExpected != result.crcActual {
    print("  CRC MISMATCH")
}

if result.passed {
    print("PASS")
    exit(0)
} else {
    print("FAIL")
    exit(1)
}
