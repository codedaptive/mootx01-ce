// MomentSummaryPrimitive.swift
//
// Moment-summary fingerprint (cookbook §8.7) — promotes the
// `moment_summary` reference into the conformance harness per the
// "Pending future work" entry in primitive-catalog.md.
//
// Wired to the real reference at
// GeniusLocusReference/glref-swift-MomentSummary.swift via the
// GeniusLocusReference Swift package.
//
// Mirror: rust/src/primitives/moment_summary.rs
//
// The Swift/Rust API asymmetry (Swift's `Row` is the full
// production type from glref-swift-Verbs.swift; Rust uses a
// lightweight `RowLite` with only fingerprint + capture_hlc) is
// bridged here: the harness builds whatever each language needs
// from a unified (fingerprint, capture_hlc) input pair.
//
// In Swift, the moment_summary algorithm calls
// `activeDuring(Row, TimeRange) -> Bool` once per row in row
// order. We use an index-counter closure that pulls the
// corresponding capture HLC from a parallel array.
//
// Input schema:
//   rows   : array of {capture_hlc: HLC-32hex, fingerprint: Fingerprint256-64hex}
//   window : {end: HLC-32hex, start: HLC-32hex}
//
// Output schema:
//   summary : Fingerprint256 (64-hex, 32 wire bytes)
//
// Binary canonical encoding (alphabetical key order, single field):
//   summary : 32 bytes (4 × u64 LE per Fingerprint256.wireBytes)
//
// Cross-language bit-identity: only OR (idempotent, commutative,
// integer) and integer HLC comparison. No transcendentals. The
// captured-during filter consumes rows in JSON-array order in
// both languages so the OR-reduce accumulates in identical order.

import Foundation
import GeniusLocusReference

