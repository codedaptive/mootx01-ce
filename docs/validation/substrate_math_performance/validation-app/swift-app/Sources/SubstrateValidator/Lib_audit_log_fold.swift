// Lib_audit_log_fold.swift
//
// Lib-side conformance CRC for the `audit_log_fold` primitive
// (cookbook §5.3 + §8.15). Computes the canonical CRC by calling the
// SHIPPING libs (SubstrateML.AuditLogFold over SubstrateTypes.AuditEvent),
// not the glref reference, so the validator can report lib-vs-glref drift
// on the projected-row-state wire encoding.
//
// Byte mechanism mirrors the Harness AuditLogFoldPrimitive CRC-accumulation
// path exactly. The harness accumulates, per case, the projected state via:
//     writeU8(state_raw)
//     writeI64(adjective_bitmap)
//     writeI64(operational_bitmap)
//     writeI64(provenance_bitmap)
//     writeU64(udc)
//     writeU64(qid)
//     writeU8(tombstoned ? 1 : 0)
//     writeBytes(lastEventHLC.wireBytes)   // 16 bytes, no length prefix
// case after case. CRC32 over the accumulated bytes must equal the
// committed outputCrc32.
//
// Input schema (per case):
//   row_id        : 16-byte hex (row UUID).
//   noun_type     : u8 hex (NounType raw value).
//   estate_uuid   : 16-byte hex (estate UUID, identical across a case's events).
//   events        : array of {
//                     hlc:               16-byte hex (HLC wire form),
//                     after_adjective:   i64 hex (LE u64 bit-pattern),
//                     after_operational: i64 hex,
//                     after_provenance:  i64 hex,
//                     after_udc:         u64 hex,
//                     after_qid:         u64 hex,
//                     verb:              string
//                   }
//   Events arrive in arbitrary order; the fold sorts by HLC ascending
//   internally (G-Set commutativity), so input order does not affect
//   the projection.
//
// Output (per case, accumulated into the shared encoder): the
// ProjectedRowState fields in the order listed above.
//
// Shipping-vs-glref API note: the shipping SubstrateML.AuditLogFold has the
// identical fold signature to the glref reference —
// `projectCurrentState(rowId:nounType:events:)` returns an optional
// ProjectedRowState with the same fields (stateRaw, three bitmaps,
// latticeAnchor, tombstoned, lastEventHLC). The fold math (cookbook §5.3)
// is byte-identical across ports. The only structural difference is that
// the shipping SubstrateTypes.AuditEvent carries an `eventID` field (which
// defaults in its initializer and does not participate in the fold), so the
// AuditEvent construction here omits it; the projection is unaffected.
// state_raw is the low 6 bits of the adjective bitmap; tombstoned is sticky
// (true once state_raw == 33 appears, per I-22).

import Foundation
import Harness
import SubstrateTypes
import SubstrateML

