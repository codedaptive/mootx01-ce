// AuditLogFoldPrimitive.swift
//
// Audit log G-Set projection (cookbook § 5.3 + § 8.15). Mirror of
// rust/src/primitives/audit_log_fold.rs.
//
// Wired to the real reference at
// substrate_reference/GeniusLocusReference/glref-swift-AuditLogFold.swift
// via the GeniusLocusReference Swift package.
//
// Exercises `projectCurrentState`: given a row id, noun type, and
// a list of AuditEvents (in arbitrary order), fold to the
// ProjectedRowState. Both ports sort by HLC ascending internally
// before folding, so input order does not affect the projection
// (commutativity / G-Set semantics).
//
// Each case:
//   1. Generate N events for a single row id (5-12 per case).
//   2. Shuffle the event order (deterministic shuffle from RNG).
//   3. Fold and record the projected state.
//
// Output bytes encoded canonically: adjective/operational/provenance
// bitmaps (i64 each, LE), state_raw, tombstoned flag, lattice
// anchor (16 bytes LE), and lastEventHLC wire bytes (16 LE).
//
// Input schema:
//   row_id        : 16-byte hex
//   noun_type     : u8 hex (NounType enum raw value)
//   estate_uuid   : 16-byte hex (same across all events in a case)
//   events        : array of {
//                     hlc: 16-byte hex,
//                     after_adjective:   i64 hex,
//                     after_operational: i64 hex,
//                     after_provenance:  i64 hex,
//                     after_udc:         u64 hex,
//                     after_qid:         u64 hex,
//                     verb:              string
//                   }
//
// Output schema:
//   state_raw          : u8 hex
//   adjective_bitmap   : i64 hex
//   operational_bitmap : i64 hex
//   provenance_bitmap  : i64 hex
//   udc                : u64 hex
//   qid                : u64 hex
//   tombstoned         : u8 hex (0 or 1)
//   last_event_hlc     : 16-byte hex

import Foundation
import GeniusLocusReference

public enum AuditLogFoldPrimitive {

    public static let descriptor = PrimitiveDescriptor(
        name: "audit_log_fold",
        cookbookSection: "§5.3+§8.15",
        referenceFile: "glref-swift-AuditLogFold.swift",
        generate: generate,
        validate: validate
    )

