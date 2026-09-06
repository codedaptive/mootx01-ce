//! model_directory_resolver — encoder model directory resolution for Rust.
//!
//! Locates the model directory for a given model ID, verifying vocab.txt
//! sha256 as the integrity sentinel. `SpanEncoderFactory::make` calls
//! `model_dir_for` and treats `None` as model unavailable — recall then
//! runs lexical-only with no error surfaced to the caller.
//!
//! # Search order (contract §7 of ENCODER_RERANK_CONTRACT.md)
//!
//! 1. `<data_dir>/models/<model_id>/`  — 1.2 download location (empty today)
//! 2. `<exe_dir>/../share/mootx01/models/<model_id>/` — installer package path
//!
//! Slot 2 is where `fetch-rust-triple.sh` places the three Rust model files
//! (`config.json`, `tokenizer.json`, `model.safetensors`) in the installer.
//! On macOS development runs the binary lives beside the repo; the
//! `../share/mootx01/models/` path will typically not exist and the function
//! returns None unless `MOOTX01_DATA_DIR` points at a prepared directory.
//!
//! # Integrity check
//!
//! For each found directory, `vocab.txt` sha256 is verified against the
//! hardcoded `KNOWN_TOKENIZER_HASHES` table. A mismatch logs one line to
//! stderr and returns None so a stale or tampered vocab does not silently
//! produce wrong vectors. The large `model.safetensors` is NOT re-hashed at
//! resolve time (sealed by the build pipeline; 90 MB would add ~20 ms).

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

use crate::EncoderModelSeed;

// ─────────────────────────────────────────────────────────────────────────────
// Known tokenizer hashes.
// sha256(vocab.txt) for each shipped model ID, sourced from
// tools/encoder-models/encoder-models-linux.json.
// Update when swapping the winner from the audition.
// ─────────────────────────────────────────────────────────────────────────────

/// sha256 of vocab.txt for each known bundled model ID.
/// The hash is identical between the Apple and Linux/Windows manifests
/// because both platforms ship the same source vocab file.
fn known_tokenizer_hashes() -> HashMap<&'static str, &'static str> {
    let mut m = HashMap::new();
    // all-MiniLM-L6-v2 at revision 1110a243fdf4706b3f48f1d95db1a4f5529b4d41.
    m.insert(
        "minilm-l6-v2-w60",
        "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
    );
    m.insert(EncoderModelSeed::MODEL_ID, EncoderModelSeed::TOKENIZER_HASH);
    m
}

