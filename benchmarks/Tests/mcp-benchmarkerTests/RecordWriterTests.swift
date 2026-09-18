import Testing
import Foundation
@testable import mcp_benchmarker

// RecordWriterTests.swift — the two record mandates of 2026-08-17.
//
// These are the Swift half of a cross-port pair; the Rust half lives in
// `record_writer.rs`'s test module and asserts the same literals. Both legs
// pin literal names rather than shapes, because a shape assertion passes for a
// name that has lost its arm — which is exactly the defect that cost 4h19m of
// matrix measurement.

@Suite("Record naming and no-clobber writes") struct RecordWriterSuite {

    // MARK: Naming

    @Test("A record name carries test, arm and serial")
    func nameCarriesTestArmSerial() {
        #expect(recordFilename(test: "matrix", arm: "lmeb", serial: "20260817T055302Z")
                == "matrix-lmeb-20260817T055302Z.json")
        #expect(recordFilename(test: "matrix", arm: "lmeb", serial: "20260817T055302Z",
                               suffix: "params")
                == "matrix-lmeb-20260817T055302Z-params.json")
    }

    @Test("Two arms of one lane cannot produce one name")
    func armsDoNotCollide() {
        // The defect, stated as a test: these four ran in one pass and all
        // wrote `matrix-report-seed20260816.json`.
        let serial = "20260817T055302Z"
        let names = ["locomo", "lmeb", "lme-s", "membench-ThirdAgent"].map {
            recordFilename(test: "matrix", arm: $0, serial: serial)
        }
        #expect(Set(names).count == names.count)
    }

    @Test("A serial distinguishes two passes of the same arm")
    func serialsDoNotCollide() {
        let a = recordFilename(test: "membench", arm: "ThirdAgent", serial: "20260817T055302Z")
        let b = recordFilename(test: "membench", arm: "ThirdAgent", serial: "20260818T010000Z")
        #expect(a != b)
    }

    @Test("Path separators in an arm are flattened")
    func armSeparatorsFlattened() {
        let name = recordFilename(test: "matrix", arm: "set/one", serial: "S")
        #expect(name == "matrix-set_one-S.json")
        #expect(!name.contains("/"))
    }

    @Test("The run serial comes from --run-id when supplied")
    func serialHonoursRunID() {
        #expect(resolveRunSerial(["--run-id", "20260817T055302Z"]) == "20260817T055302Z")
        // Absent the flag a serial is still produced — a record is never
        // written without one. Shape only; the value is the current time.
        let fallback = resolveRunSerial([])
        #expect(fallback.count == 16)
        #expect(fallback.hasSuffix("Z"))
    }

    // MARK: No overwrite

    @Test("A second write to one path is refused and leaves the first intact")
    func secondWriteRefused() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("record-writer-noclobber-swift")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("r.json")
        try writeRecordNeverOverwrite(Data("first".utf8), to: path)

        var refused = false
        do {
            try writeRecordNeverOverwrite(Data("second".utf8), to: path)
        } catch {
            refused = true
            #expect("\(error)".contains("never overwritten"))
        }
        #expect(refused)
        // A refused write must not truncate what was already measured.
        #expect(try Data(contentsOf: path) == Data("first".utf8))
    }

    @Test("A large record is written whole")
    func largeRecordWrittenWhole() throws {
        // `write(2)` may return a short count; the MemBench report is ~53 MB,
        // so the write loop is load-bearing rather than defensive.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("record-writer-large-swift")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let path = dir.appendingPathComponent("big.json")
        try writeRecordNeverOverwrite(payload, to: path)
        #expect(try Data(contentsOf: path).count == payload.count)
    }

    // MARK: Parent directory creation

    // Gate for item (b): writeRecordNeverOverwrite must create the parent
    // directory tree before the O_EXCL open. Without the createDirectory call
    // the open(2) fails with ENOENT and the test throws — not with a
    // "never overwritten" error, but with a generic "cannot create record" one.
    // Removing the createDirectory block makes this test fail (gate is red).
    @Test("writeRecordNeverOverwrite creates the parent directory when absent")
    func parentDirCreatedOnWrite() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("record-writer-parent-create-swift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // root itself is NOT created; the function must create both root and sub.
        let path = root
            .appendingPathComponent("sub")
            .appendingPathComponent("record.json")
        // If parent creation is removed the throw carries "cannot create record",
        // not the expected success path, so this #expect throws and the test fails.
        try writeRecordNeverOverwrite(Data("payload".utf8), to: path)
        #expect(try Data(contentsOf: path) == Data("payload".utf8))
    }

    // MARK: Ledger

    @Test("The ledger appends rather than replaces")
    func ledgerAppends() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("record-writer-ledger-swift")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("records.tsv")
        try appendToLedger("matrix\tlocomo\tone.json", at: path)
        try appendToLedger("matrix\tlmeb\ttwo.json", at: path)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("locomo"))
        #expect(lines[1].contains("lmeb"))
    }
}