enum Lib_audit_log_fold {
    static func crc(_ file: VectorFile) -> UInt32 {
        var enc = CanonicalBinaryEncoder()
        for c in file.cases {
            // --- row_id: 16-byte UUID ---
            guard case .string(let ridHex) = c.inputs.get("row_id") ?? .null,
                  let ridBytes = try? HexCoding.decode(ridHex), ridBytes.count == 16
            else { continue }

            // --- noun_type: single u8 (NounType raw value) ---
            guard case .string(let ntHex) = c.inputs.get("noun_type") ?? .null,
                  let ntBytes = try? HexCoding.decode(ntHex), ntBytes.count == 1,
                  let noun = NounType(rawValue: ntBytes[0])
            else { continue }

            // --- estate_uuid: 16-byte UUID, identical across the case's events ---
            guard case .string(let estHex) = c.inputs.get("estate_uuid") ?? .null,
                  let estBytes = try? HexCoding.decode(estHex), estBytes.count == 16
            else { continue }

            // --- events: array of audit rows in arbitrary order ---
            guard case .array(let eventsArr) = c.inputs.get("events") ?? .null
            else { continue }

            let estateUUID = alfUUID(estBytes)
            let rowUUID = alfUUID(ridBytes)

            var auditEvents = [AuditEvent]()
            auditEvents.reserveCapacity(eventsArr.count)
            var malformed = false
            for v in eventsArr {
                guard case .dict(let obj) = v,
                      let hlc = alfParseHLC(obj.get("hlc")),
                      let adj = alfParseI64(obj.get("after_adjective")),
                      let op = alfParseI64(obj.get("after_operational")),
                      let prov = alfParseI64(obj.get("after_provenance")),
                      let udc = alfParseU64(obj.get("after_udc")),
                      let qid = alfParseU64(obj.get("after_qid")),
                      case .string(let verb)? = obj.get("verb")
                else { malformed = true; break }

                let anchor = LatticeAnchor(udcCode: udc, qidPointer: qid)
                // eventID defaults in the SubstrateTypes.AuditEvent initializer
                // and does not participate in the fold (the fold keys on rowId
                // and orders by hlc), so it is left at its default here.
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
            if malformed { continue }

            // Shipping G-Set projection (cookbook §5.3). The fold sorts by
            // HLC ascending internally, so the shuffled input order does not
            // change the projected state.
            guard let state = AuditLogFold.projectCurrentState(
                    rowId: rowUUID, nounType: noun, events: auditEvents)
            else { continue }

            // Canonical encoding: the ProjectedRowState fields in the harness's
            // fixed order, no length prefix, exactly the harness CRC path.
            enc.writeU8(state.stateRaw)
            enc.writeI64(state.adjectiveBitmap)
            enc.writeI64(state.operationalBitmap)
            enc.writeI64(state.provenanceBitmap)
            enc.writeU64(state.latticeAnchor.udcCode)
            enc.writeU64(state.latticeAnchor.qidPointer)
            enc.writeU8(state.tombstoned ? 1 : 0)
            enc.writeBytes(state.lastEventHLC.wireBytes)
        }
        return CRC32.compute(enc.bytes)
    }

    // MARK: - Helpers (private, alf-prefixed to avoid cross-file collisions)

    /// Build a UUID from 16 raw bytes in declaration order. Mirrors the
    /// harness `uuidFromBytes`.
    private static func alfUUID(_ bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        let tuple: uuid_t = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// Decode a 16-byte HLC wire form: 8-byte LE physicalTime, 4-byte LE
    /// logicalCount, 4-byte LE nodeID. Mirrors the harness `parseHLC` and
    /// the SubstrateTypes `HLC(wireBytes:)` byte layout.
    private static func alfParseHLC(_ v: JSONValue?) -> HLC? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 16 else { return nil }
        var phys: Int64 = 0
        for j in 0..<8 { phys |= Int64(bytes[j]) << (j * 8) }
        var log: Int32 = 0
        for j in 0..<4 { log |= Int32(bytes[8 + j]) << (j * 8) }
        var node: Int32 = 0
        for j in 0..<4 { node |= Int32(bytes[12 + j]) << (j * 8) }
        return HLC(physicalTime: phys, logicalCount: log, nodeID: node)
    }

    /// Decode an 8-byte LE u64, reinterpreted as the i64 bit-pattern.
    /// Mirrors the harness `parseI64`.
    private static func alfParseI64(_ v: JSONValue?) -> Int64? {
        guard let u = alfParseU64(v) else { return nil }
        return Int64(bitPattern: u)
    }

    /// Decode an 8-byte little-endian u64. Mirrors the harness `parseU64`.
    private static func alfParseU64(_ v: JSONValue?) -> UInt64? {
        guard case .string(let s)? = v,
              let bytes = try? HexCoding.decode(s), bytes.count == 8 else { return nil }
        var out: UInt64 = 0
        for (i, b) in bytes.enumerated() { out |= UInt64(b) << (i * 8) }
        return out
    }
}
