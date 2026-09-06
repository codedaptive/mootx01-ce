// ModelDirectoryResolver.swift
//
// Locates the encoder model directory for a given model ID.
// `SpanEncoderFactory` calls `encoderModelDirectory(for:dataDirectory:)`
// and treats nil as model unavailable — recall then runs lexical-only.
//
// Search order (contract §7.5 of CORPUSKIT_INTERFACE.md):
//   1. <dataDirectory>/models/<modelID>/          — 1.2 download location (empty today)
//   2. Bundle resources <modelID>/                — bundled with app / plugin
//   3. <exe>/../share/mootx01/models/<modelID>/   — installer package path (CLI)
//
// Integrity: for each slot found, the vocab.txt sha256 is verified against
// the hardcoded tokenizer_hash constant for that model. A mismatch returns
// nil and logs once so a stale bundle does not silently produce wrong vectors.
// The large model files (safetensors / .mlmodelc) are NOT re-hashed at
// resolve time — they are sealed at build time by the packaging step.
//
// Adding a new model: add its tokenizer_hash to `knownTokenizerHashes` and
// add its file list to `requiredFiles`. The packaging pipeline then builds
// and places the model directory in the bundle.

import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "ModelDirectoryResolver")

/// Locates and integrity-verifies a bundled encoder model directory.
///
/// `SpanEncoderFactory` calls this at session startup; a nil return
/// means the model is absent and recall runs lexical-only. The call is cheap
/// on the happy path (one directory existence check, then sha256(vocab.txt)).
public enum ModelDirectoryResolver {

    // MARK: - Known model constants

    /// sha256(vocab.txt) for each shipped model ID, as recorded in
    /// tools/encoder-models/encoder-models-apple.json after conversion.
    /// The same hash is stored in the `encoder_models.tokenizer_hash` column
    /// and is identical between the Apple and Linux/Windows manifests because
    /// both platforms use the same source vocab file.
    private static let knownTokenizerHashes: [String: String] = [
        // all-MiniLM-L6-v2 at revision 1110a243fdf4706b3f48f1d95db1a4f5529b4d41.
        "minilm-l6-v2-w60": "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
    ].merging([EncoderModelSeed.modelID: EncoderModelSeed.tokenizerHash]) { _, seeded in seeded }

    /// Files that must be present in the model directory on Apple platforms.
    /// The .mlmodelc is a compiled CoreML bundle (directory); vocab.txt is
    /// the WordPiece vocabulary used for tokenisation.
    private static let requiredFiles: [String: [String]] = [
        "minilm-l6-v2-w60": ["MiniLM-L6-v2.mlmodelc", "vocab.txt"],
        "arctic-embed-s-w60": ["ArcticEmbedS.mlmodelc", "vocab.txt"],
    ]

    // MARK: - Public API

    /// Locate the encoder model directory for `modelID`.
    ///
    /// - Parameters:
    ///   - modelID: The model identifier (e.g. `"arctic-embed-s-w60"`).
    ///   - dataDirectory: The mootx01 data directory root (search slot 1 —
    ///     the 1.2 download location; empty in 1.1).
    ///   - bundle: The resource bundle to search for the bundled model
    ///     (search slot 2). Defaults to `.main`; pass `Bundle.module` or a
    ///     test bundle in tests.
    ///   - executableURL: The URL of the running executable, used to derive
    ///     the installer share slot (search slot 3). Defaults to nil which
    ///     resolves via `Bundle.main.executableURL`; injectable for tests.
    /// - Returns: A URL pointing to the model directory if found and
    ///   vocab.txt integrity-verified; nil otherwise.
    public static func encoderModelDirectory(
        for modelID: String,
        dataDirectory: URL,
        bundle: Bundle = .main,
        executableURL: URL? = nil
    ) -> URL? {
        // Slot 1: user download directory (1.2 feature, empty today).
        let downloadSlot = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        if let url = verified(directory: downloadSlot, modelID: modelID, source: "download") {
            return url
        }

        // Slot 2: bundled resources (app bundle or test bundle).
        if let bundledURL = bundleSlot(modelID: modelID, bundle: bundle) {
            if let url = verified(directory: bundledURL, modelID: modelID, source: "bundle") {
                return url
            }
        }

        // Slot 3: installer package path beside the executable.
        // Mirrors the Rust resolver's `<exe>/../share/mootx01/models/<id>/`
        // path so the Swift CLI (`mootx01` built from apps/mootx01) finds the
        // model installed by the release tarball at the same relative location.
        if let shareURL = shareSlot(modelID: modelID, executableURL: executableURL) {
            if let url = verified(directory: shareURL, modelID: modelID, source: "package") {
                return url
            }
        }

        return nil
    }