public enum MomentSummaryPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "moment_summary",
        cookbookSection: "§8.7",
        referenceFile: "glref-swift-MomentSummary.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let spec = generateCaseSpec(i, rng: &rng)
            let summary = computeSummary(rows: spec.rows, captureHLCs: spec.captureHLCs,
                                          window: spec.window)

            let rowsJSON: JSONValue = .array(zip(spec.rows, spec.captureHLCs).map { row, hlc in
                .dict(JSONDict([
                    ("capture_hlc", .string(HexCoding.encode(hlc.wireBytes))),
                    ("fingerprint", .string(HexCoding.encode(row.fingerprint.wireBytes))),
                ]))
            })
            let windowJSON: JSONValue = .dict(JSONDict([
                ("end",   .string(HexCoding.encode(spec.window.end.wireBytes))),
                ("start", .string(HexCoding.encode(spec.window.start.wireBytes))),
            ]))

            let inputs = JSONDict([
                ("rows",   rowsJSON),
                ("window", windowJSON),
            ])
            let output = JSONDict([
                ("summary", .string(HexCoding.encode(summary.wireBytes))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: spec.description,
                inputs: inputs,
                expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "moment_summary",
            cookbookSection: "§8.7",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-MomentSummary.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases {
            caseResults.append(validateCase(c, encoder: &encoder))
        }
        let crcActual = CRC32.compute(encoder.bytes)
        let allPassed = caseResults.allSatisfy { $0.passed }
        return ValidationResult(
            passed: allPassed && crcActual == file.outputCrc32,
            caseResults: caseResults,
            crcExpected: file.outputCrc32,
            crcActual: crcActual)
    }

    private static func validateCase(_ c: VectorFile.Case,
                                      encoder: inout CanonicalBinaryEncoder)
                                     -> ValidationResult.CaseResult {
        guard case .array(let rowsArr) = c.inputs.get("rows") ?? .null else {
            return fail(c, "missing rows")
        }
        var fingerprints = [Fingerprint256]()
        var captureHLCs = [HLC]()
        fingerprints.reserveCapacity(rowsArr.count)
        captureHLCs.reserveCapacity(rowsArr.count)
        for (rowIdx, rv) in rowsArr.enumerated() {
            guard case .dict(let rd) = rv else {
                return fail(c, "row[\(rowIdx)] not a dict")
            }
            guard case .string(let fpHex) = rd.get("fingerprint") ?? .null,
                  let fp = parseFingerprint(fpHex) else {
                return fail(c, "row[\(rowIdx)] missing or malformed fingerprint")
            }
            guard case .string(let hHex) = rd.get("capture_hlc") ?? .null,
                  let h = parseHLC(hHex) else {
                return fail(c, "row[\(rowIdx)] missing or malformed capture_hlc")
            }
            fingerprints.append(fp)
            captureHLCs.append(h)
        }
        guard case .dict(let wd) = c.inputs.get("window") ?? .null else {
            return fail(c, "missing window")
        }
        guard case .string(let startHex) = wd.get("start") ?? .null,
              let start = parseHLC(startHex) else {
            return fail(c, "missing window.start")
        }
        guard case .string(let endHex) = wd.get("end") ?? .null,
              let end = parseHLC(endHex) else {
            return fail(c, "missing window.end")
        }
        let window = TimeRange(start: start, end: end)

        let rows = makeRows(fingerprints: fingerprints)
        let actual = computeSummaryFromRows(rows: rows, captureHLCs: captureHLCs,
                                              window: window)

        guard case .string(let expHex) = c.expectedOutput.get("summary") ?? .null,
              let expected = parseFingerprint(expHex) else {
            return fail(c, "missing or malformed expected summary")
        }

        encoder.writeBytes(actual.wireBytes)

        if actual == expected {
            return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
        } else {
            return ValidationResult.CaseResult(
                id: c.id, passed: false,
                diagnostic: "summary mismatch: expected \(HexCoding.encode(expected.wireBytes)), got \(HexCoding.encode(actual.wireBytes))")
        }
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard case .string(let s) = output.get("summary") ?? .null,
              let fp = parseFingerprint(s) else {
            fatalError("expected_output missing or malformed summary")
        }
        encoder.writeBytes(fp.wireBytes)
    }

    // MARK: - Algorithm wrappers

    /// Build a minimal `Row` set carrying only the fingerprints we
    /// care about. All other fields are throwaway: nounType=.drawer,
    /// state=.active, bitmaps=0, latticeAnchor=null, id from a
    /// deterministic per-position UUID.
    private static func makeRows(fingerprints: [Fingerprint256]) -> [Row] {
        return fingerprints.enumerated().map { (idx, fp) in
            Row(id: makeDeterministicUUID(idx),
                nounType: .drawer,
                state: .active,
                adjectiveBitmap: 0,
                operationalBitmap: 0,
                provenanceBitmap: 0,
                fingerprint: fp,
                latticeAnchor: LatticeAnchor(udcCode: 0, qidPointer: 0))
        }
    }

    /// Wrap `MomentSummary.summarize` with the index-counter
    /// closure that resolves each row to its capture HLC.
    /// `summarize` calls the predicate exactly once per row in
    /// row order (via `rows.filter`), so a monotonic counter
    /// matches the parallel HLC array index-for-index.
    private static func computeSummary(rows: [(fingerprint: Fingerprint256, idx: Int)],
                                        captureHLCs: [HLC],
                                        window: TimeRange) -> Fingerprint256 {
        let rowObjs = makeRows(fingerprints: rows.map { $0.fingerprint })
        return computeSummaryFromRows(rows: rowObjs, captureHLCs: captureHLCs, window: window)
    }

    private static func computeSummaryFromRows(rows: [Row],
                                                 captureHLCs: [HLC],
                                                 window: TimeRange) -> Fingerprint256 {
        let counter = IndexCounter()
        return MomentSummary.summarize(rows: rows, window: window) { _, w in
            let idx = counter.value
            counter.value += 1
            guard idx < captureHLCs.count else { return false }
            return w.contains(captureHLCs[idx])
        }
    }

    // MARK: - Case generation

    private struct CaseSpec {
        let rows: [(fingerprint: Fingerprint256, idx: Int)]
        let captureHLCs: [HLC]
        let window: TimeRange
        let description: String
    }

    private static func generateCaseSpec(_ i: Int, rng: inout SplitMix64) -> CaseSpec {
        switch i {
        case 0:
            return CaseSpec(
                rows: [], captureHLCs: [],
                window: TimeRange(start: hlc(0, 0, 0), end: hlc(1000, 0, 0)),
                description: "empty rows -> zero fingerprint")
        case 1:
            // Single row inside window.
            let fp = Fingerprint256(block0: 0xCAFEBABE, block1: 0xDEAD, block2: 0xBEEF, block3: 0x1234)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(500, 0, 0)],
                window: TimeRange(start: hlc(0, 0, 0), end: hlc(1000, 0, 0)),
                description: "single row inside window")
        case 2:
            // No rows match (single row outside window).
            let fp = Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(2000, 0, 0)],
                window: TimeRange(start: hlc(0, 0, 0), end: hlc(1000, 0, 0)),
                description: "single row outside window -> zero")
        case 3:
            // All rows match (window covers all).
            let fps = (0..<5).map { k in randomFingerprint(&rng, salt: UInt64(k)) }
            let hlcs = (0..<5).map { k in hlc(Int64(100 * (k + 1)), 0, 1) }
            return CaseSpec(
                rows: fps.enumerated().map { ($0.element, $0.offset) },
                captureHLCs: hlcs,
                window: TimeRange(start: hlc(0, 0, 0), end: hlc(10_000, 0, 0)),
                description: "all 5 rows in window")
        case 4:
            // Boundary: row exactly at window.start (inclusive).
            let fp = Fingerprint256(block0: 0x1, block1: 0, block2: 0, block3: 0)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(100, 0, 1)],
                window: TimeRange(start: hlc(100, 0, 1), end: hlc(200, 0, 1)),
                description: "row at window.start (inclusive)")
        case 5:
            // Boundary: row exactly at window.end (inclusive).
            let fp = Fingerprint256(block0: 0x2, block1: 0, block2: 0, block3: 0)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(200, 0, 1)],
                window: TimeRange(start: hlc(100, 0, 1), end: hlc(200, 0, 1)),
                description: "row at window.end (inclusive)")
        case 6:
            // Just before window.start (excluded).
            let fp = Fingerprint256(block0: 0x4, block1: 0, block2: 0, block3: 0)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(99, 0, 1)],
                window: TimeRange(start: hlc(100, 0, 1), end: hlc(200, 0, 1)),
                description: "row just before window.start -> excluded")
        case 7:
            // Just after window.end (excluded).
            let fp = Fingerprint256(block0: 0x8, block1: 0, block2: 0, block3: 0)
            return CaseSpec(
                rows: [(fp, 0)],
                captureHLCs: [hlc(201, 0, 1)],
                window: TimeRange(start: hlc(100, 0, 1), end: hlc(200, 0, 1)),
                description: "row just after window.end -> excluded")
        default:
            // Random distributions.
            let rowCount = 1 + Int(rng.next() % 16)            // 1..16 rows
            var fps = [Fingerprint256]()
            var hlcs = [HLC]()
            for k in 0..<rowCount {
                fps.append(randomFingerprint(&rng, salt: UInt64(k)))
                let phys = Int64(rng.next() & 0x0000_FFFF_FFFF_FFFF)
                let log  = Int32(rng.next() & 0x0000_FFFF)
                let node = Int32(rng.next() & 0x0000_00FF)
                hlcs.append(hlc(phys, log, node))
            }
            let wStartPhys = Int64(rng.next() & 0x0000_FFFF_FFFF_FFFF)
            let wEndOffset = Int64(rng.next() & 0x0000_FFFF_FFFF)
            let window = TimeRange(
                start: hlc(wStartPhys, 0, 0),
                end:   hlc(wStartPhys &+ wEndOffset, 0, Int32.max))
            return CaseSpec(
                rows: fps.enumerated().map { ($0.element, $0.offset) },
                captureHLCs: hlcs,
                window: window,
                description: "random \(rowCount) rows, window spans 0x..\(String(format: "%llx", wEndOffset))")
        }
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func parseFingerprint(_ s: String) -> Fingerprint256? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 32 else { return nil }
        return try? Fingerprint256(wireBytes: bytes)
    }

    private static func parseHLC(_ s: String) -> HLC? {
        guard let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for i in 0..<8 { phys |= Int64(bytes[i]) << (i * 8) }
        var log: Int32 = 0
        for i in 0..<4 { log  |= Int32(bytes[8 + i]) << (i * 8) }
        var node: Int32 = 0
        for i in 0..<4 { node |= Int32(bytes[12 + i]) << (i * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    private static func hlc(_ phys: Int64, _ log: Int32, _ node: Int32) -> HLC {
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    private static func randomFingerprint(_ rng: inout SplitMix64, salt: UInt64) -> Fingerprint256 {
        // Four words from the RNG; salt only feeds the description
        // but RNG consumption is identical between languages.
        _ = salt
        return Fingerprint256(
            block0: rng.next(),
            block1: rng.next(),
            block2: rng.next(),
            block3: rng.next())
    }

    /// Stable deterministic UUID from a row position. The exact
    /// bytes don't matter — Row.id is only used as a dictionary
    /// key in production; the harness uses it only for type
    /// satisfaction.
    private static func makeDeterministicUUID(_ idx: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let i = UInt64(bitPattern: Int64(idx))
        for k in 0..<8 { bytes[k] = UInt8((i >> (k * 8)) & 0xFF) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Reference-typed counter for the activeDuring closure. The
/// closure is `(Row, TimeRange) -> Bool`; Swift closures can't
/// mutate captured value-type variables without a wrapping ref.
private final class IndexCounter {
    var value: Int = 0
}
