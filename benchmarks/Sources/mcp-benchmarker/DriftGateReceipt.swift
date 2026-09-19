// DriftGateReceipt.swift
//
// Runtime enforcement of the drift gate, for the case the Makefile cannot
// cover.
//
// `make drift-gate` runs CorpusKit's counts-store invariants in both ports and
// writes a receipt. `make drift-stamp-current` then refuses to measure a binary
// that predates the source those invariants were checked against — but only
// when MOOT_BINARY names a path make can stat. When the flag is unset, the lane
// discovers its own binary and make has nothing to compare, so the rule goes
// unenforced exactly where a mistake is easiest to make.
//
// This type applies the same rule against the path the harness ACTUALLY
// resolved, which is the check that always applies. A measurement of a binary
// older than the validated source is a measurement of code nobody checked, and
// it reads as an ordinary result.
//
// The receipt is three lines, written only when both ports' suites pass:
//
//   1  ISO8601 instant the gate passed        (provenance, not enforcement)
//   2  sha256 over the kit sources it checked (make enforces this one)
//   3  newest kit source mtime, epoch seconds (THIS type enforces this one)
//
// Line 3 exists so the harness can apply the freshness rule without reaching
// into the kit tree. The harness is layered away from the kits deliberately
// (its deps are IntellectusLib + ObserverSink); teaching it to stat kit sources
// would put kit layout knowledge in the benchmarker, and drift between those
// two is the failure this whole mechanism exists to prevent.

import Foundation

/// Why a run may not proceed. Each case carries the numbers, because a refusal
/// that does not say what it saw sends the reader back to reproduce it.
public enum DriftGateRefusal: Error, CustomStringConvertible {
    /// No receipt at the expected path: the gate has not run for this cache dir.
    case noReceipt(path: String)

    /// The receipt exists but is not the three-line shape this type reads.
    /// Treated as a refusal rather than a pass: an unreadable receipt is
    /// absence of evidence, and the whole point is to fail closed.
    case unreadableReceipt(path: String, detail: String)

    /// The binary under test predates the newest source the gate validated.
    case binaryOlderThanValidatedSource(
        binaryPath: String, binaryMTime: Date, newestSourceMTime: Date)

    public var description: String {
        switch self {
        case .noReceipt(let path):
            return """
                REFUSING to run: no drift-gate receipt at \(path).
                The counts-store invariants have not been checked for this cache \
                directory. Run `make drift-gate` before measuring.
                """
        case .unreadableReceipt(let path, let detail):
            return """
                REFUSING to run: drift-gate receipt at \(path) could not be read \
                (\(detail)). An unreadable receipt is not evidence the gate passed. \
                Run `make drift-gate` to rewrite it.
                """
        case .binaryOlderThanValidatedSource(let binaryPath, let binaryMTime, let sourceMTime):
            return """
                REFUSING to run: \(binaryPath) is older than the source the drift \
                gate validated.
                  binary built:   \(ISO8601DateFormatter().string(from: binaryMTime))
                  source changed: \(ISO8601DateFormatter().string(from: sourceMTime))
                The binary predates the code whose invariants were checked, so the \
                gate's evidence does not cover what is about to be measured. \
                Rebuild the binary, then run `make drift-gate`.
                """
        }
    }
}

/// The gate's receipt, and the rule the harness enforces from it.
public struct DriftGateReceipt {

    /// Instant the gate passed. Provenance for the run record; not enforced.
    public let passedAt: String

    /// sha256 over the kit sources the gate checked. Carried so a run record
    /// can name the exact source state that was validated. The Makefile
    /// enforces this field; the harness cannot, having no kit tree to hash.
    public let kitFingerprint: String

    /// Newest mtime among the kit sources the gate checked.
    public let newestSourceMTime: Date

    /// Filename the Makefile writes. One constant, so a rename cannot leave
    /// the writer and the reader looking at different paths.
    public static let filename = ".drift-gate-stamp"

    /// Reads the receipt from a cache directory.
    ///
    /// - Throws: `DriftGateRefusal.noReceipt` when absent,
    ///   `.unreadableReceipt` when present but malformed. Both are refusals:
    ///   this fails closed, because the alternative is measuring on the
    ///   strength of a file nobody could parse.
    public static func read(cacheDirectory: String) throws -> DriftGateReceipt {
        let path = (cacheDirectory as NSString).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path) else {
            throw DriftGateRefusal.noReceipt(path: path)
        }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw DriftGateRefusal.unreadableReceipt(
                path: path, detail: error.localizedDescription)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else {
            throw DriftGateRefusal.unreadableReceipt(
                path: path, detail: "expected 3 lines, found \(lines.count)")
        }
        guard let epoch = TimeInterval(lines[2]) else {
            throw DriftGateRefusal.unreadableReceipt(
                path: path, detail: "line 3 is not an epoch timestamp: '\(lines[2])'")
        }
        return DriftGateReceipt(
            passedAt: lines[0],
            kitFingerprint: lines[1],
            newestSourceMTime: Date(timeIntervalSince1970: epoch))
    }

    /// Refuses when `binaryPath` is older than the newest source the gate
    /// validated.
    ///
    /// A binary whose mtime cannot be read is NOT a refusal: the path may be a
    /// wrapper or a symlink into a store the harness cannot stat, and failing
    /// closed there would block legitimate runs on a condition unrelated to
    /// drift. The receipt checks that CAN be made are made.
    public func assertCovers(binaryPath: String) throws {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: binaryPath),
            let binaryMTime = attrs[.modificationDate] as? Date
        else { return }

        if binaryMTime < newestSourceMTime {
            throw DriftGateRefusal.binaryOlderThanValidatedSource(
                binaryPath: binaryPath,
                binaryMTime: binaryMTime,
                newestSourceMTime: newestSourceMTime)
        }
    }

    /// The whole preflight: read the receipt, then apply the freshness rule.
    ///
    /// Call once per run, after the lane has resolved which binary it will
    /// drive and before it writes anything to a scratch estate.
    public static func preflight(cacheDirectory: String, binaryPath: String?) throws {
        let receipt = try read(cacheDirectory: cacheDirectory)
        // A run with no resolved binary has nothing to check freshness against.
        // The receipt still had to exist, which is the part that can be checked.
        guard let binaryPath else { return }
        try receipt.assertCovers(binaryPath: binaryPath)
    }
}
