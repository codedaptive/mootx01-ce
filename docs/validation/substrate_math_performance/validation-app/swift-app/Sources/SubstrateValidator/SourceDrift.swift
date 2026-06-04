// SourceDrift.swift — subsystem 6 (source-CRC drift) for the Swift app.
//
// Mirrors the Rust app's build.rs stamp + runtime recompute, with one honest
// difference: SwiftPM's build-plugin sandbox cannot hash a SIBLING package's
// source at build time (plugins are sandboxed to their own target), so there is
// no clean `build.rs` equivalent. Instead `--stamp` records the current lib-source
// CRC to source-crc.txt (intended to be run at release/build time), and `--drift`
// recomputes and compares. Drift = "since the last stamp" rather than the Rust
// app's "since compiled"; same detection, explicit stamp point.
//
// Hashes the same shipping Swift libs this app validates (Sources/*.swift), using
// the canonical Harness CRC32 (CRC-32/ISO-HDLC).
import Foundation
import Harness

enum SourceDrift {
    private static let libs = ["SubstrateTypes", "SubstrateKernel", "SubstrateML", "SubstrateLib"]

    /// repo root: package root (validation-app/swift-app) is #filePath up 3; repo
    /// root is 5 more up (swift-app → validation-app → substrate_math_performance →
    /// validation → docs → repo root).
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SubstrateValidator
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // swift-app
            .deletingLastPathComponent()  // validation-app
            .deletingLastPathComponent()  // substrate_math_performance
            .deletingLastPathComponent()  // validation
            .deletingLastPathComponent()  // docs
            .deletingLastPathComponent()  // repo root
    }

    private static var stampPath: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()  // swift-app
            .appendingPathComponent("source-crc.txt")
    }

    /// Sorted absolute paths of every *.swift under the shipping libs' Sources.
    private static func libSourceFiles() -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        for lib in libs {
            let dir = repoRoot()
                .appendingPathComponent("packages/libs/\(lib)/Sources/\(lib)")
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                files.append(url.standardizedFileURL.path)
            }
        }
        return files.sorted()
    }

    /// (crc, fileCount) over the concatenated source bytes, sorted by path.
    private static func currentCRC() -> (UInt32, Int) {
        let files = libSourceFiles()
        var crc = CRC32()
        for f in files {
            if let data = FileManager.default.contents(atPath: f) {
                crc.update([UInt8](data))
            }
        }
        return (crc.finalize(), files.count)
    }

    /// Write the current lib-source CRC to source-crc.txt. Run at release/build.
    static func stamp() -> Int32 {
        let (crc, n) = currentCRC()
        let line = "\(HexCoding.crc32(crc)) \(n)\n"
        try? line.write(to: stampPath, atomically: true, encoding: .utf8)
        print("stamped lib-source CRC \(HexCoding.crc32(crc)) over \(n) files -> \(stampPath.lastPathComponent)")
        return 0
    }

    /// Recompute and compare to the stamp. Returns 1 on drift (or no stamp), else 0.
    static func drift() -> Int32 {
        let (crc, n) = currentCRC()
        guard let stamped = try? String(contentsOf: stampPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty else {
            print("source drift: NO STAMP (run --stamp first)  (now \(HexCoding.crc32(crc)) over \(n) files)")
            return 1
        }
        let parts = stamped.split(separator: " ")
        let stampedCRC = parts.first.map(String.init) ?? ""
        let drifted = stampedCRC != HexCoding.crc32(crc)
        print("source drift: \(drifted ? "DRIFTED" : "none")  "
            + "(stamped \(stamped); now \(HexCoding.crc32(crc)) over \(n) files)")
        return drifted ? 1 : 0
    }
}
