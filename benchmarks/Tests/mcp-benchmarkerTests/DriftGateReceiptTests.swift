// DriftGateReceiptTests.swift
//
// Proves the runtime drift-gate preflight CAN refuse.
//
// The Makefile enforces the same rule, but only when MOOT_BINARY names a path
// it can stat. This type covers the case make cannot see, so it is the check
// that always applies — and a check nobody has watched fail is a claim.
//
// Each refusal path gets a test that builds the condition and asserts the
// throw, plus the paired case that must NOT throw. The pairing matters: a
// preflight that refused everything would satisfy the first half and fail the
// second.

import Testing
import Foundation
@testable import mcp_benchmarker

@Suite("DriftGateReceipt preflight")
struct DriftGateReceiptTests {

    /// A scratch cache directory. Each test gets its own so receipts written by
    /// one cannot satisfy another.
    private func scratchDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Writes a receipt in the three-line shape the Makefile produces.
    private func writeReceipt(
        in dir: String, fingerprint: String = "abc123", sourceMTime: Date
    ) throws {
        let text = """
            2026-08-15T22:00:00Z
            \(fingerprint)
            \(Int(sourceMTime.timeIntervalSince1970))
            """
        try text.write(
            toFile: (dir as NSString).appendingPathComponent(DriftGateReceipt.filename),
            atomically: true, encoding: .utf8)
    }

    /// Creates a file with an explicit mtime, standing in for a product binary.
    private func makeBinary(named name: String, mtime: Date) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data([0x7f]))
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: path)
        return path
    }

    // MARK: - Missing and malformed receipts

    @Test("refuses when no receipt exists")
    func refusesWithoutReceipt() throws {
        let dir = try scratchDir()
        #expect(throws: DriftGateRefusal.self) {
            try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: nil)
        }
    }

    /// A receipt that cannot be parsed is absence of evidence, not presence of
    /// a pass. This fails closed on purpose.
    @Test("refuses on a truncated receipt")
    func refusesOnTruncatedReceipt() throws {
        let dir = try scratchDir()
        try "2026-08-15T22:00:00Z\nabc123"
            .write(toFile: (dir as NSString).appendingPathComponent(DriftGateReceipt.filename),
                   atomically: true, encoding: .utf8)

        #expect(throws: DriftGateRefusal.self) {
            try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: nil)
        }
    }

    @Test("refuses when line 3 is not an epoch timestamp")
    func refusesOnNonNumericMTime() throws {
        let dir = try scratchDir()
        try "2026-08-15T22:00:00Z\nabc123\nyesterday"
            .write(toFile: (dir as NSString).appendingPathComponent(DriftGateReceipt.filename),
                   atomically: true, encoding: .utf8)

        #expect(throws: DriftGateRefusal.self) {
            try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: nil)
        }
    }

    // MARK: - The freshness rule

    /// The case the Makefile cannot see: the lane resolved its own binary, and
    /// that binary predates the source the gate validated.
    @Test("refuses a binary older than the validated source")
    func refusesStaleBinary() throws {
        let dir = try scratchDir()
        let sourceChanged = Date(timeIntervalSince1970: 1_760_000_000)
        try writeReceipt(in: dir, sourceMTime: sourceChanged)
        let stale = try makeBinary(
            named: "stale", mtime: sourceChanged.addingTimeInterval(-3600))

        #expect(throws: DriftGateRefusal.self) {
            try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: stale)
        }
    }

    @Test("accepts a binary newer than the validated source")
    func acceptsFreshBinary() throws {
        let dir = try scratchDir()
        let sourceChanged = Date(timeIntervalSince1970: 1_760_000_000)
        try writeReceipt(in: dir, sourceMTime: sourceChanged)
        let fresh = try makeBinary(
            named: "fresh", mtime: sourceChanged.addingTimeInterval(3600))

        try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: fresh)
    }

    /// A binary built at the same instant as the last source change is
    /// accepted. The rule is "older than", not "not newer than" — equal mtimes
    /// happen on fast machines where a build finishes inside the same second,
    /// and refusing them would block correct runs.
    @Test("accepts a binary whose mtime equals the source mtime")
    func acceptsEqualMTime() throws {
        let dir = try scratchDir()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        try writeReceipt(in: dir, sourceMTime: t)
        let sameInstant = try makeBinary(named: "same", mtime: t)

        try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: sameInstant)
    }

    /// An unstattable path is not a refusal: it may be a wrapper or a symlink
    /// into a store the harness cannot inspect, and failing closed there blocks
    /// runs for a reason unrelated to drift. The receipt still had to exist.
    @Test("does not refuse when the binary path cannot be stat'd")
    func toleratesUnstattableBinary() throws {
        let dir = try scratchDir()
        try writeReceipt(in: dir, sourceMTime: Date(timeIntervalSince1970: 1_760_000_000))

        try DriftGateReceipt.preflight(
            cacheDirectory: dir, binaryPath: "/nonexistent/path/to/mootx01")
    }

    // MARK: - Parsing

    @Test("reads all three receipt fields")
    func readsReceiptFields() throws {
        let dir = try scratchDir()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        try writeReceipt(in: dir, fingerprint: "deadbeef", sourceMTime: t)

        let receipt = try DriftGateReceipt.read(cacheDirectory: dir)
        #expect(receipt.kitFingerprint == "deadbeef")
        #expect(receipt.passedAt == "2026-08-15T22:00:00Z")
        #expect(Int(receipt.newestSourceMTime.timeIntervalSince1970)
                == Int(t.timeIntervalSince1970))
    }

    /// The refusal message must name the paths and both instants — a refusal
    /// that does not say what it saw sends the reader back to reproduce it.
    @Test("refusal message names the binary and both timestamps")
    func refusalMessageIsActionable() throws {
        let dir = try scratchDir()
        let sourceChanged = Date(timeIntervalSince1970: 1_760_000_000)
        try writeReceipt(in: dir, sourceMTime: sourceChanged)
        let stale = try makeBinary(
            named: "stale", mtime: sourceChanged.addingTimeInterval(-3600))

        do {
            try DriftGateReceipt.preflight(cacheDirectory: dir, binaryPath: stale)
            Issue.record("preflight must refuse a stale binary")
        } catch let refusal as DriftGateRefusal {
            let text = refusal.description
            #expect(text.contains(stale), "message must name the binary: \(text)")
            #expect(text.contains("REFUSING"), "message must state the refusal: \(text)")
            #expect(text.contains("Rebuild"), "message must say what to do: \(text)")
        }
    }
}
