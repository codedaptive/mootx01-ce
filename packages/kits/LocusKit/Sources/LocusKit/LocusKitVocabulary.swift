// LocusKitVocabulary.swift
//
// LocusKit's contribution to the substrate write-gate vocabulary: the
// operational and provenance field slots a drawer estate declares, with
// their legal value sets per cookbook §2.4 / §2.5. The substrate basis
// (state / sensitivity / exportability / trust / flags, all in the
// adjective column) is supplied by the gate itself, not here — so this
// is purely the consumer union. Frozen once at estate open via
// `VocabularyValidator.freeze`; the frozen `Vocabulary` is what
// `AuditGate.admit` gates every write against.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

public enum LocusKitVocabulary {

    /// Operational + provenance slots. Bitset/flag fields carry no
    /// enumerated value set (any value fits the width); enumerated fields
    /// carry exactly their cookbook raws so the gate refuses any other.
    public static let unionSlots: Set<FieldSlot> = [
        // operational bitmap (DrawerOperational, cookbook §2.4)
        FieldSlot(column: .operational, shift: 0,  width: 6,  label: "capture_channel",
                  legalValues: [0, 1, 2, 3, 4, 5]),
        FieldSlot(column: .operational, shift: 6,  width: 6,  label: "content_kind",
                  legalValues: [0, 1, 2, 3, 4, 5, 6]),
        FieldSlot(column: .operational, shift: 12, width: 12, label: "feature_flags"),       // bitset
        FieldSlot(column: .operational, shift: 24, width: 1,  label: "state_extension"),     // flag
        FieldSlot(column: .operational, shift: 25, width: 1,  label: "lineage_clustering"),  // flag
        // provenance bitmap (Provenance, cookbook §2.5)
        FieldSlot(column: .provenance, shift: 0,  width: 6, label: "source_type",
                  legalValues: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
        FieldSlot(column: .provenance, shift: 6,  width: 6, label: "channel",
                  legalValues: [0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16]),
        FieldSlot(column: .provenance, shift: 12, width: 6, label: "prov_capture_channel",
                  legalValues: [0, 1, 2, 3, 4, 5]),
        FieldSlot(column: .provenance, shift: 18, width: 6, label: "confirmation",
                  legalValues: [0, 1, 2, 3, 4]),
        FieldSlot(column: .provenance, shift: 24, width: 6, label: "confidence",
                  legalValues: [0, 16, 32, 48, 56]),
        FieldSlot(column: .provenance, shift: 30, width: 6, label: "sensitivity_at_capture",
                  legalValues: [0, 16, 32, 48]),
        FieldSlot(column: .provenance, shift: 36, width: 6, label: "enrichment_status",
                  legalValues: [0, 1, 2, 3, 4]),
    ]

    /// Freeze the union into a `Vocabulary` for arming the gate. Static and
    /// known-valid, so this succeeds; the open sequence calls it and arms
    /// the gate with the result before admitting any write.
    public static func frozen() -> Result<Vocabulary, VocabularyError> {
        VocabularyValidator.freeze(union: unionSlots)
    }
}