/// Files that must be present in the Rust model directory for each model ID.
/// These are the three files the candle provider loads.
fn required_files() -> HashMap<&'static str, &'static [&'static str]> {
    let mut m: HashMap<&'static str, &'static [&'static str]> = HashMap::new();
    m.insert(
        "minilm-l6-v2-w60",
        &[
            "config.json",
            "tokenizer.json",
            "model.safetensors",
            "vocab.txt",
        ],
    );
    m.insert(
        "arctic-embed-s-w60",
        &[
            "config.json",
            "tokenizer.json",
            "model.safetensors",
            "vocab.txt",
        ],
    );
    m
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Locate the encoder model directory for `model_id`.
///
/// `data_dir` is the mootx01 data directory root (search slot 1 — the 1.2
/// download location, empty in 1.1).
///
/// Returns `Some(PathBuf)` pointing to the verified directory, or `None` when
/// the model is absent or its vocab.txt sha256 does not match. Absence is
/// silent (normal operating condition in 1.1); sha256 mismatch logs one line
/// to stderr.
pub fn model_dir_for(model_id: &str, data_dir: &Path) -> Option<PathBuf> {
    let exe_dir = exe_directory();
    model_dir_for_with_exe_dir(model_id, data_dir, exe_dir.as_deref())
}

/// Resolver implementation with an injectable executable directory so tests
/// can exercise the installed `../share/mootx01/models` layout.
fn model_dir_for_with_exe_dir(
    model_id: &str,
    data_dir: &Path,
    exe_dir: Option<&Path>,
) -> Option<PathBuf> {
    // Slot 1: user download directory (1.2 feature, empty today).
    let download_slot = data_dir.join("models").join(model_id);
    if let Some(dir) = verified(&download_slot, model_id, "download") {
        return Some(dir);
    }

    // Slot 2: installer package path beside the binary.
    if let Some(exe_dir) = exe_dir {
        let share_slot = exe_dir
            .join("..")
            .join("share")
            .join("mootx01")
            .join("models")
            .join(model_id);
        // Canonicalize to resolve the ".." component; ignore errors on
        // non-existent paths (the slot is simply absent).
        let canonical = share_slot.canonicalize().unwrap_or(share_slot);
        if let Some(dir) = verified(&canonical, model_id, "package") {
            return Some(dir);
        }
    }

    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `Some(dir)` when the directory exists, all required files are
/// present, and vocab.txt sha256 matches the known hash. Returns `None`
/// with one stderr line on sha256 mismatch; returns `None` silently on
/// absence so the caller can continue to the next search slot.
fn verified(dir: &Path, model_id: &str, source: &str) -> Option<PathBuf> {
    if !dir.is_dir() {
        return None;
    }

    // Confirm required files are present.
    let hashes = known_tokenizer_hashes();
    let files = required_files();
    let Some(required) = files.get(model_id) else {
        eprintln!("[ModelDirectoryResolver] unknown model ID {model_id} — no required-file list");
        return None;
    };
    for file in *required {
        if !dir.join(file).exists() {
            // Absent required file in this slot: move on to next slot silently.
            return None;
        }
    }

    // Verify vocab.txt sha256 as the integrity sentinel.
    let Some(&expected) = hashes.get(model_id) else {
        eprintln!("[ModelDirectoryResolver] no known tokenizer_hash for {model_id}");
        return None;
    };
    let vocab_path = dir.join("vocab.txt");
    match sha256_hex_file(&vocab_path) {
        Err(e) => {
            eprintln!(
                "[ModelDirectoryResolver] cannot read vocab.txt at {}: {e}",
                vocab_path.display()
            );
            return None;
        }
        Ok(actual) if actual != expected => {
            eprintln!(
                "[ModelDirectoryResolver] vocab.txt sha256 mismatch for {model_id} \
                 in {source} slot — expected {expected}, got {actual}. \
                 Session runs lexical-only."
            );
            return None;
        }
        Ok(_) => {}
    }

    Some(dir.to_path_buf())
}

/// Compute the sha256 hex digest of a file. Returns an error when the file
/// cannot be read.
fn sha256_hex_file(path: &Path) -> io::Result<String> {
    let bytes = std::fs::read(path)?;
    let digest = Sha256::digest(&bytes);
    Ok(hex_encode(&digest))
}

/// Encode bytes as lowercase hex.
fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Returns the directory containing the running executable, or `None` when
/// it cannot be determined (permission error, proc/fs unavailable).
fn exe_directory() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const VENDORED_VOCAB: &[u8] =
        include_bytes!("../../Tests/Fixtures/encoder-models/minilm-l6-v2-w60/vocab.txt");

    fn write_model_directory(model_dir: &Path, model_id: &str) {
        fs::create_dir_all(model_dir).unwrap();
        fs::write(model_dir.join("vocab.txt"), VENDORED_VOCAB).unwrap();
        for file in required_files().get(model_id).unwrap().iter().copied() {
            if file != "vocab.txt" {
                fs::write(model_dir.join(file), b"placeholder").unwrap();
            }
        }
    }

    /// The active seed is discoverable from the 1.2 download slot without a
    /// second tokenizer-hash constant. Arctic and MiniLM share this vocabulary;
    /// the filename map remains model-specific.
    #[test]
    fn seeded_arctic_download_slot_resolves() {
        assert_eq!(EncoderModelSeed::MODEL_ID, "arctic-embed-s-w60");
        let tmp = tempdir();
        let model_dir = tmp.join("models").join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&model_dir, EncoderModelSeed::MODEL_ID);

        assert_eq!(
            model_dir_for(EncoderModelSeed::MODEL_ID, &tmp),
            Some(model_dir)
        );
    }

    /// The normal packaged share slot discovers the seeded Arctic model.
    #[test]
    fn seeded_arctic_installed_share_slot_resolves() {
        let tmp = tempdir();
        let exe_dir = tmp.join("bin");
        fs::create_dir_all(&exe_dir).unwrap();
        let model_dir = tmp
            .join("share")
            .join("mootx01")
            .join("models")
            .join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&model_dir, EncoderModelSeed::MODEL_ID);

        assert_eq!(
            model_dir_for_with_exe_dir(
                EncoderModelSeed::MODEL_ID,
                &tmp.join("empty-data"),
                Some(&exe_dir),
            ),
            Some(model_dir.canonicalize().unwrap())
        );
    }

    /// A valid download shadows a valid installed share, preserving slot order.
    #[test]
    fn seeded_arctic_download_precedes_installed_share() {
        let tmp = tempdir();
        let data_dir = tmp.join("data");
        let download = data_dir.join("models").join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&download, EncoderModelSeed::MODEL_ID);
        let exe_dir = tmp.join("bin");
        fs::create_dir_all(&exe_dir).unwrap();
        let installed = tmp
            .join("share")
            .join("mootx01")
            .join("models")
            .join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&installed, EncoderModelSeed::MODEL_ID);

        assert_eq!(
            model_dir_for_with_exe_dir(EncoderModelSeed::MODEL_ID, &data_dir, Some(&exe_dir),),
            Some(download)
        );
    }

    #[test]
    fn seeded_arctic_missing_required_file_returns_none() {
        let tmp = tempdir();
        let model_dir = tmp.join("models").join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&model_dir, EncoderModelSeed::MODEL_ID);
        fs::remove_file(model_dir.join("model.safetensors")).unwrap();

        assert_eq!(
            model_dir_for_with_exe_dir(EncoderModelSeed::MODEL_ID, &tmp, None),
            None
        );
    }

    #[test]
    fn seeded_arctic_vocab_mismatch_returns_none() {
        let tmp = tempdir();
        let model_dir = tmp.join("models").join(EncoderModelSeed::MODEL_ID);
        write_model_directory(&model_dir, EncoderModelSeed::MODEL_ID);
        fs::write(model_dir.join("vocab.txt"), b"wrong-vocab").unwrap();

        assert_eq!(
            model_dir_for_with_exe_dir(EncoderModelSeed::MODEL_ID, &tmp, None),
            None
        );
    }

    /// Build a scratch model directory with valid files and verify the
    /// resolver returns it.
    ///
    /// Failure mode: resolver returns None for a valid directory, meaning
    /// the candle provider never loads and recall stays lexical-only.
    #[test]
    fn resolver_finds_directory_with_correct_vocab() {
        let tmp = tempdir();
        let model_dir = tmp.join("models").join("minilm-l6-v2-w60");
        fs::create_dir_all(&model_dir).unwrap();

        // Write a vocab.txt with the correct sha256.
        // The real file is 231 KB; we embed a tiny representative content
        // and adjust the known hash table for this test via a custom call
        // to `verified` with a test-only model ID.
        //
        // Because we cannot change the hardcoded known hash inside the test,
        // we instead use the REAL vocab file from the kit's test fixture
        // (the same bytes the bundled model ships), skipping when absent.
        let hf_vocab = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/Fixtures/encoder-models/minilm-l6-v2-w60/vocab.txt");
        if !hf_vocab.exists() {
            // Fixture absent on this runner — skip without failing.
            eprintln!("SKIP: fixture vocab absent; skipping resolver integration test");
            return;
        }
        let vocab_bytes = fs::read(&hf_vocab).unwrap();
        fs::write(model_dir.join("vocab.txt"), &vocab_bytes).unwrap();

        // Placeholder required files.
        for f in &["config.json", "tokenizer.json", "model.safetensors"] {
            fs::write(model_dir.join(f), b"placeholder").unwrap();
        }

        let result = model_dir_for("minilm-l6-v2-w60", &tmp);
        assert!(
            result.is_some(),
            "resolver must return Some for a directory with a valid vocab"
        );
    }

    /// A corrupted vocab.txt causes the resolver to return None.
    ///
    /// Failure mode: resolver returns a URL despite sha256 mismatch,
    /// causing the encoder to tokenise with a wrong vocabulary.
    #[test]
    fn corrupted_vocab_returns_none() {
        let tmp = tempdir();
        let model_dir = tmp.join("models").join("minilm-l6-v2-w60");
        fs::create_dir_all(&model_dir).unwrap();
        // Wrong bytes — sha256 will not match.
        fs::write(model_dir.join("vocab.txt"), b"not-a-real-vocab").unwrap();
        for f in &["config.json", "tokenizer.json", "model.safetensors"] {
            fs::write(model_dir.join(f), b"placeholder").unwrap();
        }

        let result = model_dir_for("minilm-l6-v2-w60", &tmp);
        assert!(
            result.is_none(),
            "resolver must return None when vocab.txt sha256 does not match"
        );
    }

    /// A missing download-slot directory returns None without panicking.
    ///
    /// Failure mode: resolver panics or returns a URL to a non-existent path.
    #[test]
    fn missing_directory_returns_none() {
        let tmp = tempdir();
        // No models/ subdirectory at all.
        let result = model_dir_for("minilm-l6-v2-w60", &tmp);
        assert!(
            result.is_none(),
            "resolver must return None when the model directory does not exist"
        );
    }

    /// A fresh scratch directory per call. The test binary runs its cases in
    /// parallel inside one process, so the name carries a per-process counter
    /// beside the pid: a shared per-pid directory would be removed by one case
    /// while another writes into it.
    fn tempdir() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let p = std::env::temp_dir().join(format!("moot-resolver-test-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }
}
