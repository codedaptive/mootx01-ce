import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

/// The write gate + vocabulary freeze: the properties that make
/// corruption unrepresentable through the interface.
@Suite("AuditGate write gate + vocabulary freeze")
struct AuditGateTests {

    private let estate = UUID()
    private let row = UUID()
    private let anchor = LatticeAnchor(udcCode: 1, qidPointer: 0)

    // A consumer field: capture channel at operational bits 0-3,
    // legal values 0...5 only.
    private let channel = FieldSlot(column: .operational, shift: 0, width: 4,
                                    label: "captureChannel", legalValues: [0,1,2,3,4,5])

    private func vocab(_ union: Set<FieldSlot> = []) -> Vocabulary {
        guard case .success(let v) = VocabularyValidator.freeze(union: union) else {
            fatalError("test vocab failed to freeze")
        }
        return v
    }

    private func hlc(_ p: Int64) -> HLC { HLC(physicalTime: p, logicalCount: 0, nodeID: 0) }

    // MARK: write gate

    @Test func testNoClobber() {
        let priorAdj = BitField.writeField(3, into: 0, shift: 18, width: 6) // trust=3
        let prior = BitmapFields(adjective: UInt64(bitPattern: priorAdj), operational: 0xFF, provenance: 0)
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: prior, priorLatticeAnchor: anchor, writes: [FieldWrite(slot: channel, value: 5)],
            afterLatticeAnchor: anchor, vocabulary: vocab([channel]), hlc: hlc(1), actor: "t")
        guard case .success(let ev) = r else { Issue.record("expected admit"); return }
        #expect((ev.afterBitmaps.adjective >> 18) & 0x3F == 3)   // trust preserved
        #expect(ev.afterBitmaps.operational & 0xF == 5)          // channel written
        #expect((ev.afterBitmaps.operational >> 4) & 0xF == 0xF) // neighbor bits preserved
        #expect(ev.verb == "mutate")
    }

    @Test func testUndeclaredFieldRejected() {
        let bogus = FieldSlot(column: .provenance, shift: 0, width: 4, label: "undeclared")
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: bogus, value: 1)],
            afterLatticeAnchor: anchor, vocabulary: vocab([channel]), hlc: hlc(1), actor: "t")
        guard case .failure(.undeclaredField(let l)) = r else { Issue.record("expected undeclaredField"); return }
        #expect(l == "undeclared")
    }

    @Test func testIllegalValueRejected() {
        // 7 is not in the channel's legal set {0..5}, though it fits 4 bits.
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: channel, value: 7)],
            afterLatticeAnchor: anchor, vocabulary: vocab([channel]), hlc: hlc(1), actor: "t")
        guard case .failure(.illegalValue(_, let v)) = r else { Issue.record("expected illegalValue"); return }
        #expect(v == 7)
    }

    @Test func testOverWidthValueRejectedNotTruncated() {
        // 20 does not fit a 4-bit field (cap 16). Must reject, not mask to 4.
        let wide = FieldSlot(column: .operational, shift: 0, width: 4, label: "wide") // no enum ⇒ width-only
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: wide, value: 20)],
            afterLatticeAnchor: anchor, vocabulary: vocab([wide]), hlc: hlc(1), actor: "t")
        guard case .failure(.illegalValue(_, let v)) = r else { Issue.record("expected illegalValue (no truncation)"); return }
        #expect(v == 20)
    }

    @Test func testIllegalTransitionRejected() {
        let priorAdj = BitField.writeField(Int64(RowState.tombstoned.rawValue), into: 0, shift: 0, width: 6)
        let prior = BitmapFields(adjective: UInt64(bitPattern: priorAdj), operational: 0, provenance: 0)
        let stateSlot = FieldSlot(column: .adjective, shift: 0, width: 6, label: "state")
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: prior, priorLatticeAnchor: anchor,
            writes: [FieldWrite(slot: stateSlot, value: Int64(RowState.active.rawValue))],
            afterLatticeAnchor: anchor, vocabulary: vocab(), hlc: hlc(1), actor: "t")
        guard case .failure(.basisViolation) = r else { Issue.record("expected basisViolation"); return }
    }

    @Test func testContentIDDeterministicAndStable() {
        let mk = { AuditGate.admit(estateUuid: self.estate, rowId: self.row, nounType: .drawer, verb: .capture,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: self.channel, value: 2)],
            afterLatticeAnchor: self.anchor, vocabulary: self.vocab([self.channel]), hlc: self.hlc(7), actor: "t") }
        guard case .success(let a) = mk(), case .success(let b) = mk() else { Issue.record("expected admit"); return }
        #expect(a.eventID == b.eventID)  // same logical event ⇒ same ID (idempotence)
    }

    @Test func testContentIDChangesWithPayload() {
        let mk = { (v: Int64) in AuditGate.admit(estateUuid: self.estate, rowId: self.row, nounType: .drawer, verb: .capture,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: self.channel, value: v)],
            afterLatticeAnchor: self.anchor, vocabulary: self.vocab([self.channel]), hlc: self.hlc(7), actor: "t") }
        guard case .success(let a) = mk(2), case .success(let b) = mk(3) else { Issue.record("expected admit"); return }
        #expect(a.eventID != b.eventID)
    }

    // MARK: vocabulary freeze

    @Test func testFreezeRejectsOverlap() {
        let a = FieldSlot(column: .operational, shift: 0, width: 4, label: "a")
        let b = FieldSlot(column: .operational, shift: 2, width: 4, label: "b") // overlaps a at bits 2-3
        guard case .failure(.overlap) = VocabularyValidator.freeze(union: [a, b]) else {
            Issue.record("expected overlap"); return
        }
    }

    @Test func testFreezeRejectsBasisCollision() {
        // Adjective bits 0-5 are the basis state field.
        let collide = FieldSlot(column: .adjective, shift: 0, width: 6, label: "myState")
        guard case .failure(.basisCollision) = VocabularyValidator.freeze(union: [collide]) else {
            Issue.record("expected basisCollision"); return
        }
    }

    @Test func testFreezeRejectsMalformedWidth() {
        let bad = FieldSlot(column: .operational, shift: 60, width: 8, label: "runsPast64")
        guard case .failure(.malformedWidth) = VocabularyValidator.freeze(union: [bad]) else {
            Issue.record("expected malformedWidth"); return
        }
    }

    @Test func testFreezeRejectsValueExceedingWidth() {
        let bad = FieldSlot(column: .operational, shift: 0, width: 2, label: "small", legalValues: [0,1,9])
        guard case .failure(.valueExceedsWidth) = VocabularyValidator.freeze(union: [bad]) else {
            Issue.record("expected valueExceedsWidth"); return
        }
    }

    @Test func testFreezeAcceptsCleanUnion() {
        guard case .success = VocabularyValidator.freeze(union: [channel]) else {
            Issue.record("clean union should freeze"); return
        }
    }
    // Cross-leg content-ID vector. The same hex is asserted in the Rust
    // audit_gate `content_id_shared_vector` test (M8 byte-parity): the
    // two ports hash identical bytes to the identical id.
    @Test func testContentIDSharedVector() {
        func uuid(_ low: UInt8) -> UUID {
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,low))
        }
        let id = AuditGate.contentID(
            estateUuid: uuid(1), rowId: uuid(2), hlc: hlc(7), verb: "mutate",
            after: (0, 2, 0), afterAnchor: LatticeAnchor(udcCode: 1, qidPointer: 0))
        let hex = withUnsafeBytes(of: id.uuid) { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "eba1f4509f84abe2a472d99fb621334b")
    }
    // State cannot be moved to a state the verb did not authorize.
    @Test func testStateInconsistentWithVerbRejected() {
        let prior = BitmapFields(adjective: 0, operational: 0, provenance: 0) // state=active
        let stateSlot = FieldSlot(column: .adjective, shift: 0, width: 6, label: "state")
        // write state=accepted(3) but verb=mutate (active->active). Inconsistent.
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: prior, priorLatticeAnchor: anchor,
            writes: [FieldWrite(slot: stateSlot, value: Int64(RowState.accepted.rawValue))],
            afterLatticeAnchor: anchor, vocabulary: vocab(), hlc: hlc(1), actor: "t")
        guard case .failure(.stateInconsistentWithVerb) = r else {
            Issue.record("expected stateInconsistentWithVerb"); return
        }
    }

    // A basis value field refuses a non-enumerated value (sensitivity=7).
    @Test func testBasisValueRejected() {
        let prior = BitmapFields(adjective: 0, operational: 0, provenance: 0)
        let sens = FieldSlot(column: .adjective, shift: 6, width: 6, label: "sensitivity")
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: prior, priorLatticeAnchor: anchor, writes: [FieldWrite(slot: sens, value: 7)],
            afterLatticeAnchor: anchor, vocabulary: vocab(), hlc: hlc(1), actor: "t")
        guard case .failure(.illegalValue(let l, 7)) = r else { Issue.record("expected illegalValue"); return }
        #expect(l == "sensitivity")
    }

    // Capture must use the capture verb; a mutation verb on a fresh row is refused.
    @Test func testCaptureRequiresCaptureVerb() {
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: nil, priorLatticeAnchor: nil, writes: [FieldWrite(slot: channel, value: 1)],
            afterLatticeAnchor: anchor, vocabulary: vocab([channel]), hlc: hlc(1), actor: "t")
        guard case .failure(.stateInconsistentWithVerb) = r else {
            Issue.record("expected stateInconsistentWithVerb for non-capture verb on fresh row"); return
        }
    }
    // Basis legalValues are derived from the SubstrateLib-local adjective
    // enums, not from hardcoded integer arrays. Verify each slot's set
    // equals the corresponding enum's allCases raw values.
    @Test func testBasisLegalValuesDerivedFromAuditEnums() {
        let state = Vocabulary.basis.first(where: { $0.label == "state" })
        let sens  = Vocabulary.basis.first(where: { $0.label == "sensitivity" })
        let exp   = Vocabulary.basis.first(where: { $0.label == "exportability" })
        let trust = Vocabulary.basis.first(where: { $0.label == "trust" })
        #expect(state?.legalValues == Set(AuditState.allCases.map { Int64($0.rawValue) }),
            "state slot legalValues must equal AuditState.allCases raws")
        #expect(sens?.legalValues == Set(AuditSensitivity.allCases.map { Int64($0.rawValue) }),
            "sensitivity slot legalValues must equal AuditSensitivity.allCases raws")
        #expect(exp?.legalValues == Set(AuditExportability.allCases.map { Int64($0.rawValue) }),
            "exportability slot legalValues must equal AuditExportability.allCases raws")
        #expect(trust?.legalValues == Set(AuditTrust.allCases.map { Int64($0.rawValue) }),
            "trust slot legalValues must equal AuditTrust.allCases raws")
    }

    // I-22: a secret row cannot be exportable — now enforced in the
    // substrate basis check (centralized from LocusKit), so the gate
    // refuses it on any write.
    @Test func testI22SecretCannotBeExportableViaGate() {
        // build a prior that's active/normal, then write sensitivity=secret
        // AND exportability=public via the gate → basis violation.
        let prior = BitmapFields(adjective: 0, operational: 0, provenance: 0)
        let sens = FieldSlot(column: .adjective, shift: 6, width: 6, label: "sensitivity")
        let exp = FieldSlot(column: .adjective, shift: 12, width: 6, label: "exportability")
        let r = AuditGate.admit(estateUuid: estate, rowId: row, nounType: .drawer, verb: .mutate,
            prior: prior, priorLatticeAnchor: anchor,
            writes: [FieldWrite(slot: sens, value: 48), FieldWrite(slot: exp, value: 32)],
            afterLatticeAnchor: anchor, vocabulary: vocab(), hlc: hlc(1), actor: "t")
        guard case .failure(.basisViolation) = r else {
            Issue.record("expected I-22 basisViolation for secret+exportable"); return
        }
    }
}
