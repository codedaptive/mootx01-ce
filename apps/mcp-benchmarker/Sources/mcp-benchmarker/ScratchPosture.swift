import Foundation

// ScratchPosture.swift — at-rest encryption posture for benchmark scratch estates.
//
// WHY THIS EXISTS
// mootx01 creates new estates ENCRYPTED by default (CE-1.0.35). Key resolution
// goes through the macOS keychain (EstateKeyProvider), and keychain ACLs are
// bound to the binary's code signature. Every `swift build` re-signs the binary
// ad hoc, so every rebuild invalidates the ACL match and every freshly-spawned
// `mootx01 serve` (one per benchmark question — 50+ per run) triggers a
// keychain prompt at the operator. Synthetic benchmark data that is deleted
// minutes after creation needs zero keychain contact.
//
// THE MECHANISM (contract with the product, verified against
// apps/mootx01/Sources/MootInstallerCore/EstateOpenPosture.swift):
//   - Marker filename: EstateKeyProvider.encryptionOptOutMarkerName == "no-encrypt".
//   - Location: the estate file's PARENT directory. Benchmark runners launch
//     serve with MOOTX01_DATA_DIR=<scratchDir> and the default estate, whose
//     file is <scratchDir>/estate.sqlite — so the marker path is
//     <scratchDir>/no-encrypt.
//   - The marker is consulted ONLY on the absent-file branch of
//     EstateKeyProvider.resolveOpenPosture: a not-yet-created estate with the
//     marker present is created plaintext (posture `newPlaintextByOptOut`).
//     Existing estates are never re-postured by it. The marker must therefore
//     exist BEFORE the first serve launch against the scratch dir — which is
//     exactly when the runners write it (at scratch-dir creation).
//
// The chosen posture is recorded in every report JSON as the run-level
// "estate_encryption" key so results are self-describing about at-rest posture
// (encryption overhead is a legitimate thing to benchmark deliberately via
// --no-plaintext-scratch).

// MARK: - Posture

/// At-rest posture for a benchmark scratch estate.
/// Recorded as the "estate_encryption" key in every report JSON.
enum ScratchEstatePosture: String, Sendable, Codable, Equatable {
    /// Default. The runner writes mootx01's `no-encrypt` opt-out marker into
    /// the scratch data dir before serve launch; the estate is created
    /// plaintext and never touches the macOS keychain.
    case plaintextOptOut = "plaintext-optout"
    /// Deliberate opt-out of the opt-out (--no-plaintext-scratch): no marker
    /// is written, the estate is created encrypted through the keychain.
    /// Use only to benchmark encrypted-estate overhead on purpose.
    case encryptedDefault = "encrypted-default"
}

// MARK: - Marker contract

/// Filename of mootx01's per-estate encryption opt-out marker.
/// MUST match `EstateKeyProvider.encryptionOptOutMarkerName` in
/// MootInstallerCore/EstateOpenPosture.swift. The product treats presence of
/// this file beside a not-yet-created estate file as "create plaintext".
let mootEncryptionOptOutMarkerName = "no-encrypt"

/// URL of the opt-out marker inside a benchmark scratch data dir.
/// The default estate's file is `<scratchDir>/estate.sqlite`, so the marker's
/// parent-of-estate-file location IS the scratch dir itself.
func scratchOptOutMarkerURL(in scratchDir: URL) -> URL {
    scratchDir.appendingPathComponent(mootEncryptionOptOutMarkerName, isDirectory: false)
}

/// Applies the posture to a freshly-created scratch data dir, BEFORE any
/// mootx01 serve is launched against it.
///
/// plaintextOptOut: writes the `no-encrypt` marker (idempotent).
/// encryptedDefault: writes nothing — the product's default (encrypted) applies.
///
/// - Throws: `MCPError` when the marker cannot be written; the runner must not
///   proceed to launch serve with an ambiguous posture.
func applyScratchPosture(_ posture: ScratchEstatePosture, to scratchDir: URL) throws {
    guard posture == .plaintextOptOut else { return }
    let marker = scratchOptOutMarkerURL(in: scratchDir)
    // Idempotent: an existing marker already encodes the same choice.
    guard !FileManager.default.fileExists(atPath: marker.path) else { return }
    let body = """
        Benchmark scratch estate: created with the encryption opt-out marker so
        mootx01 serve creates it PLAINTEXT (posture newPlaintextByOptOut) and
        never touches the macOS keychain. This directory holds synthetic
        benchmark data and is torn down by the harness.

        """
    do {
        try Data(body.utf8).write(to: marker, options: .atomic)
    } catch {
        throw MCPError(description:
            "applyScratchPosture: could not write opt-out marker \(marker.path): \(error)")
    }
}

/// True when the scratch dir currently carries the opt-out marker. Used by the
/// estate cache to verify that a restored snapshot's posture matches the run's
/// expected posture (a snapshot copies the whole data dir, so the marker
/// travels with it).
func scratchHasOptOutMarker(in scratchDir: URL) -> Bool {
    FileManager.default.fileExists(atPath: scratchOptOutMarkerURL(in: scratchDir).path)
}
