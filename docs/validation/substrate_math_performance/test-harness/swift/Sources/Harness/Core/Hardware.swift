// Hardware.swift
//
// Hardware identification for benchmark output. Returns a stable,
// filename-safe slug describing the machine the benchmark ran on.
//
// macOS: `sysctl -n machdep.cpu.brand_string` → e.g. "apple-m3-max"
// Linux: parses /proc/cpuinfo (model name line) → e.g.
//                "arm-neoverse-n2" or "intel-xeon-platinum-8480cl"
// Other: returns "unknown"
//
// Mirror of test-harness/rust/src/harness/hardware.rs. The slug
// is appended to the benchmark output directory so results from
// different hardware live side-by-side without overwriting each
// other. Decision docs cite the slug in their "measured at ..."
// lines so the reader knows what hardware produced the numbers.

import Foundation

public enum Hardware {

    /// Best-effort hardware tag. Format: lowercase, hyphens only,
    /// no whitespace, safe for filenames on all major filesystems.
    public static func tag() -> String {
        #if os(macOS)
        if let s = macOSBrandString() { return slugify(s) }
        #endif
        #if os(Linux)
        if let s = linuxCpuinfoModelName() { return slugify(s) }
        #endif
        return "unknown"
    }

    #if os(macOS)
    private static func macOSBrandString() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "machdep.cpu.brand_string"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif

    #if os(Linux)
    private static func linuxCpuinfoModelName() -> String? {
        guard let content = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") {
            if line.hasPrefix("model name") {
                if let colon = line.firstIndex(of: ":") {
                    let name = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { return name }
                }
            }
        }
        for line in content.split(separator: "\n") {
            if line.hasPrefix("Hardware") {
                if let colon = line.firstIndex(of: ":") {
                    let name = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { return name }
                }
            }
        }
        return nil
    }
    #endif

    /// Lowercase + collapse non-alphanumeric to single hyphen +
    /// trim leading/trailing hyphens. Filename-safe on every
    /// modern filesystem.
    public static func slugify(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var prevHyphen = true // suppresses leading hyphen
        for c in s {
            if c.isASCII && (c.isLetter || c.isNumber) {
                out.append(Character(c.lowercased()))
                prevHyphen = false
            } else if !prevHyphen {
                out.append("-")
                prevHyphen = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "unknown" : out
    }
}
