import Foundation
import SubstrateTypes
import SubstrateKernel
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

/// Enforces the constitutional forbidden combination per cookbook
/// §9.5 (safety invariants) and the §2.8 verification table.
///
/// The forbidden combination is:
///   sensitivity = secret  (`AdjectiveSensitivity.secret`, raw 48, bits 6–11)
///   AND
///   exportability = public (`AdjectiveExportability.public_`,
///                           raw 32, bits 12–17)
///
/// F11 cascade (2026-05-27): field positions and raws bumped from
/// v0.35 (bits 4–7 / 8–11; raws 12 / 8) to cookbook v0.6 (bits 6–11
/// / 12–17; raws 48 / 32). The numeric encoding is the contract; the
/// enum names are documentation.
///
/// Storage can represent the combination; the verb layer must not
/// produce it. This validator is called at every adjective-bitmap
/// write path before any transaction opens, so a violation leaves
/// the database exactly as it was — the row never reaches INSERT
/// and the audit table never receives a row.
///
/// The validator does not import the `AdjectiveSensitivity` or
/// `AdjectiveExportability` enums. The bit constants below are
/// hand-derived from those enums' shipped `rawValue`s so future
/// changes to the enum cases (renaming `public_` to a non-keyword
/// alias, adding intermediate tiers between `restricted` and
/// `secret`) cannot silently shift this check. The numeric encoding
/// at bits 4–11 is the contract; the enum names are documentation.
///
/// Additional forbidden combinations may be added in future spec
/// versions. When added, extend `isForbidden` with another guarded
/// clause and a matching `disciplineViolation` throw — the surface
/// pattern is intentionally simple so each addition is reviewable as
/// a one-line change against the spec.
public enum ForbiddenCombinationValidator {

    // MARK: - Forbidden field values (cookbook §2.3)
    //
    // F18 atomic centralization: the prior `sensitivityMask`/`secretValue`/
    // `exportabilityMask`/`exportableValue` constants were removed. The
    // checks now extract each field via `BitField` and compare to the
    // cookbook-spec'd raw directly: sensitivity=secret is raw 48 at bits
    // 6–11; exportability=public is raw 32 at bits 12–17.

    // MARK: - Public API

    /// Validate that `bitmap` does not encode a forbidden combination.
    /// Throws `LocusKitError.disciplineViolation` if it does, with
    /// `from` set to the sensitivity raw value (bits 6–11) and `to`
    /// set to the exportability raw value (bits 12–17). The
    /// `from`/`to` field reuse is the same pattern `DrawerStateValidator`
    /// uses to keep `LocusKitError` independent of the typed enums.
    ///
    /// - Parameter bitmap: the full `adjectiveBitmap` value about to
    ///   be written. The validator only inspects bits 6–17; state
    ///   bits (0–5) and trust bits (18–23) are ignored.
    public static func validate(_ bitmap: Int64) throws {
        if isSecretAndExportable(bitmap) {
            throw LocusKitError.disciplineViolation(
                // F18: cookbook §2.3 sensitivity (bits 6-11) + exportability (bits 12-17).
                from: Int(BitField.extractField(bitmap, shift: 6, width: 6)),
                to:   Int(BitField.extractField(bitmap, shift: 12, width: 6)),
                reason: "forbidden combination: sensitivity=secret AND " +
                        "exportability=exportable (spec I-3, § 6.6)"
            )
        }
    }

    // MARK: - Private checks

    /// True when `bitmap` encodes both `secret` in bits 6–11 and
    /// `public` in bits 12–17. Other bits are not inspected.
    private static func isSecretAndExportable(_ bitmap: Int64) -> Bool {
        // F18 atomic centralization: extract each field via BitField and
        // compare the field value directly to the cookbook-spec'd raw.
        // Sensitivity=secret is raw 48 at bits 6–11; exportability=public
        // is raw 32 at bits 12–17 (cookbook §2.3).
        let sensitivity = BitField.extractField(bitmap, shift: 6, width: 6)
        let exportability = BitField.extractField(bitmap, shift: 12, width: 6)
        return sensitivity == 48 && exportability == 32
    }
}