    public static func generate(seed: UInt64) throws -> VectorFile {
        var rng = SplitMix64(seed: seed)
        var cases = [VectorFile.Case]()
        let caseCount = 32

        for i in 0..<caseCount {
            let estateBytes = randomUUIDBytes(&rng)
            let rowBytes = randomUUIDBytes(&rng)
            let nounRaw = UInt8(i % 8)
            let noun = NounType(rawValue: nounRaw) ?? .drawer

            // Number of events 5..12.
            let nEvents = 5 + Int(rng.next() % 8)

            // Generate raw events in HLC-ascending order.
            var rawEvents = [SyntheticEvent]()
            var lastPhys: Int64 = 0
            for _ in 0..<nEvents {
                lastPhys += Int64(1 + (rng.next() & 0xFFF))   // monotonic
                let hlc = HLC(physicalTime: lastPhys, logicalCount: 0, nodeID: 0)

                // Bitmaps: cycle through reachable state values
                // (active=0, pending=1, contested=2, accepted=3,
                //  superseded=16, decayed=17, withdrawn=18, expired=19,
                //  rejected=32, tombstoned=33). Pick one with the RNG.
                let stateMenu: [UInt8] = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
                let stateVal = stateMenu[Int(rng.next() % UInt64(stateMenu.count))]
                // Build the adjective bitmap from the chosen state in
                // the low 6 bits plus a random high-bits tail. Use
                // `Int64(bitPattern:)` to convert the random UInt64
                // since direct `Int64(...)` traps when bit 63 is set.
                let adjUpper = rng.next() & 0xFFFFFFFF_FFFFFF00
                let adj = Int64(bitPattern: adjUpper | UInt64(stateVal))
                let op  = Int64(bitPattern: rng.next())
                let prov = Int64(bitPattern: rng.next())
                let udc = rng.next()
                let qid = rng.next() & 0x7FFFFFFFFFFFFFFF

                rawEvents.append(SyntheticEvent(
                    hlc: hlc, adjective: adj, operational: op, provenance: prov,
                    udc: udc, qid: qid, verb: "mutate"))
            }

            // Shuffle deterministically with the RNG so the events
            // arrive out of order, exercising the sort step.
            var shuffled = rawEvents
            for k in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let j = Int(rng.next() % UInt64(k + 1))
                shuffled.swapAt(k, j)
            }

            // Build AuditEvent values for the real reference.
            let estateUUID = uuidFromBytes(estateBytes)
            let rowUUID = uuidFromBytes(rowBytes)
            let auditEvents = shuffled.map { e -> AuditEvent in
                let anchor = LatticeAnchor(udcCode: e.udc, qidPointer: e.qid)
                return AuditEvent(
                    estateUuid: estateUUID,
                    rowId: rowUUID,
                    hlc: e.hlc,
                    verb: e.verb,
                    beforeBitmaps: nil,
                    afterBitmaps: (adjective: e.adjective,
                                    operational: e.operational,
                                    provenance: e.provenance),
                    beforeLatticeAnchor: nil,
                    afterLatticeAnchor: anchor,
                    actor: "harness")
            }

            guard let state = AuditLogFold.projectCurrentState(
                    rowId: rowUUID, nounType: noun, events: auditEvents) else {
                fatalError("projection returned nil")
            }

            let eventsArr: JSONValue = .array(shuffled.map { e -> JSONValue in
                .dict(JSONDict([
                    ("hlc",               .string(HexCoding.encode(e.hlc.wireBytes))),
                    ("after_adjective",   .string(HexCoding.u64(UInt64(bitPattern: e.adjective)))),
                    ("after_operational", .string(HexCoding.u64(UInt64(bitPattern: e.operational)))),
                    ("after_provenance",  .string(HexCoding.u64(UInt64(bitPattern: e.provenance)))),
                    ("after_udc",         .string(HexCoding.u64(e.udc))),
                    ("after_qid",         .string(HexCoding.u64(e.qid))),
                    ("verb",              .string(e.verb)),
                ]))
            })
            let inputs = JSONDict([
                ("row_id",      .string(HexCoding.encode(rowBytes))),
                ("noun_type",   .string(HexCoding.u8(nounRaw))),
                ("estate_uuid", .string(HexCoding.encode(estateBytes))),
                ("events",      eventsArr),
            ])
            let output = JSONDict([
                ("state_raw",          .string(HexCoding.u8(state.stateRaw))),
                ("adjective_bitmap",   .string(HexCoding.u64(UInt64(bitPattern: state.adjectiveBitmap)))),
                ("operational_bitmap", .string(HexCoding.u64(UInt64(bitPattern: state.operationalBitmap)))),
                ("provenance_bitmap",  .string(HexCoding.u64(UInt64(bitPattern: state.provenanceBitmap)))),
                ("udc",                .string(HexCoding.u64(state.latticeAnchor.udcCode))),
                ("qid",                .string(HexCoding.u64(state.latticeAnchor.qidPointer))),
                ("tombstoned",         .string(HexCoding.u8(state.tombstoned ? 1 : 0))),
                ("last_event_hlc",     .string(HexCoding.encode(state.lastEventHLC.wireBytes))),
            ])

            cases.append(VectorFile.Case(
                id: String(format: "case_%03d", i),
                description: "noun=\(nounRaw), |events|=\(nEvents), tombstoned=\(state.tombstoned)",
                inputs: inputs, expectedOutput: output))
        }

        var encoder = CanonicalBinaryEncoder()
        for c in cases { encodeOutput(c.expectedOutput, encoder: &encoder) }
        let crc = CRC32.compute(encoder.bytes)