    // MARK: - Private helpers

    /// Returns the directory only when all required files are present and
    /// vocab.txt has the expected sha256. Returns nil with one OSLog line on
    /// any failure so the caller degrades to lexical-only silently.
    private static func verified(
        directory: URL,
        modelID: String,
        source: String
    ) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return nil }

        // Confirm required files are present.
        guard let required = requiredFiles[modelID] else {
            log.error("ModelDirectoryResolver: unknown model ID \(modelID, privacy: .public) — no required-file list")
            return nil
        }
        for file in required {
            let filePath = directory.appendingPathComponent(file).path
            // .mlmodelc is a directory; test existence rather than isRegularFile.
            guard fm.fileExists(atPath: filePath) else {
                log.info("ModelDirectoryResolver: \(source, privacy: .public) slot missing \(file, privacy: .public) for \(modelID, privacy: .public)")
                return nil
            }
        }

        // Verify vocab.txt sha256 as the integrity sentinel.
        // The large model files (.mlmodelc / safetensors) are sealed by the
        // build pipeline and not re-hashed here; vocab.txt is cheap (231 KB).
        let vocabURL = directory.appendingPathComponent("vocab.txt")
        guard let expectedHash = knownTokenizerHashes[modelID] else {
            log.error("ModelDirectoryResolver: no known tokenizer_hash for \(modelID, privacy: .public)")
            return nil
        }
        guard let actualHash = sha256Hex(of: vocabURL) else {
            log.error("ModelDirectoryResolver: cannot read vocab.txt at \(vocabURL.path, privacy: .public)")
            return nil
        }
        guard actualHash == expectedHash else {
            log.error("""
                ModelDirectoryResolver: vocab.txt sha256 mismatch for \
                \(modelID, privacy: .public) in \(source, privacy: .public) slot — \
                expected \(expectedHash, privacy: .public), got \(actualHash, privacy: .public). \
                Model directory ignored; session runs lexical-only.
                """)
            return nil
        }

        return directory
    }

    /// Returns the model directory URL inside a resource bundle.
    ///
    /// The bundle is expected to contain a folder named `<modelID>` at its
    /// top level (for app targets: placed via the `resources` section of the
    /// target in project.yml; for the plugin: beside the binary in the plugin
    /// bundle). Returns nil when the bundle has no such resource.
    private static func bundleSlot(modelID: String, bundle: Bundle) -> URL? {
        // Check the root of the bundle's resource path first (the common case
        // for app targets that declare the directory as a resource).
        if let resourcePath = bundle.resourcePath {
            let dir = URL(fileURLWithPath: resourcePath, isDirectory: true)
                .appendingPathComponent(modelID, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                return dir
            }
        }
        // Fallback: ask Bundle for a resource with the modelID as name.
        // This covers test bundles that declare the fixture via .copy() in
        // the test target's resources.
        if let url = bundle.url(forResource: modelID, withExtension: nil) {
            return url
        }
        return nil
    }

    /// Returns the model directory under the installer share path:
    /// `<exe>/../share/mootx01/models/<modelID>/`.
    ///
    /// This slot mirrors the Rust resolver's search slot 2, making the Swift
    /// CLI binary find the model when the release tarball is installed to
    /// `<prefix>/bin/mootx01` + `<prefix>/share/mootx01/models/<id>/`.
    /// App-bundle targets reach the model through the bundle slot (slot 2)
    /// instead; this slot is the CLI's fallback.
    ///
    /// `executableURL` is injectable so tests can exercise the slot without
    /// needing a real binary on PATH. Passing nil resolves via
    /// `Bundle.main.executableURL`, which works for both app bundles and
    /// command-line tools.
    private static func shareSlot(modelID: String, executableURL: URL?) -> URL? {
        let exeURL = executableURL ?? Bundle.main.executableURL
        guard let exeDir = exeURL?.deletingLastPathComponent() else { return nil }
        let candidate = exeDir
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("mootx01", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        // Resolve the ".." component lexically (standardizedFileURL never fails)
        // so the verified() check and its log line see the real path, matching
        // the Rust resolver's canonicalize call on the same slot.
        return candidate.standardizedFileURL
    }

    /// Compute sha256 of a file and return the lowercase hex digest.
    /// Returns nil when the file cannot be read.
    private static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