        return VectorFile(
            primitive: "audit_log_fold",
            cookbookSection: "§5.3+§8.15",
            generator: VectorFile.Generator(
                language: "swift",
                harnessVersion: VectorFile.harnessVersion,
                referenceFile: "glref-swift-AuditLogFold.swift"),
            seed: seed,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputCrc32: crc,
            cases: cases)
    }

    public static func validate(_ file: VectorFile) throws -> ValidationResult {
        var caseResults = [ValidationResult.CaseResult]()
        var encoder = CanonicalBinaryEncoder()
        for c in file.cases { caseResults.append(validateCase(c, encoder: &encoder)) }
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
        guard case .string(let ridHex) = c.inputs.get("row_id") ?? .null,
              let ridBytes = try? HexCoding.decode(ridHex),
              ridBytes.count == 16 else { return fail(c, "malformed row_id") }
        guard case .string(let estHex) = c.inputs.get("estate_uuid") ?? .null,
              let estBytes = try? HexCoding.decode(estHex),
              estBytes.count == 16 else { return fail(c, "malformed estate_uuid") }
        guard case .string(let ntHex) = c.inputs.get("noun_type") ?? .null,
              let ntBytes = try? HexCoding.decode(ntHex),
              ntBytes.count == 1,
              let noun = NounType(rawValue: ntBytes[0]) else { return fail(c, "malformed noun_type") }

        guard case .array(let eventsArr) = c.inputs.get("events") ?? .null else {
            return fail(c, "missing events")
        }

        let estateUUID = uuidFromBytes(estBytes)
        let rowUUID = uuidFromBytes(ridBytes)
        var auditEvents = [AuditEvent]()
        for v in eventsArr {
            guard case .dict(let obj) = v else { return fail(c, "event not dict") }
            guard let hlc = parseHLC(obj.get("hlc")) else { return fail(c, "event hlc malformed") }
            guard let adj = parseI64(obj.get("after_adjective")) else { return fail(c, "after_adjective malformed") }
            guard let op  = parseI64(obj.get("after_operational")) else { return fail(c, "after_operational malformed") }
            guard let prov = parseI64(obj.get("after_provenance")) else { return fail(c, "after_provenance malformed") }
            guard let udc = parseU64(obj.get("after_udc")) else { return fail(c, "after_udc malformed") }
            guard let qid = parseU64(obj.get("after_qid")) else { return fail(c, "after_qid malformed") }
            guard case .string(let verb)? = obj.get("verb") else { return fail(c, "verb malformed") }

            let anchor = LatticeAnchor(udcCode: udc, qidPointer: qid)
            auditEvents.append(AuditEvent(
                estateUuid: estateUUID,
                rowId: rowUUID,
                hlc: hlc,
                verb: verb,
                beforeBitmaps: nil,
                afterBitmaps: (adjective: adj, operational: op, provenance: prov),
                beforeLatticeAnchor: nil,
                afterLatticeAnchor: anchor,
                actor: "harness"))
        }

        guard let state = AuditLogFold.projectCurrentState(
                rowId: rowUUID, nounType: noun, events: auditEvents) else {
            return fail(c, "projection returned nil")
        }

        // Parse expected outputs.
        guard let expStateRaw = parseU8(c.expectedOutput.get("state_raw")) else { return fail(c, "missing state_raw") }
        guard let expAdj = parseI64(c.expectedOutput.get("adjective_bitmap")) else { return fail(c, "missing adjective_bitmap") }
        guard let expOp = parseI64(c.expectedOutput.get("operational_bitmap")) else { return fail(c, "missing operational_bitmap") }
        guard let expProv = parseI64(c.expectedOutput.get("provenance_bitmap")) else { return fail(c, "missing provenance_bitmap") }
        guard let expUdc = parseU64(c.expectedOutput.get("udc")) else { return fail(c, "missing udc") }
        guard let expQid = parseU64(c.expectedOutput.get("qid")) else { return fail(c, "missing qid") }
        guard let expTomb = parseU8(c.expectedOutput.get("tombstoned")) else { return fail(c, "missing tombstoned") }
        guard let expHLC = parseHLC(c.expectedOutput.get("last_event_hlc")) else { return fail(c, "missing last_event_hlc") }

        // Encode canonical.
        encoder.writeU8(state.stateRaw)
        encoder.writeI64(state.adjectiveBitmap)
        encoder.writeI64(state.operationalBitmap)
        encoder.writeI64(state.provenanceBitmap)
        encoder.writeU64(state.latticeAnchor.udcCode)
        encoder.writeU64(state.latticeAnchor.qidPointer)
        encoder.writeU8(state.tombstoned ? 1 : 0)
        encoder.writeBytes(state.lastEventHLC.wireBytes)

        if state.stateRaw != expStateRaw {
            return fail(c, "state_raw mismatch: expected \(expStateRaw), got \(state.stateRaw)")
        }
        if state.adjectiveBitmap != expAdj {
            return fail(c, "adjective mismatch")
        }
        if state.operationalBitmap != expOp {
            return fail(c, "operational mismatch")
        }
        if state.provenanceBitmap != expProv {
            return fail(c, "provenance mismatch")
        }
        if state.latticeAnchor.udcCode != expUdc {
            return fail(c, "udc mismatch")
        }
        if state.latticeAnchor.qidPointer != expQid {
            return fail(c, "qid mismatch")
        }
        if (state.tombstoned ? UInt8(1) : 0) != expTomb {
            return fail(c, "tombstoned mismatch")
        }
        if state.lastEventHLC.physicalTime != expHLC.physicalTime
            || state.lastEventHLC.logicalCount != expHLC.logicalCount
            || state.lastEventHLC.nodeID != expHLC.nodeID {
            return fail(c, "last_event_hlc mismatch")
        }

        return ValidationResult.CaseResult(id: c.id, passed: true, diagnostic: nil)
    }

    private static func encodeOutput(_ output: JSONDict,
                                      encoder: inout CanonicalBinaryEncoder) {
        guard let stateRaw = parseU8(output.get("state_raw")),
              let adj = parseI64(output.get("adjective_bitmap")),
              let op = parseI64(output.get("operational_bitmap")),
              let prov = parseI64(output.get("provenance_bitmap")),
              let udc = parseU64(output.get("udc")),
              let qid = parseU64(output.get("qid")),
              let tomb = parseU8(output.get("tombstoned")),
              let hlc = parseHLC(output.get("last_event_hlc")) else {
            fatalError("expected_output malformed")
        }
        encoder.writeU8(stateRaw)
        encoder.writeI64(adj)
        encoder.writeI64(op)
        encoder.writeI64(prov)
        encoder.writeU64(udc)
        encoder.writeU64(qid)
        encoder.writeU8(tomb)
        encoder.writeBytes(hlc.wireBytes)
    }

    // MARK: - Helpers

    private static func fail(_ c: VectorFile.Case, _ msg: String) -> ValidationResult.CaseResult {
        return ValidationResult.CaseResult(id: c.id, passed: false, diagnostic: msg)
    }

    private static func randomUUIDBytes(_ rng: inout SplitMix64) -> [UInt8] {
        let lo = rng.next()
        let hi = rng.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for j in 0..<8 { bytes[j]     = UInt8((lo >> (j * 8)) & 0xFF) }
        for j in 0..<8 { bytes[8 + j] = UInt8((hi >> (j * 8)) & 0xFF) }
        return bytes
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func parseHLC(_ v: JSONValue?) -> HLC? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for j in 0..<8 { phys |= Int64(bytes[j]) << (j * 8) }
        var log: Int32 = 0
        for j in 0..<4 { log  |= Int32(bytes[8 + j]) << (j * 8) }
        var node: Int32 = 0
        for j in 0..<4 { node |= Int32(bytes[12 + j]) << (j * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    private static func parseI64(_ v: JSONValue?) -> Int64? {
        guard let u = parseU64(v) else { return nil }
        return Int64(bitPattern: u)
    }

    private static func parseU64(_ v: JSONValue?) -> UInt64? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (i * 8) }
        return v
    }

    private static func parseU8(_ v: JSONValue?) -> UInt8? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    private struct SyntheticEvent {
        let hlc: HLC
        let adjective: Int64
        let operational: Int64
        let provenance: Int64
        let udc: UInt64
        let qid: UInt64
        let verb: String
    }
}
